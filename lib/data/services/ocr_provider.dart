import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;

import '../../domain/logic/grade_parser.dart';
import '../../domain/logic/student_matcher.dart';
import '../../domain/models/extraction_models.dart';
import 'ministry_excel_service.dart';

class ProviderCapabilities {
  final bool offline;
  final bool sendsDataOffDevice;
  final bool acceptsRosterHints;
  final bool supportsArabicHandwriting;

  const ProviderCapabilities({
    required this.offline,
    required this.sendsDataOffDevice,
    required this.acceptsRosterHints,
    required this.supportsArabicHandwriting,
  });
}

class OcrPrivacyOptions {
  final bool cloudConsentGranted;
  final bool shareRosterNamesAsHint;

  const OcrPrivacyOptions({
    this.cloudConsentGranted = false,
    this.shareRosterNamesAsHint = false,
  });
}

abstract class OcrProvider {
  String get name;
  ProviderCapabilities get capabilities;

  Future<SheetExtraction> extractSheet({
    required String imageId,
    required String imagePath,
    required Uint8List imageBytes,
    required List<RosterStudent> roster,
    required List<MinistryGradeColumn> targetColumns,
    OcrPrivacyOptions privacy = const OcrPrivacyOptions(),
  });
}

/// Real Cloud Vision-LLM OCR Provider (Gemini 2.5 Flash).
/// Enforces explicit teacher consent before sending any image bytes off-device.
class VisionLlmOcrProvider implements OcrProvider {
  final String apiKey;
  final String modelName;
  final http.Client _client;

