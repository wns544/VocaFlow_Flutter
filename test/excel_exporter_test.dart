import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/excel_exporter.dart';
import 'package:vocaflow/excel_parser.dart';
import 'package:vocaflow/models.dart';

void main() {
  test('exported Excel restores all five word columns', () {
    final book = WordBook(
      id: 'custom-book',
      name: '내 단어장',
      words: [
        Word(
          term: 'ephemeral',
          meaning: '덧없는',
          reading: '/ɪˈfem.ər.əl/',
          example: 'Fame can be ephemeral.',
          exampleMeaning: '명성은 덧없을 수 있다.',
        ),
      ],
    );

    final restored = parseWordsXlsx(createWordBookXlsx(book));

    expect(restored, hasLength(1));
    expect(restored.single.term, 'ephemeral');
    expect(restored.single.meaning, '덧없는');
    expect(restored.single.reading, '/ɪˈfem.ər.əl/');
    expect(restored.single.example, 'Fame can be ephemeral.');
    expect(restored.single.exampleMeaning, '명성은 덧없을 수 있다.');
  });

  test('empty word book still creates a valid Excel file', () {
    final book = WordBook(id: 'empty', name: '빈 단어장', words: []);

    final bytes = createWordBookXlsx(book);

    expect(bytes, isNotEmpty);
    expect(parseWordsXlsx(bytes), isEmpty);
  });
}
