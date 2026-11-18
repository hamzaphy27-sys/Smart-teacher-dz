import 'dart:math' as math;
import '../models/extraction_models.dart';
import 'name_normalizer.dart';

class StudentMatchOutcome {
  final List<StudentCandidate> candidates;
  final String? suggestedMatricule;
  final ConfidenceBand band;
  final List<String> flags;

  const StudentMatchOutcome({
    required this.candidates,
    this.suggestedMatricule,
    required this.band,
    this.flags = const [],
  });
}

/// Roster-constrained fuzzy student matcher ported from `stocr/matching.py`.
/// Never assigns an uncertain or sibling-ambiguous name as `ConfidenceBand.green`.
class StudentMatcher {
  final List<RosterStudent> roster;
  final double greenThreshold;
  final double reviewThreshold;
  final double marginThreshold;

  const StudentMatcher(
    this.roster, {
    this.greenThreshold = 0.88,
    this.reviewThreshold = 0.62,
    this.marginThreshold = 0.08,
  });

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var prev = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(
          prev[j] + 1,
          math.min(cur[j - 1] + 1, prev[j - 1] + cost),
        );
      }
      prev = cur;
    }
    return prev[b.length];
  }

  static double _tokenSimilarity(String a, String b) {
    if (a == b) return 1.0;
    final maxLen = math.max(a.length, b.length);
    if (maxLen == 0) return 1.0;
    if (math.min(a.length, b.length) == 1) {
      return a[0] == b[0] ? 0.55 : 0.0;
    }
    return 1.0 - (_levenshtein(a, b) / maxLen);
  }

  ({double score, double precision, double recall}) _scoreTokens(
    List<String> qTokens,
    List<String> rTokens,
  ) {
    if (qTokens.isEmpty || rTokens.isEmpty) {
      return (score: 0.0, precision: 0.0, recall: 0.0);
    }

    final pairs = <({double sim, int qi, int ri})>[];
    for (var i = 0; i < qTokens.length; i++) {
      for (var j = 0; j < rTokens.length; j++) {
        pairs.add((sim: _tokenSimilarity(qTokens[i], rTokens[j]), qi: i, ri: j));
      }
    }
    pairs.sort((a, b) => b.sim.compareTo(a.sim));

    final usedQ = <int>{};
    final usedR = <int>{};
    var numP = 0.0;
    var numR = 0.0;

    for (final p in pairs) {
      if (p.sim < 0.50) break;
      if (usedQ.contains(p.qi) || usedR.contains(p.ri)) continue;
      usedQ.add(p.qi);
      usedR.add(p.ri);
      numP += qTokens[p.qi].length * p.sim;
      numR += rTokens[p.ri].length * p.sim;
    }

    final qLen = qTokens.fold<int>(0, (sum, t) => sum + t.length);
    final rLen = rTokens.fold<int>(0, (sum, t) => sum + t.length);
    final precision = qLen > 0 ? numP / qLen : 0.0;
    final recall = rLen > 0 ? numR / rLen : 0.0;
    final combined = 0.70 * precision + 0.30 * recall;
    return (score: combined, precision: precision, recall: recall);
  }

  StudentMatchOutcome match(String rawName, {int topK = 5}) {
    final qTokens = NameNormalizer.arabicTokens(rawName);
    if (qTokens.isEmpty) {
      return const StudentMatchOutcome(
        candidates: [],
        suggestedMatricule: null,
        band: ConfidenceBand.red,
        flags: ['no_name_detected'],
      );
    }

    final scored = <({StudentCandidate cand, double p, double r, int order})>[];
    for (final st in roster) {
      final rTokens = NameNormalizer.arabicTokens(st.fullName);
      final res = _scoreTokens(qTokens, rTokens);
      if (res.score > 0) {
        scored.add((
          cand: StudentCandidate(
            matricule: st.matricule,
            score: (res.score * 10000).roundToDouble() / 10000.0,
            matchedOn: 'name_arabic',
          ),
          p: res.precision,
          r: res.recall,
          order: st.officialOrder,
        ));
      }
    }

    if (scored.isEmpty) {
      return const StudentMatchOutcome(
        candidates: [],
        suggestedMatricule: null,
        band: ConfidenceBand.red,
        flags: ['no_name_candidates'],
      );
    }

    scored.sort((a, b) {
      final cmp = b.cand.score.compareTo(a.cand.score);
      return cmp != 0 ? cmp : a.order.compareTo(b.order);
    });

    final topList = scored.take(topK).map((e) => e.cand).toList();
    final top = scored.first;
    final secondScore = scored.length > 1 ? scored[1].cand.score : 0.0;

    if (top.cand.score < reviewThreshold) {
      return StudentMatchOutcome(
        candidates: topList,
        suggestedMatricule: null,
        band: ConfidenceBand.red,
        flags: const ['low_name_score'],
      );
    }

    if (top.cand.score - secondScore < marginThreshold) {
      return StudentMatchOutcome(
        candidates: topList,
        suggestedMatricule: top.cand.matricule,
        band: ConfidenceBand.orange,
        flags: const ['ambiguous_match'],
      );
    }

    // Sibling / partial-name guard: surname-only that fits multiple students equally
    if (top.p >= 0.80 &&
        top.r < 0.90 &&
        scored.skip(1).any((other) => other.p >= top.p - 0.06 && other.cand.score >= reviewThreshold)) {
      return StudentMatchOutcome(
        candidates: topList,
        suggestedMatricule: top.cand.matricule,
        band: ConfidenceBand.orange,
        flags: const ['ambiguous_partial_name'],
      );
    }

    if (top.cand.score < greenThreshold) {
      return StudentMatchOutcome(
        candidates: topList,
        suggestedMatricule: top.cand.matricule,
        band: ConfidenceBand.orange,
        flags: const ['moderate_name_score'],
      );
    }

    return StudentMatchOutcome(
      candidates: topList,
      suggestedMatricule: top.cand.matricule,
      band: ConfidenceBand.green,
    );
  }
}
