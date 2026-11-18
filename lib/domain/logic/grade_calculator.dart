import 'dart:math' as math;
import '../../data/local/app_database.dart';
import '../../data/services/ministry_excel_service.dart';

/// Pedagogical formula presets aligned with Algerian Ministry of Education circulars
/// (e.g., Circular 522 for Middle & Secondary schools), while remaining fully configurable.
enum FormulaPreset {
  /// المتوسط والثانوي (مواد عادية): ((التقويم + الفرض) / 2 + الاختبار × 2) / 3
  standardSingleDevoir,

  /// الثانوي (مواد مميزة بفرضين): ((التقويم + معدل الفرضين) / 2 + الاختبار × 2) / 3
  secondaryTwoDevoirs,

  /// الثانوي (مواد بأعمال تطبيقية TP): ((التقويم + الفرض + TP) / 3 + الاختبار × 2) / 3
  secondaryWithTp,

  /// متوسط حسابي مرجح مخصص حسب أوزان يحددها الأستاذ
  customWeighted,
}

class GradingFormulaConfig {
  final FormulaPreset preset;
  final double continuousWeight; // Default 1.0
  final double examWeight;       // Default 2.0
  final double passThreshold;    // Default 10.0
  final Map<String, double> customColumnWeights;

  const GradingFormulaConfig({
    this.preset = FormulaPreset.standardSingleDevoir,
    this.continuousWeight = 1.0,
    this.examWeight = 2.0,
    this.passThreshold = 10.0,
    this.customColumnWeights = const {},
  });

  /// Automatically infers the matching Ministry formula from the hidden Row-7 column codes
  /// (`01`=Continuous, `04`=Devoir 1, `05`=Devoir 2, `08`=TP, `09`=Exam).
  factory GradingFormulaConfig.inferFromColumns(List<MinistryGradeColumn> cols) {
    final codes = cols.map((c) => c.code.trim()).toSet();
    if (codes.contains('08')) {
      return const GradingFormulaConfig(preset: FormulaPreset.secondaryWithTp);
    }
    if (codes.contains('05')) {
      return const GradingFormulaConfig(preset: FormulaPreset.secondaryTwoDevoirs);
    }
    return const GradingFormulaConfig(preset: FormulaPreset.standardSingleDevoir);
  }

  String get presetLabelAr {
    switch (preset) {
      case FormulaPreset.standardSingleDevoir:
        return 'المتوسط / الثانوي العادي: ((التقويم + الفرض)÷2 + الاختبار×2) ÷ 3';
      case FormulaPreset.secondaryTwoDevoirs:
        return 'الثانوي (فرضين): ((التقويم + معدل الفرضين)÷2 + الاختبار×2) ÷ 3';
      case FormulaPreset.secondaryWithTp:
        return 'الثانوي (أعمال تطبيقية TP): ((التقويم + الفرض + TP)÷3 + الاختبار×2) ÷ 3';
      case FormulaPreset.customWeighted:
        return 'صيغة مرجحة مخصصة';
    }
  }
}

class StudentTermResult {
  final Student student;
  final double? continuousAverage; // معدل التقييم المستمر
  final double? termAverage;       // المعدل الفصلي للمادة (/20)
  final double? fardGrade;
  final double? examGrade;
  final bool isComplete;
  final String suggestedComment;
  final String? savedObservation;

  const StudentTermResult({
    required this.student,
    this.continuousAverage,
    this.termAverage,
    this.fardGrade,
    this.examGrade,
    required this.isComplete,
    required this.suggestedComment,
    this.savedObservation,
  });

  bool get isPassing => termAverage != null && termAverage! >= 10.0;
}

class PerformanceDistribution {
  final int excellent; // >= 16
  final int veryGood;  // 14 .. 15.99
  final int good;      // 12 .. 13.99
  final int average;   // 10 .. 11.99
  final int belowAvg;  // 8 .. 9.99
  final int weak;      // < 8

  const PerformanceDistribution({
    required this.excellent,
    required this.veryGood,
    required this.good,
    required this.average,
    required this.belowAvg,
    required this.weak,
  });
}

class ClassBilanReport {
  final int totalStudents;
  final int evaluatedStudents;
  final double? classAverage;
  final double? medianAverage;
  final double? highestAverage;
  final double? lowestAverage;
  final int passedCount;
  final int failedCount;
  final double? passRatePercent;
  final double? fardMean;
  final double? examMean;
  final PerformanceDistribution distribution;
  final List<StudentTermResult> studentResults;
  final List<StudentTermResult> studentsNeedingSupport;

