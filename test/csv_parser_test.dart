import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/csv_parser.dart';

void main() {
  test('quoted commas and escaped quotes are parsed', () {
    final words = parseWordsCsv(
        'term,meaning,reading,example,exampleMeaning\n"take off","벗다, 이륙하다",teik-off,"He said ""go"", then left.",그는 출발했다.');
    expect(words, hasLength(1));
    expect(words.single.term, 'take off');
    expect(words.single.meaning, '벗다, 이륙하다');
    expect(words.single.example, 'He said "go", then left.');
  });

  test('invalid rows are skipped', () {
    final words = parseWordsCsv(
        'term,meaning,reading\nvalid,유효한,val-id\nmissing,meaning');
    expect(words.map((word) => word.term), ['valid']);
  });

  test('CSV header may place reading before meaning', () {
    final words = parseWordsCsv('단어,발음,뜻\n遺跡,いせき,유적');

    expect(words.single.reading, 'いせき');
    expect(words.single.meaning, '유적');
  });
}
