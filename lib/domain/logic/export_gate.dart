import '../models/extraction_models.dart';

class ExportBlocker {
  final int rowIndex;
  final String code;
  final String detail;

  const ExportBlocker({
    required this.rowIndex,
    required this.code,
    this.detail = '',
  });
}

class ExportGateResult {
  final bool ok;
  final List<ExportBlocker> blockers;

  const ExportGateResult({required this.ok, this.blockers = const []});
}

/// Hard safety gate: prevents exporting any unconfirmed, ambiguous, or duplicate row.
class ExportGateService {
  static String? resolvedMatricule(ExtractedRow row, {bool requireConfirmGreen = false}) {
    if (row.verification == VerificationStatus.rejected) return null;
    if (row.confirmedMatricule != null && row.confirmedMatricule!.isNotEmpty) {
      return row.confirmedMatricule;
    }
    if (row.band == ConfidenceBand.green && !requireConfirmGreen) {
      return row.suggestedMatricule;
    }
    return null;
  }

  static ExportGateResult evaluate(
    SheetExtraction sheet, {
    bool requireConfirmGreen = false,
  }) {
    final blockers = <ExportBlocker>[];
    final owners = <String, List<int>>{};

    for (final r in sheet.rows) {
      if (r.verification == VerificationStatus.rejected) continue;

      final mat = resolvedMatricule(r, requireConfirmGreen: requireConfirmGreen);
      if (mat == null) {
        blockers.add(ExportBlocker(rowIndex: r.rowIndex, code: 'student_unconfirmed'));
      } else {
        owners.putIfAbsent(mat, () => []).add(r.rowIndex);
      }

      for (final g in r.grades) {
        final st = g.effectiveStatus;
        if (st == GradeStatus.invalid || st == GradeStatus.ambiguous) {
          blockers.add(ExportBlocker(
            rowIndex: r.rowIndex,
            code: 'grade_invalid',
            detail: g.columnLabel,
          ));
        } else {
          final done = g.verification == VerificationStatus.confirmed ||
              g.verification == VerificationStatus.corrected;
          if (!done && (g.band != ConfidenceBand.green || requireConfirmGreen)) {
            blockers.add(ExportBlocker(
              rowIndex: r.rowIndex,
              code: 'grade_unconfirmed',
              detail: g.columnLabel,
            ));
          }
        }
      }
    }

    owners.forEach((mat, rows) {
      if (rows.length > 1) {
        blockers.add(ExportBlocker(
          rowIndex: rows.first,
          code: 'duplicate_student',
          detail: '$mat -> rows $rows',
        ));
      }
    });

    return ExportGateResult(ok: blockers.isEmpty, blockers: blockers);
  }
}
