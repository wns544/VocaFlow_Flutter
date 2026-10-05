import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/pronunciation/pronunciation_pack_archive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled pronunciation pack is a valid installable archive', () async {
    final asset = await rootBundle
        .load('assets/pronunciation/vocaflow-pitch-samples.vfpitch.zip');
    final pack = PronunciationPackArchive.inspect(asset.buffer.asUint8List());
    expect(pack.manifest.entries, isNotEmpty);
    expect(pack.manifest.entries.every((entry) =>
        pack.files.containsKey(entry.audioPath) && entry.pattern != null), isTrue);
  });
}
