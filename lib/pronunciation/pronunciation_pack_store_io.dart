import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'pronunciation_pack_archive.dart';
import 'pronunciation_pack.dart';

class InstalledPronunciationPack {
  const InstalledPronunciationPack(this.rootPath, this.manifest);
  final String rootPath;
  final PronunciationPackManifest manifest;
}

class PronunciationPackStore {
  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final root =
        Directory('${support.path}${Platform.pathSeparator}pronunciation');
    await root.create(recursive: true);
    return root;
  }

  Future<String> install(Uint8List bytes) async {
    final archive = PronunciationPackArchive.inspect(bytes);
    final root = await _root();
    final target = Directory(
        '${root.path}${Platform.pathSeparator}${archive.manifest.packId}');
    if (await target.exists()) return target.path;
    final staging = Directory(
        '${root.path}${Platform.pathSeparator}.${archive.manifest.packId}.staging');
    await staging.create(recursive: true);
    try {
      for (final file in archive.files.entries) {
        final output =
            File('${staging.path}${Platform.pathSeparator}${file.key}');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(file.value, flush: true);
      }
      await staging.rename(target.path);
      return target.path;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<List<InstalledPronunciationPack>> list() async {
    final result = <InstalledPronunciationPack>[];
    await for (final entity in (await _root()).list()) {
      if (entity is! Directory || entity.path.endsWith('.staging')) continue;
      final file = File('${entity.path}${Platform.pathSeparator}manifest.json');
      if (!await file.exists()) continue;
      try {
        result.add(InstalledPronunciationPack(
          entity.path,
          PronunciationPackManifest.parse(await file.readAsString()),
        ));
      } catch (_) {}
    }
    return result;
  }
}