  const ClassBilanReport({
    required this.totalStudents,
    required this.evaluatedStudents,
    this.classAverage,
    this.medianAverage,
    this.highestAverage,
    this.lowestAverage,
    required this.passedCount,
    required this.failedCount,
    this.passRatePercent,
    this.fardMean,
    this.examMean,
    required this.distribution,
    required this.studentResults,
    required this.studentsNeedingSupport,
  });
}

/// Pedagogical comment generator strictly grounded in verified academic numbers.
/// Never infers student behavior, discipline, or attendance from grades alone.
class PedagogicalCommentAssistant {
  static String suggestFromGrades({
    required double? termAverage,
    required double? continuousAverage,
    required double? examGrade,
  }) {
    if (termAverage == null) {
      return 'نتائج غير مكتملة';
    }
    final delta = (continuousAverage != null && examGrade != null)
        ? (examGrade - continuousAverage)
        : 0.0;

    if (termAverage >= 17.0) {
      return 'نتائج ممتازة، واصل على هذا التألق';
    }
    if (termAverage >= 15.0) {
      return delta >= 2.0
          ? 'أداء جيد جداً وتحسن ملحوظ في الاختبار'
          : 'نتائج جيدة جداً، أحسنت';
    }
    if (termAverage >= 12.0) {
      return delta <= -3.0
          ? 'نتائج مرضية إجمالاً مع تراجع في الاختبار، يمكنه الأفضل'
          : 'أداء حسن، واصل الاجتهاد';
    }
    if (termAverage >= 10.0) {
      return delta >= 2.0
          ? 'نتائج مقبولة وتحسن في الاختبار، واصل المثابرة'
          : 'نتائج متوسطة، يحتاج إلى مزيد من التركيز';
    }
    if (termAverage >= 8.0) {
      return 'نتائج دون المتوسط، يحتاج إلى دعم ومراجعة منتظمة';
    }
    return 'نتائج ضعيفة، يستوجب مرافقة بيداغوجية وتدارك النقائص';
  }
}

class MinistryGradeCalculator {
  static double _round2(double v) => (v * 100).roundToDouble() / 100.0;

  /// Computes a single student's continuous assessment average and term average.
  static ({double? continuous, double? termAvg, double? fard, double? exam, bool complete})
      computeStudentAverage({
    required Map<String, StudentGrade> gradesByCode,
    required List<MinistryGradeColumn> columns,
    required GradingFormulaConfig config,
  }) {
    double? valOf(String code) {
      final g = gradesByCode[code];
      if (g == null || g.status != 'value') return null;
      return g.numericValue;
    }

    final c01 = valOf('01'); // تقويم النشاطات
    final c04 = valOf('04'); // الفرض 1
    final c05 = valOf('05'); // الفرض 2 (إن وجد)
    final c08 = valOf('08'); // أعمال تطبيقية TP (إن وجدت)
    final c09 = valOf('09'); // الاختبار

    if (config.preset == FormulaPreset.customWeighted && config.customColumnWeights.isNotEmpty) {
      var weightedSum = 0.0;
      var totalWeight = 0.0;
      var allPresent = true;
      for (final col in columns) {
        final w = config.customColumnWeights[col.code] ?? 0.0;
        if (w <= 0) continue;
        final v = valOf(col.code);
        if (v == null) {
          allPresent = false;
        } else {
          weightedSum += v * w;
          totalWeight += w;
        }
      }
      if (totalWeight <= 0 || !allPresent) {
        return (continuous: null, termAvg: null, fard: c04, exam: c09, complete: false);
      }
      return (
        continuous: null,
        termAvg: _round2(weightedSum / totalWeight),
        fard: c04,
        exam: c09,
        complete: true,
      );
    }

    double? continuousAvg;
    if (config.preset == FormulaPreset.secondaryWithTp) {
      if (c01 != null && c04 != null && c08 != null) {
        final fardPart = c05 != null ? (c04 + c05) / 2.0 : c04;
        continuousAvg = (c01 + fardPart + c08) / 3.0;
      }
    } else if (config.preset == FormulaPreset.secondaryTwoDevoirs) {
      if (c01 != null && c04 != null && c05 != null) {
        final fardMean = (c04 + c05) / 2.0;
        continuousAvg = (c01 + fardMean) / 2.0;
      }
    } else {
      // Standard single devoir (Middle & Secondary standard subjects)
      if (c01 != null && c04 != null) {
        continuousAvg = (c01 + c04) / 2.0;
      }
    }

    if (continuousAvg == null || c09 == null) {
      return (
        continuous: continuousAvg != null ? _round2(continuousAvg) : null,
        termAvg: null,
        fard: c04,
        exam: c09,
        complete: false,
      );
    }

    final denom = config.continuousWeight + config.examWeight;
    final term = (continuousAvg * config.continuousWeight + c09 * config.examWeight) / denom;
    return (
      continuous: _round2(continuousAvg),
      termAvg: _round2(term),
      fard: c04,
      exam: c09,
      complete: true,
    );
  }

