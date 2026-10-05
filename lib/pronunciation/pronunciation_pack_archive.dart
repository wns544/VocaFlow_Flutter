import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'pronunciation_pack.dart';

class PronunciationPackArchive {
  const PronunciationPackArchive({required this.manifest, required this.files});

  final PronunciationPackManifest manifest;
  final Map<String, Uint8List> files;

  static const _maximumFiles = 20001;
  static const _maximumBytes = 250 * 1024 * 1024;
  static const _maximumAudioBytes = 10 * 1024 * 1024;
  static const _maximumAudioSeconds = 60;

  factory PronunciationPackArchive.inspect(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length > _maximumFiles) {
      throw const FormatException('Too many files in pronunciation pack.');
    }
    final files = <String, Uint8List>{};
    var totalBytes = 0;
    for (final file in archive.files) {
      if (!file.isFile ||
          file.name.contains('..') ||
          file.name.contains('\\')) {
        throw const FormatException('Unsafe pronunciation pack file.');
      }
      final content = file.content;
      if (content is! List<int> || files.containsKey(file.name)) {
        throw const FormatException('Invalid pronunciation pack file.');
      }
      totalBytes += content.length;
      if (totalBytes > _maximumBytes) {
        throw const FormatException('Pronunciation pack is too large.');
      }
      if (file.name.startsWith('audio/') &&
          (content.length > _maximumAudioBytes || !_isSafeWav(content))) {
        throw const FormatException('Invalid pronunciation WAV file.');
      }
      files[file.name] = Uint8List.fromList(content);
    }
    final manifestBytes = files['manifest.json'];
    if (manifestBytes == null) {
      throw const FormatException('Pronunciation pack has no manifest.');
    }
    final manifest =
        PronunciationPackManifest.parse(utf8.decode(manifestBytes));
    final expectedAudio =
        manifest.entries.map((entry) => entry.audioPath).toSet();
    if (!expectedAudio.every(files.containsKey) ||
        files.keys.any((path) =>
            path != 'manifest.json' && !expectedAudio.contains(path))) {
      throw const FormatException(
          'Pronunciation pack files do not match manifest.');
    }
    return PronunciationPackArchive(
      manifest: manifest,
      files: Map.unmodifiable(files),
    );
  }

  static bool _isSafeWav(List<int> bytes) {
    if (bytes.length < 44 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      return false;
    }
    var offset = 12;
    int? byteRate;
    int? dataLength;
    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkLength = _uint32(bytes, offset + 4);
      final next = offset + 8 + chunkLength + (chunkLength.isOdd ? 1 : 0);
      if (next > bytes.length) return false;
      if (chunkId == 'fmt ' && chunkLength >= 16) {
        byteRate = _uint32(bytes, offset + 16);
      } else if (chunkId == 'data') {
        dataLength = chunkLength;
      }
      offset = next;
    }
    return byteRate != null &&
        byteRate > 0 &&
        dataLength != null &&
        dataLength <= byteRate * _maximumAudioSeconds;
  }

  static int _uint32(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
