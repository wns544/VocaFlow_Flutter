import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'kanjium_pitch_dictionary.dart';

const bundledPitchDictionaryAsset = 'assets/data/kanjium-accents.txt';

KanjiumPitchDictionary _parsePitchDictionary(String source) =>
    KanjiumPitchDictionary.parse(source);

/// The immutable accent data is loaded separately from cards. It is never
/// copied to Firestore or used to rewrite an imported word.
class BundledPitchDictionary {
  BundledPitchDictionary._();

  static KanjiumPitchDictionary? _dictionary;
  static Future<KanjiumPitchDictionary>? _loading;

  /// Avoid delaying an audio tap while the bundled snapshot is parsed once.
  static KanjiumPitchDictionary? get cached => _dictionary;

  static Future<KanjiumPitchDictionary> load() => _loading ??= _loadFromAsset();

  static Future<KanjiumPitchDictionary> _loadFromAsset() async {
    final source = await rootBundle.loadString(bundledPitchDictionaryAsset);
    final dictionary = await compute(_parsePitchDictionary, source);
    _dictionary = dictionary;
    return dictionary;
  }

  static Future<List<PitchAccentCandidate>> lookup({
    required String term,
    required String reading,
  }) async =>
      (await load()).lookup(term: term, reading: reading);
}
