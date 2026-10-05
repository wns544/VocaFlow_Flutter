import 'pronunciation_pack_store.dart';

/// The USB companion is intentionally an Android-only convenience. Web builds
/// keep the same call sites, but never put vocabulary into a browser download.
class PronunciationPcBridge {
  PronunciationPcBridge(PronunciationPackStore store);

  Future<void> queueIfNeeded(String term, String reading) async {}
  Future<bool> importIncoming() async => false;
}
