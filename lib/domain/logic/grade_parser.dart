import '../models/extraction_models.dart';
import 'name_normalizer.dart';

class GradeRules {
  final double minValue;
  final double maxValue;
  final double? step;
  final Set<String> absentMarkers;
  final Set<String> excusedMarkers;
  final Set<String> missingMarkers;

  const GradeRules({
    this.minValue = 0.0,
    this.maxValue = 20.0,
    this.step,
    this.absentMarkers = const {'abs', 'absent', 'absente', 'غ', 'غائب', 'غائبة', 'غياب', 'غايب'},
    this.excusedMarkers = const {'disp', 'dispense', 'dispensé', 'معفى', 'معفي'},
    this.missingMarkers = const {'-', '--', '—', '–', '_', '/', '\\', 'x', '×', 'nn', 'n.n'},
  });
}

class ParsedGradeResult {
  final GradeStatus status;
  final double? value;
  final List<String> flags;
  final List<GradeCandidate> candidates;

  const ParsedGradeResult({
    required this.status,
    this.value,
    this.flags = const [],
    this.candidates = const [],
  });
}

/// Configurable grade parser matching `stocr/grade_parser.py`.
/// Never guesses silently when a decimal separator is lost (e.g. "125" -> candidates 12.5 / 1.25).
class GradeParser {
  static ParsedGradeResult parse(String? raw, [GradeRules rules = const GradeRules()]) {
    final text = NameNormalizer.normalizeDigits(raw ?? '').trim();
    if (text.isEmpty) {
      return const ParsedGradeResult(status: GradeStatus.missing);
    }

    final normMarker = NameNormalizer.normalizeArabic(text).toLowerCase().replaceAll(RegExp(r'[.:،,\s]+$'), '');
    if (rules.absentMarkers.contains(normMarker) || rules.absentMarkers.contains(text.toLowerCase())) {
      return const ParsedGradeResult(status: GradeStatus.absent);
    }
    if (rules.excusedMarkers.contains(normMarker) || rules.excusedMarkers.contains(text.toLowerCase())) {
      return const ParsedGradeResult(status: GradeStatus.excused);
    }
    if (rules.missingMarkers.contains(normMarker) || rules.missingMarkers.contains(text.toLowerCase())) {
      return const ParsedGradeResult(status: GradeStatus.missing);
    }

    final core = text.replaceAll(RegExp(r'\s+'), '').replaceAll(',', '.');
    final parsed = double.tryParse(core);
    if (parsed == null || parsed.isNaN || parsed.isInfinite) {
      return const ParsedGradeResult(status: GradeStatus.invalid, flags: ['unparseable']);
    }

    if (parsed < rules.minValue || parsed > rules.maxValue) {
      // Check if it is an integer with a lost decimal separator (e.g. "125" -> 12.5 or 1.25)
      if (RegExp(r'^\d+$').hasMatch(core) && core.length >= 2) {
        final cands = <GradeCandidate>[];
        for (var pos = 1; pos < core.length; pos++) {
          final candidateStr = '${core.substring(0, pos)}.${core.substring(pos)}';
          final v = double.tryParse(candidateStr);
          if (v != null && v >= rules.minValue && v <= rules.maxValue) {
            cands.add(GradeCandidate(
              status: GradeStatus.value,
              value: v,
              text: candidateStr,
              source: 'parser',
            ));
          }
        }
        if (cands.isNotEmpty) {
          return ParsedGradeResult(
            status: GradeStatus.ambiguous,
            flags: const ['out_of_range_maybe_lost_separator'],
            candidates: cands,
          );
        }
      }
      return const ParsedGradeResult(status: GradeStatus.invalid, flags: ['out_of_range']);
    }

    final softFlags = <String>[];
    if (rules.step != null && rules.step! > 0) {
      final rem = (parsed / rules.step!).round() * rules.step! - parsed;
      if (rem.abs() > 1e-6) {
        softFlags.add('off_step');
      }
    }

    return ParsedGradeResult(
      status: GradeStatus.value,
      value: parsed,
      flags: softFlags,
      candidates: [
        GradeCandidate(status: GradeStatus.value, value: parsed, text: core, source: 'primary'),
      ],
    );
  }
}
