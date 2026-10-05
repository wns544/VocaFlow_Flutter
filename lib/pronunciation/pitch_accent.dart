/// Utilities shared by Japanese pitch-accent lookup, display, and audio-pack
/// generation. They intentionally do not alter a vocabulary card's reading.
library;

enum PitchLevel { low, high }

/// Converts katakana to hiragana so a dictionary's reading and a card's
/// reading can be compared without changing the card data itself.
String normalizeJapaneseReading(String reading) {
  final trimmed = reading.trim();
  final buffer = StringBuffer();
  for (final codeUnit in trimmed.codeUnits) {
    if (codeUnit == 0x30F5) {
      buffer.write('か');
    } else if (codeUnit == 0x30F6) {
      buffer.write('け');
    } else if (codeUnit >= 0x30A1 && codeUnit <= 0x30F6) {
      buffer.writeCharCode(codeUnit - 0x60);
    } else if (codeUnit == 0x30F7) {
      buffer.write('ゔぁ');
    } else if (codeUnit == 0x30F8) {
      buffer.write('ゔぃ');
    } else if (codeUnit == 0x30F9) {
      buffer.write('ゔぇ');
    } else if (codeUnit == 0x30FA) {
      buffer.write('ゔぉ');
    } else {
      buffer.writeCharCode(codeUnit);
    }
  }
  return buffer.toString();
}

const _smallKana = <String>{
  'ぁ',
  'ぃ',
  'ぅ',
  'ぇ',
  'ぉ',
  'ゃ',
  'ゅ',
  'ょ',
  'ゎ',
  'ゕ',
  'ゖ',
};

bool _isHiraganaOrLongMark(String character) {
  final codeUnit = character.codeUnitAt(0);
  return (codeUnit >= 0x3041 && codeUnit <= 0x3096) || character == 'ー';
}

/// Splits a single Japanese reading into morae (拍).
///
/// Returns null when the input cannot safely be rendered as a word-level
/// pitch pattern, rather than guessing how punctuation or a phrase divides.
List<String>? splitJapaneseMorae(String reading) {
  final normalized = normalizeJapaneseReading(reading);
  if (normalized.isEmpty) return null;

  final morae = <String>[];
  for (final codeUnit in normalized.codeUnits) {
    final character = String.fromCharCode(codeUnit);
    if (!_isHiraganaOrLongMark(character)) return null;
    if (_smallKana.contains(character)) {
      if (morae.isEmpty) return null;
      morae[morae.length - 1] += character;
    } else {
      morae.add(character);
    }
  }
  return morae.isEmpty ? null : List.unmodifiable(morae);
}

/// A dictionary accent position: 0 means unaccented; a positive position is
/// the mora after which the pitch drops. The position may equal moraCount,
/// because that drop is heard after the standalone word when a particle follows.
class PitchAccentPattern {
  const PitchAccentPattern._({
    required this.reading,
    required this.morae,
    required this.accentPosition,
    required this.levels,
  });

  final String reading;
  final List<String> morae;
  final int accentPosition;
  final List<PitchLevel> levels;

  bool get isUnaccented => accentPosition == 0;

  int? get internalDropAfterMora =>
      accentPosition == 0 || accentPosition >= morae.length
          ? null
          : accentPosition;

  bool get hasParticleOnlyDrop => accentPosition == morae.length;

  static PitchAccentPattern? tryCreate({
    required String reading,
    required int accentPosition,
  }) {
    final morae = splitJapaneseMorae(reading);
    if (morae == null || accentPosition < 0 || accentPosition > morae.length) {
      return null;
    }

    final levels = <PitchLevel>[];
    for (var index = 0; index < morae.length; index++) {
      final moraNumber = index + 1;
      final isHigh = accentPosition == 1
          ? moraNumber == 1
          : accentPosition == 0
              ? moraNumber > 1
              : moraNumber > 1 && moraNumber <= accentPosition;
      levels.add(isHigh ? PitchLevel.high : PitchLevel.low);
    }
    return PitchAccentPattern._(
      reading: normalizeJapaneseReading(reading),
      morae: morae,
      accentPosition: accentPosition,
      levels: List.unmodifiable(levels),
    );
  }
}
