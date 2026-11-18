import 'dart:typed_data';
import 'package:excel/excel.dart';
import '../../domain/logic/export_gate.dart';
import '../../domain/models/extraction_models.dart';

class MinistryGradeColumn {
  final int colIndex; // 0-based in `excel` package
  final String code;  // '01', '04', '09'
  final String label; // 'الفرض /20'

  const MinistryGradeColumn({
    required this.colIndex,
    required this.code,
    required this.label,
  });

  Map<String, dynamic> toJson() => {
        'colIndex': colIndex,
        'code': code,
        'label': label,
      };

  factory MinistryGradeColumn.fromJson(Map<String, dynamic> json) {
    return MinistryGradeColumn(
      colIndex: json['colIndex'] as int,
      code: json['code'] as String,
      label: json['label'] as String,
    );
  }
}

class ImportedStudentGrade {
  final String matricule;
  final String columnCode;
  final String status; // 'value' | 'missing'
  final double? numericValue;
  final String? observation;

  const ImportedStudentGrade({
    required this.matricule,
    required this.columnCode,
    required this.status,
    this.numericValue,
    this.observation,
  });
}

class MinistrySheetSchema {
  final String sheetName;
  final String titleBanner;
  final String academicYear;
  final String termName;
  final String subjectName;
  final String groupLabel;
  final int codeRow;      // usually index 6 (Row 7 in Excel)
  final int headerRow;    // usually index 7 (Row 8 in Excel)
  final int dataStartRow; // usually index 8 (Row 9 in Excel)
  final int matriculeCol;
  final int nomCol;
  final int prenomCol;
  final int? dateNCol;
  final int? obsCol;
  final List<MinistryGradeColumn> gradeColumns;
  final List<RosterStudent> students;
  final List<ImportedStudentGrade> existingGrades;
  final Map<String, String> existingObservations;

  const MinistrySheetSchema({
    required this.sheetName,
    required this.titleBanner,
    required this.academicYear,
    required this.termName,
    required this.subjectName,
    required this.groupLabel,
    required this.codeRow,
    required this.headerRow,
    required this.dataStartRow,
    required this.matriculeCol,
    required this.nomCol,
    required this.prenomCol,
    this.dateNCol,
    this.obsCol,
    required this.gradeColumns,
    required this.students,
    this.existingGrades = const [],
    this.existingObservations = const {},
  });
}

/// Reads and writes official Algerian Ministry of Education `.xlsx` templates
/// while preserving hidden metadata rows (Rows 6 & 7) and untouched sheets.
class MinistryExcelService {
  static const Set<String> _identityCodes = {'matricule', 'nom', 'prenom', 'date_n'};

  static ({String year, String term, String subject, String group}) _parseBanner(
    String banner,
    String fallbackName,
  ) {
    final termMatch = RegExp(r'الخاصة بـ\s*:?\s*(.+?)\s+السنة الدراسية').firstMatch(banner);
    final yearMatch = RegExp(r'السنة الدراسية\s*:?\s*([0-9\-/]+)').firstMatch(banner);
    final groupMatch = RegExp(r'الفوج التربوي\s*:?\s*(.+?)\s+مادة\s*:').firstMatch(banner);
    final subjMatch = RegExp(r'مادة\s*:?\s*(.+)$').firstMatch(banner);

    final rawGroup = groupMatch?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return (
      year: yearMatch?.group(1)?.trim() ?? '',
      term: termMatch?.group(1)?.trim() ?? '',
      subject: subjMatch?.group(1)?.trim() ?? '',
      group: (rawGroup != null && rawGroup.isNotEmpty) ? rawGroup : fallbackName,
    );
  }

