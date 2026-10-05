import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/pronunciation/pronunciation_pack_archive.dart';

Uint8List zipOf(Map<String, Object> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = entry.value is String
        ? utf8.encode(entry.value as String)
        : List<int>.from(entry.value as List<int>);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

List<int> validWav() {
  final bytes = Uint8List(44);
  void ascii(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  void uint32(int offset, int value) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >> 8) & 0xff;
    bytes[offset + 2] = (value >> 16) & 0xff;
    bytes[offset + 3] = (value >> 24) & 0xff;
  }

  ascii(0, 'RIFF');
  uint32(4, 36);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  uint32(16, 16);
  bytes[20] = 1;
  bytes[22] = 1;
  uint32(24, 24000);
  uint32(28, 48000);
  bytes[32] = 2;
  bytes[34] = 16;
  ascii(36, 'data');
  uint32(40, 0);
  return bytes;
}

void main() {
  const manifest = '''
{"schemaVersion":1,"packId":"sample","entries":[
 {"term":"酒","reading":"さけ","accentPosition":0,"audioPath":"audio/sake.wav"}
]}
''';
  test('inspects a manifest and exactly matching audio files', () {
    final pack = PronunciationPackArchive.inspect(zipOf({
      'manifest.json': manifest,
      'audio/sake.wav': validWav(),
    }));
    expect(pack.manifest.entries.single.term, '酒');
    expect(pack.files['audio/sake.wav'], isNotNull);
  });

  test('rejects an unexpected archive file', () {
    expect(
      () => PronunciationPackArchive.inspect(zipOf({
        'manifest.json': manifest,
        'audio/sake.wav': validWav(),
        'extra.txt': 'no',
      })),
      throwsFormatException,
    );
  });

  test('rejects a file that only pretends to be a WAV', () {
    expect(
      () => PronunciationPackArchive.inspect(zipOf({
        'manifest.json': manifest,
        'audio/sake.wav': 'not a WAV',
      })),
      throwsFormatException,
    );
  });
}