  VisionLlmOcrProvider({
    required this.apiKey,
    this.modelName = 'gemini-2.5-flash',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  String get name => 'VisionLLM ($modelName)';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        offline: false,
        sendsDataOffDevice: true,
        acceptsRosterHints: true,
        supportsArabicHandwriting: true,
      );

  static String buildPrompt({
    required List<MinistryGradeColumn> targetColumns,
    List<String>? rosterNamesHint,
  }) {
    final colDesc = targetColumns.map((c) => '${c.code}: ${c.label}').join(', ');
    final rosterClause = (rosterNamesHint != null && rosterNamesHint.isNotEmpty)
        ? 'Official class roster (use ONLY to disambiguate unclear handwriting, never invent rows): ${rosterNamesHint.join(" | ")}.'
        : 'Do NOT assume a fixed student list; transcribe exactly what is written.';

    return '''
You are transcribing a photographed handwritten Algerian school grade sheet.
Return ONLY valid JSON with this exact schema:
{
  "rows": [
    {
      "raw_name": "string as written",
      "box": [y0, x0, y1, x1],
      "grades": [
        {
          "column_code": "string matching one of [$colDesc] or raw header",
          "raw_text": "string exactly as written (keep Arabic-Indic digits or comma decimals)",
          "confidence": 0.0
        }
      ],
      "observation": "string or empty"
    }
  ]
}
Rules:
- Normalized box coordinates must be floats between 0.0 and 1.0 (top-left origin: y0, x0, y1, x1).
- Transcribe numbers and markers (غ, abs, معفى) verbatim. Never guess missing values.
- $rosterClause
''';
  }

  @override
  Future<SheetExtraction> extractSheet({
    required String imageId,
    required String imagePath,
    required Uint8List imageBytes,
    required List<RosterStudent> roster,
    required List<MinistryGradeColumn> targetColumns,
    OcrPrivacyOptions privacy = const OcrPrivacyOptions(),
  }) async {
    if (!privacy.cloudConsentGranted) {
      throw StateError(
        'تم منع الإرسال: يجب موافقة الأستاذ الصريحة قبل معالجة صورة التلاميذ سحابياً.',
      );
    }
    if (apiKey.trim().isEmpty) {
      throw ArgumentError(
        'مفتاح Gemini API غير مضبوط. أدخله في إعدادات الأستاذ أو استخدم القراءة المحلية للأرقام.',
      );
    }

    final rosterHints = privacy.shareRosterNamesAsHint
        ? roster.map((s) => s.fullName).toList()
        : null;

    final prompt = buildPrompt(
      targetColumns: targetColumns,
      rosterNamesHint: rosterHints,
    );

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
    );

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(imageBytes),
              }
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.0,
        'responseMimeType': 'application/json',
      },
    });

    final resp = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (resp.statusCode != 200) {
      throw StateError('خطأ من خادم التعرف البصري (${resp.statusCode}): ${resp.body}');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>? ?? [];
    if (candidates.isEmpty) {
      throw StateError('لم يُرجع النموذج أي نتيجة لهذه الصورة.');
    }
    final textReply =
        candidates.first['content']?['parts']?[0]?['text']?.toString() ?? '{}';

    return parseStructuredJsonReply(
      jsonReply: textReply,
      imageId: imageId,
      imagePath: imagePath,
      roster: roster,
      targetColumns: targetColumns,
    );
  }

  /// Parses model JSON output, runs [StudentMatcher] + [GradeParser], and enforces safety bands.
  static SheetExtraction parseStructuredJsonReply({
    required String jsonReply,
    required String imageId,
    required String imagePath,
    required List<RosterStudent> roster,
    required List<MinistryGradeColumn> targetColumns,
  }) {
    final cleaned = jsonReply
        .replaceAll(RegExp(r'^```json\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^```\s*', multiLine: true), '')
        .trim();

    final map = jsonDecode(cleaned) as Map<String, dynamic>;
    final rawRows = map['rows'] as List<dynamic>? ?? [];
    final matcher = StudentMatcher(roster);
    final extractedRows = <ExtractedRow>[];
    final claimedMatricules = <String, int>{};

    for (var i = 0; i < rawRows.length; i++) {
      final r = rawRows[i] as Map<String, dynamic>;
      final rawName = (r['raw_name'] ?? '').toString().trim();
      final obs = (r['observation'] ?? '').toString().trim();
      final boxList = (r['box'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble().clamp(0.0, 1.0))
              .toList() ??
          [0.0, 0.0, 1.0, 1.0];

      final bbox = boxList.length >= 4
          ? NormalizedBox(y0: boxList[0], x0: boxList[1], y1: boxList[2], x1: boxList[3])
          : const NormalizedBox(x0: 0, y0: 0, x1: 1, y1: 1);

      final matchOutcome = matcher.match(rawName);
      if (matchOutcome.suggestedMatricule != null &&
          matchOutcome.band != ConfidenceBand.red) {
        claimedMatricules[matchOutcome.suggestedMatricule!] =
            (claimedMatricules[matchOutcome.suggestedMatricule!] ?? 0) + 1;
      }

      final rawGrades = r['grades'] as List<dynamic>? ?? [];
      final parsedGrades = <ExtractedGrade>[];

      for (var cIdx = 0; cIdx < targetColumns.length; cIdx++) {
        final targetCol = targetColumns[cIdx];
        Map<String, dynamic>? matchedCell;
        if (cIdx < rawGrades.length) {
          matchedCell = rawGrades[cIdx] as Map<String, dynamic>;
        }
        for (final rg in rawGrades) {
          final m = rg as Map<String, dynamic>;
          if (m['column_code']?.toString().trim() == targetCol.code) {
            matchedCell = m;
            break;
          }
        }

        final rawText = matchedCell?['raw_text']?.toString() ?? '';
        final conf = (matchedCell?['confidence'] as num?)?.toDouble() ?? 0.50;
        final parsed = GradeParser.parse(rawText);

        ConfidenceBand gradeBand;
        if (parsed.status == GradeStatus.invalid ||
            parsed.status == GradeStatus.ambiguous ||
            conf < 0.60) {
          gradeBand = ConfidenceBand.red;
        } else if (parsed.status == GradeStatus.missing ||
            parsed.flags.isNotEmpty ||
            conf < 0.90) {
          gradeBand = ConfidenceBand.orange;
        } else {
          gradeBand = ConfidenceBand.green;
        }

        parsedGrades.add(
          ExtractedGrade(
            columnIndex: cIdx,
            columnLabel: targetCol.label,
            targetMinistryCode: targetCol.code,
            bbox: bbox,
            rawText: rawText,
            status: parsed.status,
            value: parsed.value,
            confidence: conf,
            band: gradeBand,
            flags: parsed.flags,
            candidates: parsed.candidates,
          ),
        );
      }

      var worstBand = matchOutcome.band;
      for (final g in parsedGrades) {
        if (g.band == ConfidenceBand.red) {
          worstBand = ConfidenceBand.red;
        } else if (g.band == ConfidenceBand.orange && worstBand == ConfidenceBand.green) {
          worstBand = ConfidenceBand.orange;
        }
      }

      extractedRows.add(
        ExtractedRow(
          rowIndex: i,
          imageId: imageId,
          rowBbox: bbox,
          rawNameText: rawName,
          observationText: obs,
          candidates: matchOutcome.candidates,
          suggestedMatricule: matchOutcome.suggestedMatricule,
          matchBand: matchOutcome.band,
          band: worstBand,
          flags: [...matchOutcome.flags],
          grades: parsedGrades,
        ),
      );
    }

    for (final row in extractedRows) {
      final mat = row.suggestedMatricule;
      if (mat != null && (claimedMatricules[mat] ?? 0) > 1) {
        row.flags.add('duplicate_student');
      }
    }

    final unmatched = roster
        .where((s) => !claimedMatricules.containsKey(s.matricule))
        .map((s) => s.matricule)
        .toList();

    return SheetExtraction(
      imageId: imageId,
      imagePath: imagePath,
      rows: extractedRows,
      unmatchedMatricules: unmatched,
    );
  }
}

