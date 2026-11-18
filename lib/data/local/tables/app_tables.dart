import 'package:drift/drift.dart';

class TeacherProfiles extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get fullName => text().withDefault(const Constant(''))();
  TextColumn get schoolName => text().withDefault(const Constant(''))();
  TextColumn get wilaya => text().withDefault(const Constant(''))();
  TextColumn get subjectName => text().withDefault(const Constant(''))();
  TextColumn get academicYear => text().withDefault(const Constant('2025-2026'))();
  TextColumn get geminiApiKey => text().withDefault(const Constant(''))();
  BoolColumn get defaultCloudConsent => boolean().withDefault(const Constant(false))();
  BoolColumn get autoDeleteScanPhotos => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName("ClassRoom")
class SchoolClasses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get sheetName => text()();            // e.g. '2100001'
  TextColumn get displayName => text()();          // e.g. 'أولى متوسط 1'
  TextColumn get academicYear => text()();         // e.g. '2025-2026'
  TextColumn get termName => text()();             // e.g. 'الفصل الثالث'
  TextColumn get subjectName => text()();          // e.g. 'ع الفيزيائية والتكنولوجيا'
  TextColumn get sourceTemplatePath => text().nullable()();
  TextColumn get gradeColumnsJson => text()();     // JSON array of {code, label, colIndex}
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Students extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get classId => integer().references(SchoolClasses, #id, onDelete: KeyAction.cascade)();
  TextColumn get matricule => text()();            // 16-digit national student ID
  IntColumn get officialOrder => integer()();
  TextColumn get lastName => text()();
  TextColumn get firstName => text()();
  TextColumn get birthDate => text().nullable()();
  TextColumn get aliasesJson => text().withDefault(const Constant('[]'))();
}

class StudentGrades extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get classId => integer().references(SchoolClasses, #id, onDelete: KeyAction.cascade)();
  TextColumn get matricule => text()();
  TextColumn get columnCode => text()();           // '01', '04', '09'
  TextColumn get status => text()();               // 'value' | 'absent' | 'excused' | 'missing'
  RealColumn get numericValue => real().nullable()();
  TextColumn get observation => text().nullable()();
  TextColumn get source => text()();               // 'excel_import' | 'ocr_confirmed' | 'manual'
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {classId, matricule, columnCode},
      ];
}

class ScanSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get classId => integer().references(SchoolClasses, #id, onDelete: KeyAction.cascade)();
  TextColumn get providerName => text()();
  IntColumn get rowsExtracted => integer()();
  IntColumn get gradesCommitted => integer()();
  BoolColumn get photoDeleted => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
