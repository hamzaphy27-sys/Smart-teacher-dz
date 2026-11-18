import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../local/app_database.dart';

class BackupRestoreSummary {
  final int classesRestored;
  final int studentsRestored;
  final int gradesRestored;

  const BackupRestoreSummary({
    required this.classesRestored,
    required this.studentsRestored,
    required this.gradesRestored,
  });
}

/// Exports and restores a complete offline JSON backup of all teacher classes,
/// official student rosters, grades, observations, and profile settings.
class BackupService {
  static Future<Map<String, dynamic>> buildBackupPayload(AppDatabase db) async {
    final profile = await db.getTeacherProfile();
    final allClasses = await db.getAllClasses();
    final exportedClasses = <Map<String, dynamic>>[];

    for (final c in allClasses) {
      final stList = await db.getStudentsForClass(c.id);
      final grList = await db.getGradesForClass(c.id);

      exportedClasses.add({
        'sheetName': c.sheetName,
        'displayName': c.displayName,
        'academicYear': c.academicYear,
        'termName': c.termName,
        'subjectName': c.subjectName,
        'gradeColumnsJson': c.gradeColumnsJson,
        'students': stList
            .map((s) => {
                  'matricule': s.matricule,
                  'officialOrder': s.officialOrder,
                  'lastName': s.lastName,
                  'firstName': s.firstName,
                  'birthDate': s.birthDate,
                  'aliasesJson': s.aliasesJson,
                })
            .toList(),
        'grades': grList
            .map((g) => {
                  'matricule': g.matricule,
                  'columnCode': g.columnCode,
                  'status': g.status,
                  'numericValue': g.numericValue,
                  'observation': g.observation,
                  'source': g.source,
                })
            .toList(),
      });
    }

    return {
      'app': 'SmartTeacherDZ',
      'schemaVersion': 3,
      'exportedAt': DateTime.now().toIso8601String(),
      'profile': {
        'fullName': profile.fullName,
        'schoolName': profile.schoolName,
        'wilaya': profile.wilaya,
        'subjectName': profile.subjectName,
        'academicYear': profile.academicYear,
      },
      'classes': exportedClasses,
    };
  }

  static Future<File> exportBackupFile(AppDatabase db) async {
    final payload = await buildBackupPayload(db);
    final jsonText = const JsonEncoder.withIndent('  ').convert(payload);

    final docsDir = await getApplicationDocumentsDirectory();
    final backupsDir = Directory(p.join(docsDir.path, 'backups'));
    if (!backupsDir.existsSync()) {
      backupsDir.createSync(recursive: true);
    }
    final dateTag = DateTime.now().toIso8601String().split('T').first;
    final outFile = File(p.join(backupsDir.path, 'SmartTeacherDZ_Backup_$dateTag.json'));
    await outFile.writeAsString(jsonText, flush: true);
    return outFile;
  }

  static Future<BackupRestoreSummary> restoreFromJson(
    AppDatabase db,
    String rawJson,
  ) async {
    final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
    if (decoded['app'] != 'SmartTeacherDZ') {
      throw const FormatException('ملف النسخة الاحتياطية غير صالح أو لا يخص تطبيق الأستاذ الذكي.');
    }

    final prof = decoded['profile'] as Map<String, dynamic>?;
    if (prof != null) {
      final current = await db.getTeacherProfile();
      await db.saveTeacherProfile(
        fullName: (prof['fullName'] ?? current.fullName).toString(),
        schoolName: (prof['schoolName'] ?? current.schoolName).toString(),
        wilaya: (prof['wilaya'] ?? current.wilaya).toString(),
        subjectName: (prof['subjectName'] ?? current.subjectName).toString(),
        academicYear: (prof['academicYear'] ?? current.academicYear).toString(),
        geminiApiKey: current.geminiApiKey,
        defaultCloudConsent: current.defaultCloudConsent,
        autoDeleteScanPhotos: current.autoDeleteScanPhotos,
      );
    }

    final classesList = decoded['classes'] as List<dynamic>? ?? [];
    var classesCount = 0;
    var studentsCount = 0;
    var gradesCount = 0;

    for (final rawClass in classesList) {
      final cMap = rawClass as Map<String, dynamic>;
      final classId = await db.insertClass(
        SchoolClassesCompanion.insert(
          sheetName: cMap['sheetName'].toString(),
          displayName: cMap['displayName'].toString(),
          academicYear: (cMap['academicYear'] ?? '').toString(),
          termName: (cMap['termName'] ?? '').toString(),
          subjectName: (cMap['subjectName'] ?? '').toString(),
          gradeColumnsJson: cMap['gradeColumnsJson'].toString(),
        ),
      );
      classesCount++;

      final rawStudents = cMap['students'] as List<dynamic>? ?? [];
      final studentCompanions = rawStudents.map((s) {
        final sm = s as Map<String, dynamic>;
        return StudentsCompanion.insert(
          classId: classId,
          matricule: sm['matricule'].toString(),
          officialOrder: (sm['officialOrder'] as num).toInt(),
          lastName: sm['lastName'].toString(),
          firstName: sm['firstName'].toString(),
          birthDate: Value(sm['birthDate']?.toString()),
          aliasesJson: Value((sm['aliasesJson'] ?? '[]').toString()),
        );
      }).toList();

      await db.insertStudentsBatch(studentCompanions);
      studentsCount += studentCompanions.length;

      final rawGrades = cMap['grades'] as List<dynamic>? ?? [];
      for (final g in rawGrades) {
        final gm = g as Map<String, dynamic>;
        await db.upsertGrade(
          classId: classId,
          matricule: gm['matricule'].toString(),
          columnCode: gm['columnCode'].toString(),
          status: gm['status'].toString(),
          numericValue: (gm['numericValue'] as num?)?.toDouble(),
          observation: gm['observation']?.toString(),
          source: (gm['source'] ?? 'backup_restore').toString(),
        );
        gradesCount++;
      }
    }

    return BackupRestoreSummary(
      classesRestored: classesCount,
      studentsRestored: studentsCount,
      gradesRestored: gradesCount,
    );
  }
}
