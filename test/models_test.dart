import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/models.dart';

void main() {
  test('session overrides change label and size', () {
    final book = WordBook(
      id: 'book',
      name: '테스트',
      words: List.generate(
        12,
        (index) => Word(
          id: index,
          term: 'word$index',
          meaning: '뜻$index',
          reading: 'reading$index',
        ),
      ),
      sessionOverrides: const {
        0: SessionOverride(name: '첫 묶음', size: 5),
      },
    );

    final sessions = book.sessions(10);
    expect(sessions, hasLength(2));
    expect(sessions.first.label, '첫 묶음');
    expect(sessions.first.words, hasLength(5));
    expect(sessions.last.words, hasLength(7));
  });

  test('word book json preserves session overrides', () {
    final original = WordBook(
      id: 'book',
      name: '테스트',
      words: [Word(id: 1, term: 'term', meaning: '뜻', reading: 'reading')],
      sessionOverrides: const {
        0: SessionOverride(name: '기초', size: 20),
      },
    );

    final restored = WordBook.fromJson(original.toJson());
    expect(restored.sessionOverrides[0]?.name, '기초');
    expect(restored.sessionOverrides[0]?.size, 20);
  });

  test('word book json preserves favorite state', () {
    final original = WordBook(
      id: 'favorite',
      name: '즐겨찾기 단어장',
      words: [],
      isFavorite: true,
    );

    final restored = WordBook.fromJson(original.toJson());

    expect(restored.isFavorite, isTrue);
  });
}
