import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'tables/app_tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [TeacherProfiles, SchoolClasses, Students, StudentGrades, ScanSessions])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(teacherProfiles);
          }
          if (from < 3) {
            await m.createTable(scanSessions);
          }
        },
      );

  Future<TeacherProfile> getTeacherProfile() async {
    final row = await (select(teacherProfiles)..where((t) => t.id.equals(1))).getSingleOrNull();
    if (row != null) return row;
    await into(teacherProfiles).insert(TeacherProfilesCompanion.insert(id: const Value(1)));
    return (select(teacherProfiles)..where((t) => t.id.equals(1))).getSingle();
  }

  Future<void> saveTeacherProfile({
    required String fullName,
    required String schoolName,
    required String wilaya,
    required String subjectName,
    required String academicYear,
    required String geminiApiKey,
    required bool defaultCloudConsent,
    required bool autoDeleteScanPhotos,
  }) async {
    await into(teacherProfiles).insertOnConflictUpdate(
      TeacherProfilesCompanion(
        id: const Value(1),
        fullName: Value(fullName.trim()),
        schoolName: Value(schoolName.trim()),
        wilaya: Value(wilaya.trim()),
        subjectName: Value(subjectName.trim()),
        academicYear: Value(academicYear.trim()),
        geminiApiKey: Value(geminiApiKey.trim()),
        defaultCloudConsent: Value(defaultCloudConsent),
        autoDeleteScanPhotos: Value(autoDeleteScanPhotos),
      ),
    );
  }

  Stream<List<ClassRoom>> watchAllClasses() {
    return (select(schoolClasses)..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();
  }

  Future<List<ClassRoom>> getAllClasses() => select(schoolClasses).get();

  Future<ClassRoom?> getClassById(int id) {
    return (select(schoolClasses)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<int> insertClass(SchoolClassesCompanion entry) => into(schoolClasses).insert(entry);

  Future<void> deleteClass(int classId) async {
    await (delete(schoolClasses)..where((t) => t.id.equals(classId))).go();
  }

  Future<void> insertStudentsBatch(List<StudentsCompanion> entries) async {
    await batch((b) {
      b.insertAll(students, entries);
    });
  }

  Future<List<Student>> getStudentsForClass(int classId) {
    return (select(students)
          ..where((t) => t.classId.equals(classId))
          ..orderBy([(t) => OrderingTerm.asc(t.officialOrder)]))
        .get();
  }

  Stream<List<StudentGrade>> watchGradesForClass(int classId) {
    return (select(studentGrades)..where((t) => t.classId.equals(classId))).watch();
  }

  Future<List<StudentGrade>> getGradesForClass(int classId) {
    return (select(studentGrades)..where((t) => t.classId.equals(classId))).get();
  }

  Future<void> upsertGrade({
    required int classId,
    required String matricule,
    required String columnCode,
    required String status,
    double? numericValue,
    String? observation,
    required String source,
  }) async {
    await into(studentGrades).insertOnConflictUpdate(
      StudentGradesCompanion.insert(
        classId: classId,
        matricule: matricule,
        columnCode: columnCode,
        status: status,
        numericValue: Value(numericValue),
        observation: Value(observation),
        source: source,
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<int> logScanSession({
    required int classId,
    required String providerName,
    required int rowsExtracted,
    required int gradesCommitted,
    required bool photoDeleted,
  }) {
    return into(scanSessions).insert(
      ScanSessionsCompanion.insert(
        classId: classId,
        providerName: providerName,
        rowsExtracted: rowsExtracted,
        gradesCommitted: gradesCommitted,
        photoDeleted: Value(photoDeleted),
      ),
    );
  }

  Stream<List<ScanSession>> watchScanSessionsForClass(int classId) {
    return (select(scanSessions)
          ..where((t) => t.classId.equals(classId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'smart_teacher_dz.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
