import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/pronunciation/pronunciation_pack.dart';

void main() {
  test('accepts a bounded manifest with exact candidate records', () {
    final pack = PronunciationPackManifest.parse('''
{"schemaVersion":1,"packId":"sample","entries":[
 {"term":"酒","reading":"さけ","accentPosition":0,"audioPath":"audio/sake-0.wav"},
 {"term":"鮭","reading":"さけ","accentPosition":1,"audioPath":"audio/salmon-1.wav"}
]}
''');
    expect(pack.entries, hasLength(2));
    expect(pack.entries.first.pattern!.isUnaccented, isTrue);
  });

  test('rejects unsafe audio paths', () {
    for (final path in ['../audio/a.wav', 'audio\\a.wav', 'audio/a.mp3']) {
      expect(
        () => PronunciationPackManifest.parse('''
{"schemaVersion":1,"packId":"sample","entries":[
 {"term":"酒","reading":"さけ","accentPosition":0,"audioPath":"$path"}
]}
'''),
        throwsFormatException,
      );
    }
  });
}
