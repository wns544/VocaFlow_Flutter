import 'dart:typed_data';

import 'pronunciation_pack.dart';

class InstalledPronunciationPack {
  const InstalledPronunciationPack(this.rootPath, this.manifest);
  final String rootPath;
  final PronunciationPackManifest manifest;
}

class PronunciationPackStore {
  Future<String> install(Uint8List bytes) =>
      Future.error(UnsupportedError('음성팩 설치는 Android 앱에서 지원됩니다.'));

  Future<List<InstalledPronunciationPack>> list() async => const [];
}
