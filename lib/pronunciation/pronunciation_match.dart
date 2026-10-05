import 'pronunciation_resolver.dart';
import 'pronunciation_store.dart';

/// Resolves a card without ever modifying its source data. A saved local
/// selection wins; otherwise only a genuinely unique pack entry is automatic.
class PronunciationMatch {
  const PronunciationMatch({
    required this.candidates,
    required this.active,
    required this.hasSavedSelection,
  });

  final List<ResolvedPronunciation> candidates;
  final ResolvedPronunciation? active;
  final bool hasSavedSelection;

  const PronunciationMatch.empty()
      : candidates = const [],
        active = null,
        hasSavedSelection = false;

  bool get requiresSelection => candidates.length > 1 && active == null;
}

Future<PronunciationMatch> resolvePronunciationMatch({
  required PronunciationResolver resolver,
  required String term,
  required String reading,
  PronunciationSelectionStore? selections,
  PronunciationCardRef? reference,
}) async {
  final candidates = await resolver.candidates(term, reading);
  final saved = selections == null || reference == null
      ? null
      : selections.forCard(reference);
  ResolvedPronunciation? active;
  if (saved != null) {
    for (final candidate in candidates) {
      if (candidate.entry.candidateId == saved.candidateId) {
        active = candidate;
        break;
      }
    }
  }
  if (active == null && candidates.length == 1) active = candidates.single;
  return PronunciationMatch(
    candidates: candidates,
    active: active,
    hasSavedSelection: saved != null,
  );
}
