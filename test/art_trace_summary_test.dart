import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../tools/summarize_art_trace.dart';

void main() {
  Uint8List fixture() {
    final header = utf8.encode(
        '*version\n3\nclock=dual\ndata-file-overflow=false\n*threads\n1\tworker\n*methods\n0x4\tStore\tcommit\t()V\n0x8\tXml\tencode\t()V\n*end\n');
    final data = ByteData(32 + 4 * 14);
    data.setUint32(0, 0x574f4c53, Endian.little);
    data.setUint16(4, 3, Endian.little);
    data.setUint16(6, 32, Endian.little);
    data.setUint16(16, 14, Endian.little);
    final transitions = [
      [4, 100],
      [8, 110],
      [9, 160],
      [5, 180]
    ];
    for (var i = 0; i < transitions.length; i++) {
      final offset = 32 + i * 14;
      data.setUint16(offset, 1, Endian.little);
      data.setUint32(offset + 2, transitions[i][0], Endian.little);
      data.setUint32(offset + 6, transitions[i][1], Endian.little);
      // Wall time deliberately differs: CPU accounting must use thread CPU.
      data.setUint32(offset + 10, i * 10000, Endian.little);
    }
    return Uint8List.fromList([...header, ...data.buffer.asUint8List()]);
  }

  test('separates child CPU from parent CPU and ignores wall wait', () {
    final result = summarizeArtTrace(fixture());
    expect(result['stackMismatches'], 0);
    expect((result['threads'] as List).single['cpuMs'], 0.08);
    final exclusive = result['exclusiveMethods'] as List;
    expect(exclusive.first, {'name': 'Xml.encode', 'cpuMs': 0.05});
    expect(exclusive.last, {'name': 'Store.commit', 'cpuMs': 0.03});
    expect((result['inclusiveMethods'] as List).first,
        {'name': 'Store.commit', 'cpuMs': 0.08});
  });

  test('rejects truncated data instead of reporting partial attribution', () {
    final bytes = fixture();
    expect(() => summarizeArtTrace(bytes.sublist(0, bytes.length - 1)),
        throwsFormatException);
  });
}
