import 'dart:convert';

import 'pitch_accent.dart';

class PronunciationPackEntry {
  const PronunciationPackEntry({
    required this.term,
    required this.reading,
    required this.accentPosition,
    required this.audioPath,
  });

  final String term;
  final String reading;
  final int accentPosition;
  final String audioPath;

  PitchAccentPattern? get pattern => PitchAccentPattern.tryCreate(
        reading: reading,
        accentPosition: accentPosition,
      );

  String get candidateId => '$term\u0000$reading\u0000$accentPosition';
}

/// Parsed before a ZIP is extracted. It accepts only relative WAV paths and
/// only entries with a valid word-level accent pattern.
class PronunciationPackManifest {
  const PronunciationPackManifest({
    required this.packId,
    required this.entries,
  });

  static const schemaVersion = 1;
  final String packId;
  final List<PronunciationPackEntry> entries;

  factory PronunciationPackManifest.parse(String source) {
    final json = Map<String, dynamic>.from(jsonDecode(source) as Map);
    if (json['schemaVersion'] != schemaVersion) {
      throw const FormatException('Unsupported pronunciation pack version.');
    }
    final packId = json['packId'] as String? ?? '';
    final rawEntries = json['entries'];
    if (packId.isEmpty || rawEntries is! List || rawEntries.length > 20000) {
      throw const FormatException('Invalid pronunciation pack manifest.');
    }
    final entries = <PronunciationPackEntry>[];
    final candidates = <String>{};
    for (final raw in rawEntries) {
      final item = Map<String, dynamic>.from(raw as Map);
      final entry = PronunciationPackEntry(
        term: item['term'] as String? ?? '',
        reading: item['reading'] as String? ?? '',
        accentPosition: (item['accentPosition'] as num?)?.toInt() ?? -1,
        audioPath: item['audioPath'] as String? ?? '',
      );
      if (entry.term.isEmpty ||
          entry.pattern == null ||
          !_isSafeAudioPath(entry.audioPath) ||
          !candidates.add(entry.candidateId)) {
        throw const FormatException('Invalid pronunciation pack entry.');
      }
      entries.add(entry);
    }
    return PronunciationPackManifest(packId: packId, entries: entries);
  }

  static bool _isSafeAudioPath(String value) =>
      value.startsWith('audio/') &&
      value.endsWith('.wav') &&
      !value.contains('..') &&
      !value.contains('\\') &&
      !value.startsWith('/');
}