/// Real On-Device ML Kit Text Recognition Provider (100% Offline, Free, Private).
/// Reads real image pixels on the phone. Best for Western digits & printed/Latin names;
/// rows without readable Arabic names are flagged Red/Orange for manual student assignment.
class OnDeviceMlKitOcrProvider implements OcrProvider {
  @override
  String get name => 'MLKit-OnDevice (Offline)';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        offline: true,
        sendsDataOffDevice: false,
        acceptsRosterHints: true,
        supportsArabicHandwriting: false,
      );

  @override
  Future<SheetExtraction> extractSheet({
    required String imageId,
    required String imagePath,
    required Uint8List imageBytes,
    required List<RosterStudent> roster,
    required List<MinistryGradeColumn> targetColumns,
    OcrPrivacyOptions privacy = const OcrPrivacyOptions(),
  }) async {
    if (imagePath.isEmpty || !File(imagePath).existsSync()) {
      throw ArgumentError('ملف الصورة غير موجود للمعالجة المحلية.');
    }

    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final imgW = frame.image.width.toDouble();
    final imgH = frame.image.height.toDouble();
    frame.image.dispose();

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognized = await recognizer.processImage(inputImage);

      final lines = <TextLine>[];
      for (final block in recognized.blocks) {
        lines.addAll(block.lines);
      }
      if (lines.isEmpty) {
        return SheetExtraction(
          imageId: imageId,
          imagePath: imagePath,
          rows: const [],
          warnings: const ['لم يتم اكتشاف أي نص واضح في الصورة. تأكد من الإضاءة أو فعّل الرؤية السحابية.'],
        );
      }

      lines.sort((a, b) => a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy));

      // Cluster horizontal text lines into table rows
      final rowClusters = <List<TextLine>>[];
      for (final line in lines) {
        final cy = line.boundingBox.center.dy;
        final h = line.boundingBox.height.clamp(12.0, 200.0);
        if (rowClusters.isNotEmpty) {
          final prevCenter = rowClusters.last
                  .map((l) => l.boundingBox.center.dy)
                  .reduce((a, b) => a + b) /
              rowClusters.last.length;
          if ((cy - prevCenter).abs() <= h * 0.65) {
            rowClusters.last.add(line);
            continue;
          }
        }
        rowClusters.add([line]);
      }

      final matcher = StudentMatcher(roster);
      final extractedRows = <ExtractedRow>[];

      for (var rIdx = 0; rIdx < rowClusters.length; rIdx++) {
        final cluster = rowClusters[rIdx];
        var minX = imgW, minY = imgH, maxX = 0.0, maxY = 0.0;
        final nameParts = <String>[];
        final numericTokens = <({double cx, String text})>[];

        for (final line in cluster) {
          final rect = line.boundingBox;
          if (rect.left < minX) minX = rect.left;
          if (rect.top < minY) minY = rect.top;
          if (rect.right > maxX) maxX = rect.right;
          if (rect.bottom > maxY) maxY = rect.bottom;

          for (final el in line.elements) {
            final t = el.text.trim();
            if (t.isEmpty) continue;
            final hasDigit = RegExp(r'\d').hasMatch(t);
            if (hasDigit && t.length <= 6) {
              numericTokens.add((cx: el.boundingBox.center.dx, text: t));
            } else if (!hasDigit && t.length >= 2) {
              nameParts.add(t);
            }
          }
        }

        if (numericTokens.isEmpty && nameParts.isEmpty) continue;

        final rawName = nameParts.join(' ');
        final matchOutcome = rawName.isNotEmpty
            ? matcher.match(rawName)
            : const StudentMatchOutcome(
                candidates: [],
                suggestedMatricule: null,
                band: ConfidenceBand.red,
                flags: ['on_device_arabic_name_unreadable'],
              );

        // Sort numeric tokens right-to-left (RTL table order)
        numericTokens.sort((a, b) => b.cx.compareTo(a.cx));

        final rowBox = NormalizedBox(
          x0: (minX / imgW).clamp(0.0, 1.0),
          y0: (minY / imgH).clamp(0.0, 1.0),
          x1: (maxX / imgW).clamp(0.0, 1.0),
          y1: (maxY / imgH).clamp(0.0, 1.0),
        );

        final parsedGrades = <ExtractedGrade>[];
        for (var cIdx = 0; cIdx < targetColumns.length; cIdx++) {
          final col = targetColumns[cIdx];
          final rawText = cIdx < numericTokens.length ? numericTokens[cIdx].text : '';
          final parsed = GradeParser.parse(rawText);

          // On-device ML Kit does not expose per-token calibrated confidence -> cap at orange
          final band = (parsed.status == GradeStatus.invalid || parsed.status == GradeStatus.ambiguous)
              ? ConfidenceBand.red
              : ConfidenceBand.orange;

          parsedGrades.add(
            ExtractedGrade(
              columnIndex: cIdx,
              columnLabel: col.label,
              targetMinistryCode: col.code,
              bbox: rowBox,
              rawText: rawText,
              status: parsed.status,
              value: parsed.value,
              confidence: 0.72,
              band: band,
              flags: [...parsed.flags, 'on_device_mlkit'],
              candidates: parsed.candidates,
            ),
          );
        }

        final worstBand = (matchOutcome.band == ConfidenceBand.red ||
                parsedGrades.any((g) => g.band == ConfidenceBand.red))
            ? ConfidenceBand.red
            : ConfidenceBand.orange;

        extractedRows.add(
          ExtractedRow(
            rowIndex: extractedRows.length,
            imageId: imageId,
            rowBbox: rowBox,
            rawNameText: rawName,
            candidates: matchOutcome.candidates,
            suggestedMatricule: matchOutcome.suggestedMatricule,
            matchBand: matchOutcome.band,
            band: worstBand,
            flags: matchOutcome.flags,
            grades: parsedGrades,
          ),
        );
      }

      return SheetExtraction(
        imageId: imageId,
        imagePath: imagePath,
        rows: extractedRows,
        warnings: const [
          'تمت المعالجة محلياً بدون إنترنت: يرجى مطابقة الأسماء العربية يدوياً ومراجعة النقاط.',
        ],
      );
    } finally {
      await recognizer.close();
    }
  }
}
