import "package:smart_teacher_dz/data/services/ocr_provider.dart";
import 'dart:convert';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_teacher_dz/data/local/app_database.dart';
import 'package:smart_teacher_dz/data/repositories/classroom_repository.dart';
import 'package:smart_teacher_dz/data/services/backup_service.dart';
import 'package:smart_teacher_dz/data/services/ministry_excel_service.dart';
import 'package:smart_teacher_dz/data/services/ocr_provider.dart';
import 'package:smart_teacher_dz/domain/logic/export_gate.dart';
import 'package:smart_teacher_dz/domain/logic/grade_calculator.dart';
import 'package:smart_teacher_dz/domain/logic/grade_parser.dart';
import 'package:smart_teacher_dz/domain/logic/name_normalizer.dart';
import 'package:smart_teacher_dz/domain/logic/student_matcher.dart';
import 'package:smart_teacher_dz/domain/models/extraction_models.dart';

void main() {
  test('NameNormalizer handles Arabic-Indic digits and hamza/ta-marbuta folding', () {
    expect(NameNormalizer.normalizeDigits('١٢،٥'), '12,5');
    expect(NameNormalizer.arabicTokens('أحمد بن علي'), NameNormalizer.arabicTokens('احمد بنعلي'));
  });

  test('GradeParser flags lost decimal separator as ambiguous instead of guessing', () {
    final res = GradeParser.parse('125');
    expect(res.status, GradeStatus.ambiguous);
    expect(res.value, isNull);
    expect(res.candidates.map((c) => c.value), contains(12.5));
  });

  test('ExportGate blocks unconfirmed rows and unblocks once confirmed', () {
    final grade = ExtractedGrade(
      columnIndex: 0,
      columnLabel: 'الفرض /20',
      targetMinistryCode: '04',
      bbox: const NormalizedBox(x0: 0.1, y0: 0.1, x1: 0.2, y1: 0.2),
      rawText: '14,5',
      status: GradeStatus.value,
      value: 14.5,
      confidence: 0.75,
      band: ConfidenceBand.orange,
    );
    final row = ExtractedRow(
      rowIndex: 0,
      imageId: 'img_1',
      rowBbox: const NormalizedBox(x0: 0, y0: 0.1, x1: 1, y1: 0.2),
      rawNameText: 'أحمد رانيا',
      suggestedMatricule: '1101444010533100',
      matchBand: ConfidenceBand.orange,
      band: ConfidenceBand.orange,
      grades: [grade],
    );
    final sheet = SheetExtraction(imageId: 'img_1', imagePath: '', rows: [row]);

    expect(ExportGateService.evaluate(sheet).ok, isFalse);

    row.confirmedMatricule = row.suggestedMatricule;
    row.verification = VerificationStatus.confirmed;
    grade.verification = VerificationStatus.confirmed;

    expect(ExportGateService.evaluate(sheet).ok, isTrue);
  });

  test('MinistryExcelService parses and exports grades while preserving hidden metadata rows', () {
    final excel = Excel.createExcel();
    final sheet = excel['2100001'];
    excel.delete('Sheet1');

    sheet.cell(CellIndex.indexByString('A5')).value = TextCellValue(
      'وثيقة حجز النقاط الخاصة بـ:الفصل الثالث السنة الدراسية : 2025-2026 الفوج التربوي : أولى متوسط 1 مادة : ع الفيزيائية والتكنولوجيا',
    );
    sheet.cell(CellIndex.indexByString('A6')).value = IntCellValue(2100001);
    final codes = ['matricule', 'nom', 'prenom', 'date_n', '01', '04', '09', 'obs'];
    final labels = ['رقم التعريف', 'اللقب', 'الاسم', 'تاريخ الميلاد', 'التقويم /20', 'الفرض /20', 'الاختبار /20', 'التقديرات'];
    for (var c = 0; c < codes.length; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 6)).value = TextCellValue(codes[c]);
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 7)).value = TextCellValue(labels[c]);
    }
    sheet.cell(CellIndex.indexByString('A9')).value = TextCellValue('1101444010533100');
    sheet.cell(CellIndex.indexByString('B9')).value = TextCellValue('أحمد');
    sheet.cell(CellIndex.indexByString('C9')).value = TextCellValue('رانيا');

    final rawBytes = Uint8List.fromList(excel.encode()!);
    final schemas = MinistryExcelService.parseWorkbook(rawBytes);
    expect(schemas.length, 1);
    expect(schemas.first.groupLabel, 'أولى متوسط 1');
    expect(schemas.first.students.first.fullName, 'أحمد رانيا');

    final updatedBytes = MinistryExcelService.exportClassGradesFromDatabase(
      templateBytes: rawBytes,
      sheetName: '2100001',
      gradesByMatriculeAndCode: {
        '1101444010533100': {'04': 16.5, '09': 18.0},
      },
      observationsByMatricule: {'1101444010533100': 'ممتاز'},
    );

    final reloaded = Excel.decodeBytes(updatedBytes);
    final outSheet = reloaded['2100001'];
    expect(outSheet.cell(CellIndex.indexByString('A7')).value.toString(), 'matricule');
    expect(outSheet.cell(CellIndex.indexByString('F9')).value.toString(), contains('16.5'));
    expect(outSheet.cell(CellIndex.indexByString('G9')).value.toString(), contains('18'));
    expect(outSheet.cell(CellIndex.indexByString('H9')).value.toString(), 'ممتاز');
  });

  test('MinistryGradeCalculator computes standard Middle/Secondary & Two-Devoir averages accurately', () {
    final colsStandard = [
      const MinistryGradeColumn(colIndex: 4, code: '01', label: 'التقويم /20'),
      const MinistryGradeColumn(colIndex: 5, code: '04', label: 'الفرض /20'),
      const MinistryGradeColumn(colIndex: 6, code: '09', label: 'الاختبار /20'),
    ];

    final now = DateTime.now();
    final grades = {
      '01': StudentGrade(id: 1, classId: 1, matricule: 'M1', columnCode: '01', status: 'value', numericValue: 14.0, source: 'manual', updatedAt: now),
      '04': StudentGrade(id: 2, classId: 1, matricule: 'M1', columnCode: '04', status: 'value', numericValue: 16.0, source: 'manual', updatedAt: now),
      '09': StudentGrade(id: 3, classId: 1, matricule: 'M1', columnCode: '09', status: 'value', numericValue: 12.0, source: 'manual', updatedAt: now),
    };

    final res = MinistryGradeCalculator.computeStudentAverage(
      gradesByCode: grades,
      columns: colsStandard,
      config: GradingFormulaConfig.inferFromColumns(colsStandard),
    );
    expect(res.continuous, 15.0);
    expect(res.termAvg, 13.0);
    expect(res.complete, isTrue);
  });

  test('StudentMatcher blocks sibling surname-only ambiguity from turning green', () {
    const roster = [
      RosterStudent(matricule: 'M1', officialOrder: 1, lastName: 'بن حليمة', firstName: 'محمد'),
      RosterStudent(matricule: 'M2', officialOrder: 2, lastName: 'بن حليمة', firstName: 'أبو بكر'),
      RosterStudent(matricule: 'M3', officialOrder: 3, lastName: 'أحمد', firstName: 'رانيا'),
    ];
    const matcher = StudentMatcher(roster);

    final ambiguousRes = matcher.match('بن حليمة');
    expect(ambiguousRes.band, isNot(ConfidenceBand.green));
    expect(ambiguousRes.flags, isNotEmpty);

    final exactRes = matcher.match('احمد رانيا');
    expect(exactRes.band, ConfidenceBand.green);
    expect(exactRes.suggestedMatricule, 'M3');
  });

  test('VisionLlmOcrProvider parses structured JSON and flags lost decimal separators as red', () {
    const roster = [
      RosterStudent(matricule: 'M1', officialOrder: 1, lastName: 'أحمد', firstName: 'رانيا'),
    ];
    const cols = [
      MinistryGradeColumn(colIndex: 5, code: '04', label: 'الفرض /20'),
    ];
    const fakeReply = '''
    {
      "rows": [
        {
          "raw_name": "احمد رانيا",
          "box": [0.1, 0.1, 0.2, 0.9],
          "grades": [
            {"column_code": "04", "raw_text": "145", "confidence": 0.92}
          ],
          "observation": ""
        }
      ]
    }
    ''';

    final extraction = VisionLlmOcrProvider.parseStructuredJsonReply(
      jsonReply: fakeReply,
      imageId: 'test_img',
      imagePath: '',
      roster: roster,
      targetColumns: cols,
    );

    expect(extraction.rows.length, 1);
    expect(extraction.rows.first.suggestedMatricule, 'M1');
    expect(extraction.rows.first.grades.first.status, GradeStatus.ambiguous);
    expect(extraction.rows.first.grades.first.band, ConfidenceBand.red);
    expect(ExportGateService.evaluate(extraction).ok, isFalse);
  });

  test('In-memory Drift database + BackupService roundtrip preserves classes, students, grades, and scan sessions', () async {
    final db1 = AppDatabase(NativeDatabase.memory());
    final classId = await db1.insertClass(
      SchoolClassesCompanion.insert(
        sheetName: '2100001',
        displayName: 'أولى متوسط 1',
        academicYear: '2025-2026',
        termName: 'الفصل الثالث',
        subjectName: 'ع الفيزيائية',
        gradeColumnsJson: '[{"colIndex":5,"code":"04","label":"الفرض /20"}]',
      ),
    );
    await db1.insertStudentsBatch([
      StudentsCompanion.insert(
        classId: classId,
        matricule: '1101444010533100',
        officialOrder: 1,
        lastName: 'أحمد',
        firstName: 'رانيا',
      ),
    ]);
    await db1.upsertGrade(
      classId: classId,
      matricule: '1101444010533100',
      columnCode: '04',
      status: 'value',
      numericValue: 15.5,
      observation: 'عمل جيد',
      source: 'ocr_confirmed',
    );
    await db1.logScanSession(
      classId: classId,
      providerName: 'VisionLLM (gemini-2.5-flash)',
      rowsExtracted: 1,
      gradesCommitted: 1,
      photoDeleted: true,
    );

    final payload = await BackupService.buildBackupPayload(db1);
    final rawJson = jsonEncode(payload);
    await db1.close();

    final db2 = AppDatabase(NativeDatabase.memory());
    final summary = await BackupService.restoreFromJson(db2, rawJson);
    expect(summary.classesRestored, 1);
    expect(summary.studentsRestored, 1);
    expect(summary.gradesRestored, 1);

    final restoredClasses = await db2.getAllClasses();
    expect(restoredClasses.first.displayName, 'أولى متوسط 1');
    final restoredGrades = await db2.getGradesForClass(restoredClasses.first.id);
    expect(restoredGrades.first.numericValue, 15.5);
    expect(restoredGrades.first.observation, 'عمل جيد');
    await db2.close();
  });
}
