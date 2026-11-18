import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/logic/export_gate.dart';
import '../../domain/models/extraction_models.dart';
import '../local/app_database.dart';
import '../services/ministry_excel_service.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final classroomRepositoryProvider = Provider<ClassroomRepository>((ref) {
  return ClassroomRepository(ref.watch(appDatabaseProvider));
});

class ImportWorkbookResult {
  final int classesImported;
  final int totalStudents;
  final String savedTemplatePath;

  const ImportWorkbookResult({
    required this.classesImported,
    required this.totalStudents,
    required this.savedTemplatePath,
  });
}

class ClassroomRepository {
  final AppDatabase _db;

  ClassroomRepository(this._db);

  Stream<List<ClassRoom>> watchClasses() => _db.watchAllClasses();

  Future<List<Student>> getStudents(int classId) => _db.getStudentsForClass(classId);

  Stream<List<StudentGrade>> watchGrades(int classId) => _db.watchGradesForClass(classId);

  Future<void> deleteClass(int classId) => _db.deleteClass(classId);

  /// Copies the official Ministry `.xlsx` file into app private storage, parses every
  /// class sheet (3, 6, or more), and persists classes, students, and any existing grades.
  Future<ImportWorkbookResult> importMinistryExcel({
    required Uint8List fileBytes,
    required String originalFileName,
  }) async {
    final schemas = MinistryExcelService.parseWorkbook(fileBytes);
    if (schemas.isEmpty) {
      throw const FormatException(
        'لم يتم العثور على أي فوج صالح داخل الملف. تأكد من أنه ملف حجز النقاط الرسمي للوزارة (.xlsx).',
      );
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final templatesDir = Directory(p.join(docsDir.path, 'ministry_templates'));
    if (!templatesDir.existsSync()) {
      templatesDir.createSync(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final safeName = originalFileName.replaceAll(RegExp(r'[^a-zA-Z0-9؀-ۿ._-]'), '_');
    final savedFile = File(p.join(templatesDir.path, '${timestamp}_$safeName'));
    await savedFile.writeAsBytes(fileBytes, flush: true);

    var totalStudents = 0;

    for (final schema in schemas) {
      final colsJson = jsonEncode(schema.gradeColumns.map((c) => c.toJson()).toList());
      final classId = await _db.insertClass(
        SchoolClassesCompanion.insert(
          sheetName: schema.sheetName,
          displayName: schema.groupLabel,
          academicYear: schema.academicYear,
          termName: schema.termName,
          subjectName: schema.subjectName,
          sourceTemplatePath: Value(savedFile.path),
          gradeColumnsJson: colsJson,
        ),
      );

      final studentRows = schema.students
          .map(
            (s) => StudentsCompanion.insert(
              classId: classId,
              matricule: s.matricule,
              officialOrder: s.officialOrder,
              lastName: s.lastName,
              firstName: s.firstName,
              birthDate: Value(s.birthDate),
            ),
          )
          .toList();

      await _db.insertStudentsBatch(studentRows);
      totalStudents += studentRows.length;

      for (final g in schema.existingGrades) {
        await _db.upsertGrade(
          classId: classId,
          matricule: g.matricule,
          columnCode: g.columnCode,
          status: g.status,
          numericValue: g.numericValue,
          observation: schema.existingObservations[g.matricule],
          source: 'excel_import',
        );
      }
    }

    return ImportWorkbookResult(
      classesImported: schemas.length,
      totalStudents: totalStudents,
      savedTemplatePath: savedFile.path,
    );
  }

  Future<void> saveManualGrade({
    required int classId,
    required String matricule,
    required String columnCode,
    required String status,
    double? numericValue,
    String? observation,
  }) async {
    await _db.upsertGrade(
      classId: classId,
      matricule: matricule,
      columnCode: columnCode,
      status: status,
      numericValue: numericValue,
      observation: observation,
      source: 'manual',
    );
  }


  /// Saves an approved or edited pedagogical observation for a student.
  /// Stored on the first grade column record so it exports cleanly to Ministry `obs` column.
  Future<void> saveStudentObservation({
    required int classId,
    required String matricule,
    required String primaryColumnCode,
    required String observation,
  }) async {
    final existing = await _db.getGradesForClass(classId);
    final match = existing
        .where((g) => g.matricule == matricule && g.columnCode == primaryColumnCode)
        .firstOrNull;

    await _db.upsertGrade(
      classId: classId,
      matricule: matricule,
      columnCode: primaryColumnCode,
      status: match?.status ?? 'missing',
      numericValue: match?.numericValue,
      observation: observation.trim(),
      source: match?.source ?? 'manual',
    );
  }

  /// Commits verified OCR grades into the local SQLite database after checking [ExportGateService].
  Future<int> commitVerifiedExtraction({
    required int classId,
    required SheetExtraction extraction,
    required Map<String, String> labelToCode,
  }) async {
    final gate = ExportGateService.evaluate(extraction);
    if (!gate.ok) {
      throw StateError('لا يمكن حفظ النتائج قبل تأكيد جميع السطور والنقاط غير المؤكدة.');
    }

    var savedCount = 0;
    for (final row in extraction.rows) {
      final mat = ExportGateService.resolvedMatricule(row);
      if (mat == null) continue;

      for (final g in row.grades) {
        final code = g.targetMinistryCode ?? labelToCode[g.columnLabel];
        if (code == null) continue;

        final statusStr = g.effectiveStatus.name;
        final val = g.effectiveStatus == GradeStatus.value ? g.effectiveValue : null;
        await _db.upsertGrade(
          classId: classId,
          matricule: mat,
          columnCode: code,
          status: statusStr,
          numericValue: val,
          source: g.verification == VerificationStatus.corrected ? 'ocr_corrected' : 'ocr_confirmed',
        );
        savedCount++;
      }
    }
    return savedCount;
  }

  /// Generates a ready-to-upload Ministry `.xlsx` file for the given class.
  Future<File> exportClassToMinistryExcel(int classId) async {
    final clazz = await _db.getClassById(classId);
    if (clazz == null) {
      throw StateError('الفوج التربوي غير موجود.');
    }
    final templatePath = clazz.sourceTemplatePath;
    if (templatePath == null || !File(templatePath).existsSync()) {
      throw StateError('ملف القالب الأصلي للوزارة غير متوفر لهذا الفوج.');
    }

    final templateBytes = await File(templatePath).readAsBytes();
    final dbGrades = await _db.getGradesForClass(classId);

    final gradesMap = <String, Map<String, double?>>{};
    final obsMap = <String, String>{};

    for (final g in dbGrades) {
      gradesMap.putIfAbsent(g.matricule, () => {});
      gradesMap[g.matricule]![g.columnCode] = g.status == 'value' ? g.numericValue : null;
      if (g.observation != null && g.observation!.trim().isNotEmpty) {
        obsMap[g.matricule] = g.observation!.trim();
      }
    }

    final updatedBytes = MinistryExcelService.exportClassGradesFromDatabase(
      templateBytes: templateBytes,
      sheetName: clazz.sheetName,
      gradesByMatriculeAndCode: gradesMap,
      observationsByMatricule: obsMap,
    );

    final docsDir = await getApplicationDocumentsDirectory();
    final exportsDir = Directory(p.join(docsDir.path, 'exports'));
    if (!exportsDir.existsSync()) {
      exportsDir.createSync(recursive: true);
    }
    final cleanGroup = clazz.displayName.replaceAll(RegExp(r'[^\w؀-ۿ-]+'), '_');
    final outFile = File(p.join(exportsDir.path, 'رقمنة_${cleanGroup}_${clazz.sheetName}.xlsx'));
    await outFile.writeAsBytes(updatedBytes, flush: true);
    return outFile;
  }
}
