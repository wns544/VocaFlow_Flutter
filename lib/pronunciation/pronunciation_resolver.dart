import 'pronunciation_pack.dart';
import 'pronunciation_path.dart';
import 'pronunciation_pack_store.dart';

class ResolvedPronunciation {
  const ResolvedPronunciation(this.entry, this.audioPath);
  final PronunciationPackEntry entry;
  final String audioPath;
}

class PronunciationResolver {
  PronunciationResolver(this.store);
  final PronunciationPackStore store;
  Future<List<InstalledPronunciationPack>>? _installedPacks;

  void invalidate() => _installedPacks = null;

  Future<List<ResolvedPronunciation>> candidates(
      String term, String reading) async {
    final result = <ResolvedPronunciation>[];
    for (final pack in await (_installedPacks ??= store.list())) {
      for (final entry in pack.manifest.entries) {
        if (entry.term == term && entry.reading == reading) {
          result.add(ResolvedPronunciation(
            entry,
            pronunciationAudioPath(pack.rootPath, entry.audioPath),
          ));
        }
      }
    }
    return result;
  }
}
