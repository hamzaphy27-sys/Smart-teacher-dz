enum ConfidenceBand { green, orange, red }

enum GradeStatus { value, absent, excused, missing, invalid, ambiguous }

enum VerificationStatus { unverified, confirmed, corrected, rejected }

class NormalizedBox {
  final double x0;
  final double y0;
  final double x1;
  final double y1;

  const NormalizedBox({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
  });
}

class RosterStudent {
  final String matricule;
  final int officialOrder;
  final String lastName;
  final String firstName;
  final String? birthDate;
  final List<String> aliases;

  const RosterStudent({
    required this.matricule,
    required this.officialOrder,
    required this.lastName,
    required this.firstName,
    this.birthDate,
    this.aliases = const [],
  });

  String get fullName => '$lastName $firstName'.trim();
}

class StudentCandidate {
  final String matricule;
  final double score;
  final String matchedOn;

  const StudentCandidate({
    required this.matricule,
    required this.score,
    required this.matchedOn,
  });
}

class GradeCandidate {
  final GradeStatus status;
  final double? value;
  final String text;
  final String source;

  const GradeCandidate({
    required this.status,
    this.value,
    required this.text,
    required this.source,
  });
}

class ExtractedGrade {
  final int columnIndex;
  final String columnLabel;
  final String? targetMinistryCode; // e.g. '01', '04', '09'
  final NormalizedBox bbox;
  final String rawText;
  final GradeStatus status;
  final double? value;
  final double confidence;
  final ConfidenceBand band;
  final List<String> flags;
  final List<GradeCandidate> candidates;

  VerificationStatus verification;
  GradeStatus? finalStatus;
  double? finalValue;

  ExtractedGrade({
    required this.columnIndex,
    required this.columnLabel,
    this.targetMinistryCode,
    required this.bbox,
    required this.rawText,
    required this.status,
    this.value,
    required this.confidence,
    required this.band,
    this.flags = const [],
    this.candidates = const [],
    this.verification = VerificationStatus.unverified,
    this.finalStatus,
    this.finalValue,
  });

  GradeStatus get effectiveStatus => finalStatus ?? status;
  double? get effectiveValue => finalStatus != null ? finalValue : value;
}

class ExtractedRow {
  final int rowIndex;
  final String imageId;
  final NormalizedBox rowBbox; // Used to display the original row image crop
  final String rawNameText;
  final String observationText;
  final List<StudentCandidate> candidates;
  final String? suggestedMatricule;
  final ConfidenceBand matchBand;
  final ConfidenceBand band;
  final List<String> flags;
  final List<ExtractedGrade> grades;

  String? confirmedMatricule;
  VerificationStatus verification;

  ExtractedRow({
    required this.rowIndex,
    required this.imageId,
    required this.rowBbox,
    required this.rawNameText,
    this.observationText = '',
    this.candidates = const [],
    this.suggestedMatricule,
    required this.matchBand,
    required this.band,
    this.flags = const [],
    required this.grades,
    this.confirmedMatricule,
    this.verification = VerificationStatus.unverified,
  });
}

class SheetExtraction {
  final String imageId;
  final String imagePath;
  final List<ExtractedRow> rows;
  final List<String> unmatchedMatricules;
  final List<String> warnings;

  const SheetExtraction({
    required this.imageId,
    required this.imagePath,
    required this.rows,
    this.unmatchedMatricules = const [],
    this.warnings = const [],
  });
}