  static List<MinistrySheetSchema> parseWorkbook(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    final schemas = <MinistrySheetSchema>[];

    for (final entry in excel.tables.entries) {
      final sheetName = entry.key;
      final sheet = entry.value;
      if (sheet.maxRows < 9) continue;

      int? detectedCodeRow;
      final codeMap = <String, int>{};

      for (var r = 0; r < sheet.maxRows && r < 20; r++) {
        codeMap.clear();
        for (var c = 0; c < sheet.maxColumns; c++) {
          final val = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).value;
          if (val != null) {
            final key = val.toString().trim().toLowerCase();
            if (key.isNotEmpty) codeMap[key] = c;
          }
        }
        if (codeMap.containsKey('matricule') &&
            codeMap.containsKey('nom') &&
            codeMap.containsKey('prenom')) {
          detectedCodeRow = r;
          break;
        }
      }

      if (detectedCodeRow == null) continue;

      final headerRow = detectedCodeRow + 1;
      final dataStartRow = headerRow + 1;
      final bannerRow = detectedCodeRow >= 2 ? detectedCodeRow - 2 : 0;
      final banner = sheet
              .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: bannerRow))
              .value
              ?.toString()
              .trim() ??
          sheetName;
      final parsedMeta = _parseBanner(banner, sheetName);

      final gradeCols = <MinistryGradeColumn>[];
      for (var c = 0; c < sheet.maxColumns; c++) {
        final rawCode =
            sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: detectedCodeRow)).value;
        if (rawCode == null) continue;
        final code = rawCode.toString().trim();
        if (code.isEmpty || _identityCodes.contains(code.toLowerCase()) || code.toLowerCase() == 'obs') {
          continue;
        }
        final label = sheet
                .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: headerRow))
                .value
                ?.toString()
                .trim() ??
            code;
        gradeCols.add(MinistryGradeColumn(colIndex: c, code: code, label: label));
      }

      final students = <RosterStudent>[];
      final existingGrades = <ImportedStudentGrade>[];
      final existingObs = <String, String>{};
      final obsCol = codeMap['obs'];
      final dateNCol = codeMap['date_n'];

      var order = 0;
      for (var r = dataStartRow; r < sheet.maxRows; r++) {
        final mat = sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: codeMap['matricule']!, rowIndex: r))
            .value
            ?.toString()
            .trim();
        final nom = sheet
                .cell(CellIndex.indexByColumnRow(columnIndex: codeMap['nom']!, rowIndex: r))
                .value
                ?.toString()
                .trim() ??
            '';
        final prenom = sheet
                .cell(CellIndex.indexByColumnRow(columnIndex: codeMap['prenom']!, rowIndex: r))
                .value
                ?.toString()
                .trim() ??
            '';
        if ((mat == null || mat.isEmpty) && nom.isEmpty) continue;
        final cleanMat = (mat != null && mat.isNotEmpty) ? mat : 'row_$r';
        final birthDate = dateNCol != null
            ? sheet
                .cell(CellIndex.indexByColumnRow(columnIndex: dateNCol, rowIndex: r))
                .value
                ?.toString()
                .trim()
            : null;

        order++;
        students.add(RosterStudent(
          matricule: cleanMat,
          officialOrder: order,
          lastName: nom,
          firstName: prenom,
          birthDate: birthDate,
        ));

        for (final gc in gradeCols) {
          final cellVal =
              sheet.cell(CellIndex.indexByColumnRow(columnIndex: gc.colIndex, rowIndex: r)).value;
          if (cellVal != null) {
            final numVal = double.tryParse(cellVal.toString().replaceAll(',', '.').trim());
            if (numVal != null) {
              existingGrades.add(ImportedStudentGrade(
                matricule: cleanMat,
                columnCode: gc.code,
                status: 'value',
                numericValue: numVal,
              ));
            }
          }
        }

        if (obsCol != null) {
          final obsVal =
              sheet.cell(CellIndex.indexByColumnRow(columnIndex: obsCol, rowIndex: r)).value;
          if (obsVal != null && obsVal.toString().trim().isNotEmpty) {
            existingObs[cleanMat] = obsVal.toString().trim();
          }
        }
      }

      schemas.add(MinistrySheetSchema(
        sheetName: sheetName,
        titleBanner: banner,
        academicYear: parsedMeta.year,
        termName: parsedMeta.term,
        subjectName: parsedMeta.subject,
        groupLabel: parsedMeta.group,
        codeRow: detectedCodeRow,
        headerRow: headerRow,
        dataStartRow: dataStartRow,
        matriculeCol: codeMap['matricule']!,
        nomCol: codeMap['nom']!,
        prenomCol: codeMap['prenom']!,
        dateNCol: dateNCol,
        obsCol: obsCol,
        gradeColumns: gradeCols,
        students: students,
        existingGrades: existingGrades,
        existingObservations: existingObs,
      ));
    }

    return schemas;
  }

  /// Writes confirmed grades from [SheetExtraction] into the official workbook bytes
  /// after enforcing [ExportGateService].
  static Uint8List exportVerifiedGrades({
    required Uint8List templateBytes,
    required String sheetName,
    required SheetExtraction extraction,
    required Map<String, String> columnMapping,
  }) {
    final gate = ExportGateService.evaluate(extraction);
    if (!gate.ok) {
      throw StateError('Export blocked by safety gate: ${gate.blockers.length} unresolved items.');
    }

    final schemas = {for (final s in parseWorkbook(templateBytes)) s.sheetName: s};
    final schema = schemas[sheetName];
    if (schema == null) {
      throw ArgumentError('Sheet $sheetName not found in template.');
    }

    final excel = Excel.decodeBytes(templateBytes);
    final sheet = excel[sheetName];

    final matriculeToRow = <String, int>{};
    for (var r = schema.dataStartRow; r < sheet.maxRows; r++) {
      final mat = sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: schema.matriculeCol, rowIndex: r))
          .value
          ?.toString()
          .trim();
      if (mat != null && mat.isNotEmpty) {
        matriculeToRow[mat] = r;
      }
    }

    final codeToCol = {for (final gc in schema.gradeColumns) gc.code: gc.colIndex};

    for (final row in extraction.rows) {
      final mat = ExportGateService.resolvedMatricule(row);
      if (mat == null || !matriculeToRow.containsKey(mat)) continue;
      final excelRow = matriculeToRow[mat]!;

      for (final g in row.grades) {
        final targetCode = g.targetMinistryCode ?? columnMapping[g.columnLabel];
        if (targetCode == null || !codeToCol.containsKey(targetCode)) continue;
        final colIdx = codeToCol[targetCode]!;

        final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: colIdx, rowIndex: excelRow));
        if (g.effectiveStatus == GradeStatus.value && g.effectiveValue != null) {
          cell.value = DoubleCellValue(g.effectiveValue!);
        } else {
          cell.value = null;
        }
      }
    }

    final encoded = excel.encode();
    if (encoded == null) {
      throw StateError('Failed to encode updated Excel workbook.');
    }
    return Uint8List.fromList(encoded);
  }

  /// Exports all stored database grades & observations for a class back into its
  /// original Ministry `.xlsx` workbook while preserving all other sheets intact.
  static Uint8List exportClassGradesFromDatabase({
    required Uint8List templateBytes,
    required String sheetName,
    required Map<String, Map<String, double?>> gradesByMatriculeAndCode,
    Map<String, String> observationsByMatricule = const {},
  }) {
    final schemas = {for (final s in parseWorkbook(templateBytes)) s.sheetName: s};
    final schema = schemas[sheetName];
    if (schema == null) {
      throw ArgumentError('Sheet $sheetName not found in template.');
    }

    final excel = Excel.decodeBytes(templateBytes);
    final sheet = excel[sheetName];

    final matriculeToRow = <String, int>{};
    for (var r = schema.dataStartRow; r < sheet.maxRows; r++) {
      final mat = sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: schema.matriculeCol, rowIndex: r))
          .value
          ?.toString()
          .trim();
      if (mat != null && mat.isNotEmpty) {
        matriculeToRow[mat] = r;
      }
    }

    final codeToCol = {for (final gc in schema.gradeColumns) gc.code: gc.colIndex};

    gradesByMatriculeAndCode.forEach((mat, colGrades) {
      final excelRow = matriculeToRow[mat];
      if (excelRow == null) return;

      colGrades.forEach((code, val) {
        final colIdx = codeToCol[code];
        if (colIdx == null) return;
        final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: colIdx, rowIndex: excelRow));
        cell.value = val != null ? DoubleCellValue(val) : null;
      });
    });

    if (schema.obsCol != null) {
      observationsByMatricule.forEach((mat, obs) {
        final excelRow = matriculeToRow[mat];
        if (excelRow == null) return;
        final cell =
            sheet.cell(CellIndex.indexByColumnRow(columnIndex: schema.obsCol!, rowIndex: excelRow));
        cell.value = obs.trim().isNotEmpty ? TextCellValue(obs.trim()) : null;
      });
    }

    final encoded = excel.encode();
    if (encoded == null) {
      throw StateError('Failed to encode updated Excel workbook.');
    }
    return Uint8List.fromList(encoded);
  }
}
