import 'pitch_accent.dart';

/// One accent candidate from a pinned Kanjium `accents.txt` snapshot.
///
/// A candidate remains tied to its spelling and reading. Callers must not use
/// a kana-only lookup to silently apply it to another word.
class PitchAccentCandidate {
  const PitchAccentCandidate({
    required this.term,
    required this.reading,
    required this.accentPosition,
    required this.sourceLine,
  });

  final String term;
  final String reading;
  final int accentPosition;
  final int sourceLine;

  PitchAccentPattern? toPattern() => PitchAccentPattern.tryCreate(
        reading: reading,
        accentPosition: accentPosition,
      );
}

class KanjiumPitchDictionary {
  KanjiumPitchDictionary._(this._candidatesByKey, this.ignoredLineCount);

  final Map<String, List<PitchAccentCandidate>> _candidatesByKey;
  final int ignoredLineCount;

  /// Parses the tab-separated upstream raw file. Broken rows are counted and
  /// ignored so the generator can report an incomplete source instead of
  /// silently treating it as a complete dictionary.
  factory KanjiumPitchDictionary.parse(String source) {
    final candidatesByKey = <String, List<PitchAccentCandidate>>{};
    var ignoredLineCount = 0;
    final seen = <String>{};

    for (final record in source.split('\n').indexed) {
      final lineNumber = record.$1 + 1;
      final line = record.$2.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final fields = line.split('\t');
      if (fields.length != 3) {
        ignoredLineCount++;
        continue;
      }
      final term = fields[0].trim();
      final reading = normalizeJapaneseReading(fields[1]);
      final morae = splitJapaneseMorae(reading);
      if (term.isEmpty || morae == null) {
        ignoredLineCount++;
        continue;
      }

      var validAccentCount = 0;
      var hasInvalidAccent = false;
      for (final value in fields[2].split(',')) {
        final accentPosition = int.tryParse(value.trim());
        if (accentPosition == null ||
            accentPosition < 0 ||
            accentPosition > morae.length) {
          hasInvalidAccent = true;
          continue;
        }
        validAccentCount++;
        final candidate = PitchAccentCandidate(
          term: term,
          reading: reading,
          accentPosition: accentPosition,
          sourceLine: lineNumber,
        );
        final candidateKey = '$term\u0000$reading\u0000$accentPosition';
        if (!seen.add(candidateKey)) continue;
        candidatesByKey
            .putIfAbsent(_lookupKey(term, reading), () => [])
            .add(candidate);
      }
      if (hasInvalidAccent || validAccentCount == 0) ignoredLineCount++;
    }

    return KanjiumPitchDictionary._(
      Map<String, List<PitchAccentCandidate>>.unmodifiable({
        for (final entry in candidatesByKey.entries)
          entry.key: List<PitchAccentCandidate>.unmodifiable(entry.value),
      }),
      ignoredLineCount,
    );
  }

  List<PitchAccentCandidate> lookup({
    required String term,
    required String reading,
  }) =>
      _candidatesByKey[
          _lookupKey(term.trim(), normalizeJapaneseReading(reading))] ??
      const [];

  static String _lookupKey(String term, String normalizedReading) =>
      '$term\u0000$normalizedReading';
}