  /// Builds the complete Bilan Trimestriel analytical report for a class.
  static ClassBilanReport buildClassReport({
    required List<Student> students,
    required List<StudentGrade> allGrades,
    required List<MinistryGradeColumn> columns,
    GradingFormulaConfig? config,
  }) {
    final effectiveConfig = config ?? GradingFormulaConfig.inferFromColumns(columns);
    final byMat = <String, Map<String, StudentGrade>>{};
    final savedObs = <String, String>{};

    for (final g in allGrades) {
      byMat.putIfAbsent(g.matricule, () => {})[g.columnCode] = g;
      if (g.observation != null && g.observation!.trim().isNotEmpty) {
        savedObs[g.matricule] = g.observation!.trim();
      }
    }

    final results = <StudentTermResult>[];
    final validAverages = <double>[];
    final fardValues = <double>[];
    final examValues = <double>[];

    var excellent = 0, veryGood = 0, good = 0, average = 0, belowAvg = 0, weak = 0;

    for (final st in students) {
      final stGrades = byMat[st.matricule] ?? const <String, StudentGrade>{};
      final calc = computeStudentAverage(
        gradesByCode: stGrades,
        columns: columns,
        config: effectiveConfig,
      );

      if (calc.fard != null) fardValues.add(calc.fard!);
      if (calc.exam != null) examValues.add(calc.exam!);

      final avg = calc.termAvg;
      if (avg != null) {
        validAverages.add(avg);
        if (avg >= 16.0) {
          excellent++;
        } else if (avg >= 14.0) {
          veryGood++;
        } else if (avg >= 12.0) {
          good++;
        } else if (avg >= 10.0) {
          average++;
        } else if (avg >= 8.0) {
          belowAvg++;
        } else {
          weak++;
        }
      }

      final suggestion = PedagogicalCommentAssistant.suggestFromGrades(
        termAverage: avg,
        continuousAverage: calc.continuous,
        examGrade: calc.exam,
      );

      results.add(
        StudentTermResult(
          student: st,
          continuousAverage: calc.continuous,
          termAverage: avg,
          fardGrade: calc.fard,
          examGrade: calc.exam,
          isComplete: calc.complete,
          suggestedComment: suggestion,
          savedObservation: savedObs[st.matricule],
        ),
      );
    }

    double? meanOf(List<double> xs) =>
        xs.isEmpty ? null : _round2(xs.reduce((a, b) => a + b) / xs.length);

    double? medianOf(List<double> xs) {
      if (xs.isEmpty) return null;
      final sorted = [...xs]..sort();
      final mid = sorted.length ~/ 2;
      if (sorted.length.isOdd) return sorted[mid];
      return _round2((sorted[mid - 1] + sorted[mid]) / 2.0);
    }

    final passed = validAverages.where((v) => v >= effectiveConfig.passThreshold).length;
    final failed = validAverages.length - passed;
    final passRate = validAverages.isEmpty
        ? null
        : _round2((passed / validAverages.length) * 100.0);

    final supportList = results
        .where((r) => r.termAverage != null && r.termAverage! < effectiveConfig.passThreshold)
        .toList()
      ..sort((a, b) => a.termAverage!.compareTo(b.termAverage!));

    return ClassBilanReport(
      totalStudents: students.length,
      evaluatedStudents: validAverages.length,
      classAverage: meanOf(validAverages),
      medianAverage: medianOf(validAverages),
      highestAverage: validAverages.isEmpty ? null : validAverages.reduce(math.max),
      lowestAverage: validAverages.isEmpty ? null : validAverages.reduce(math.min),
      passedCount: passed,
      failedCount: failed,
      passRatePercent: passRate,
      fardMean: meanOf(fardValues),
      examMean: meanOf(examValues),
      distribution: PerformanceDistribution(
        excellent: excellent,
        veryGood: veryGood,
        good: good,
        average: average,
        belowAvg: belowAvg,
        weak: weak,
      ),
      studentResults: results,
      studentsNeedingSupport: supportList,
    );
  }
}
