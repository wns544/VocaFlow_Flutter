import 'bundled_pitch_dictionary.dart';
import 'pitch_accent.dart';
import 'pronunciation_match.dart';
import 'pronunciation_resolver.dart';
import 'pronunciation_store.dart';

/// A single locally-resolved pitch pattern. It keeps optional pack audio next
/// to its pattern without ever writing a field to a vocabulary card.
class PitchAccentOption {
  const PitchAccentOption({
    required this.candidateId,
    required this.pattern,
    required this.fromDictionary,
    this.audioPath,
  });

  final String candidateId;
  final PitchAccentPattern pattern;
  final bool fromDictionary;
  final String? audioPath;
}

class PitchAccentResolution {
  const PitchAccentResolution({
    required this.options,
    required this.active,
    required this.hasSavedSelection,
  });

  const PitchAccentResolution.empty()
      : options = const [],
        active = null,
        hasSavedSelection = false;

  final List<PitchAccentOption> options;
  final PitchAccentOption? active;
  final bool hasSavedSelection;

  bool get requiresSelection => options.length > 1 && active == null;
}

String dictionaryPitchCandidateId({
  required String term,
  required String reading,
  required int accentPosition,
}) =>
    'kanjium:$term\u0000${normalizeJapaneseReading(reading)}\u0000$accentPosition';

/// Returns the immediately usable exact dictionary option. Audio playback
/// calls this path so an automatic pronunciation never waits for an asset
/// parse; the richer asynchronous resolver remains responsible for choices.
PitchAccentOption? cachedPitchAccent({
  required String term,
  required String reading,
}) {
  final dictionary = BundledPitchDictionary.cached;
  if (dictionary == null) return null;
  final patterns = dictionary
      .lookup(term: term, reading: reading)
      .map((candidate) => candidate.toPattern())
      .whereType<PitchAccentPattern>()
      .toList(growable: false);
  if (patterns.length != 1) return null;
  final pattern = patterns.single;
  return PitchAccentOption(
    candidateId: dictionaryPitchCandidateId(
      term: term,
      reading: reading,
      accentPosition: pattern.accentPosition,
    ),
    pattern: pattern,
    fromDictionary: true,
  );
}

/// Gives Kanjium's exact spelling+reading candidates priority. A matching
/// installed pack only contributes its prerecorded audio to the same pattern.
Future<PitchAccentResolution> resolvePitchAccent({
  required String term,
  required String reading,
  required PronunciationResolver resolver,
  PronunciationSelectionStore? selections,
  PronunciationCardRef? reference,
}) async {
  final dictionaryCandidates = await BundledPitchDictionary.lookup(
    term: term,
    reading: reading,
  );
  final packMatch = await resolvePronunciationMatch(
    resolver: resolver,
    term: term,
    reading: reading,
    selections: selections,
    reference: reference,
  );
  final audioByAccent = <int, String>{
    for (final candidate in packMatch.candidates)
      if (candidate.entry.pattern != null)
        candidate.entry.accentPosition: candidate.audioPath,
  };
  final options = <PitchAccentOption>[];
  final seenPositions = <int>{};
  for (final candidate in dictionaryCandidates) {
    final pattern = candidate.toPattern();
    if (pattern == null || !seenPositions.add(pattern.accentPosition)) continue;
    options.add(PitchAccentOption(
      candidateId: dictionaryPitchCandidateId(
        term: term,
        reading: reading,
        accentPosition: pattern.accentPosition,
      ),
      pattern: pattern,
      fromDictionary: true,
      audioPath: audioByAccent[pattern.accentPosition],
    ));
  }
  if (options.isEmpty) {
    for (final candidate in packMatch.candidates) {
      final pattern = candidate.entry.pattern;
      if (pattern == null || !seenPositions.add(pattern.accentPosition))
        continue;
      options.add(PitchAccentOption(
        candidateId: candidate.entry.candidateId,
        pattern: pattern,
        fromDictionary: false,
        audioPath: candidate.audioPath,
      ));
    }
  }
  if (options.isEmpty) return const PitchAccentResolution.empty();

  final saved = reference == null ? null : selections?.forCard(reference);
  PitchAccentOption? active;
  if (saved != null) {
    active = options
        .where((option) => option.candidateId == saved.candidateId)
        .firstOrNull;
    // Keep a choice made in the pre-existing audio-pack UI when the same
    // accent pattern now has a dictionary-backed option.
    if (active == null) {
      final legacy = packMatch.candidates
          .where(
              (candidate) => candidate.entry.candidateId == saved.candidateId)
          .firstOrNull;
      if (legacy != null) {
        active = options
            .where((option) =>
                option.pattern.accentPosition == legacy.entry.accentPosition)
            .firstOrNull;
      }
    }
  }
  if (active == null && options.length == 1) active = options.single;
  return PitchAccentResolution(
    options: List.unmodifiable(options),
    active: active,
    hasSavedSelection: saved != null,
  );
}
