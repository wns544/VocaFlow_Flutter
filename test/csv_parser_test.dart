import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/csv_parser.dart';

void main() {
  test('deduplicates normalized cards and merges related targets in order', () {
    final result = parseWordImportCsv(
        '단어,발음,뜻,관련단어\nあえて,ㆍ,감히,愛想\n愛想,あいそう,붙임성,\nあえて,,감히,"愛想,協力"\nあえて,あえて,감히,協力');
    expect(result.words.map((w) => w.term), ['あえて', '愛想']);
    expect(result.words.first.reading, 'あえて');
    expect(result.relations.map((r) => r.sourceWordIndex), [0, 0]);
    expect(result.relations.map((r) => r.targetTerm), ['愛想', '協力']);
  });

  test('keeps different readings meanings and example content', () {
    final words = parseWordsCsv(
        'word,reading,meaning,example,exampleMeaning,explanation\nx,a,A,one,1,note\nx,a,A,two,1,note\nx,b,A,one,1,note\nx,a,B,one,1,note\nx,a,A,one,2,note\nx,a,A,one,1,other\nx,a,A,one,1,note');
    expect(words, hasLength(6));
  });
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
  test('headerless rows keep fixed term-reading-meaning columns', () {
    final words = parseWordsCsv('あえて,ㆍ,"감히, 굳이"\n愛想,あいそう,붙임성\nあかす,,밝히다');

    expect(words, hasLength(3));
    expect(words[0].term, 'あえて');
    expect(words[0].reading, 'あえて');
    expect(words[0].meaning, '감히, 굳이');
    expect(words[1].reading, 'あいそう');
    expect(words[1].meaning, '붙임성');
    expect(words[2].reading, 'あかす');
    expect(words[2].meaning, '밝히다');
  });

  test('headerless chapter separator row is not imported as a word', () {
    final words = parseWordsCsv('Chapter 01,,\n足手まとい,あしでまとい,거치적거림');

    expect(words, hasLength(1));
    expect(words.single.term, '足手まとい');
  });
  test('related words column is parsed separately from card fields', () {
    final result = parseWordImportCsv(
        '단어,뜻,발음,관련단어\n貢献,공헌,こうけん,"寄与, 協力"\n寄与,기여,きよ\n協力,협력,きょうりょく');

    expect(result.words.map((word) => word.term), ['貢献', '寄与', '協力']);
    expect(result.relations, hasLength(2));
    expect(result.relations.first.sourceWordIndex, 0);
    expect(
        result.relations.map((relation) => relation.targetTerm), ['寄与', '協力']);
  });
}
