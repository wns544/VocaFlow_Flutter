import 'package:flutter/services.dart';

import 'kanjium_pitch_dictionary.dart';

const bundledPitchDictionaryAsset = 'assets/data/kanjium-accents.txt';

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
    final dictionary = KanjiumPitchDictionary.parse(
      await rootBundle.loadString(bundledPitchDictionaryAsset),
    );
    _dictionary = dictionary;
    return dictionary;
  }

  static Future<List<PitchAccentCandidate>> lookup({
    required String term,
    required String reading,
  }) async =>
      (await load()).lookup(term: term, reading: reading);
}
