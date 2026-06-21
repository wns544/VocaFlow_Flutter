import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/local_word_search.dart';
import 'package:vocaflow/models.dart';

void main() {
  test('ranks matches without disturbing source order inside a rank', () {
    final books = [
      WordBook(
        id: 'book',
        name: 'App collection',
        words: [
          _word(1, 'snapper'),
          _word(2, 'app'),
          _word(3, 'apple'),
          _word(4, 'apply'),
          _word(5, 'sound', reading: 'apple sound'),
          _word(6, 'meaning', meaning: 'an app definition'),
          _word(7, 'example', example: 'use this app'),
          _word(8, 'unrelated'),
        ],
      ),
    ];
    final index = LocalWordSearchIndex(() => books);

    final results = index.createSession().search('app');

    expect(results.map((hit) => hit.word.id), [2, 3, 4, 5, 1, 6, 7, 8]);
  });

  test('an extended query evaluates only previous matches', () {
    final books = [
      WordBook(
        id: 'large',
        name: 'Large',
        words: List.generate(10000, (index) => _word(index, 'item-$index')),
      ),
    ];
    final session = LocalWordSearchIndex(() => books).createSession();

    final first = session.search('item-9');
    expect(session.lastEvaluatedCount, 10000);
    expect(first.length, lessThan(10000));

    session.search('item-99');
    expect(session.lastEvaluatedCount, first.length);
  });

  test('backspace starts from the complete index again', () {
    final books = [
      WordBook(
        id: 'book',
        name: 'Book',
        words: [_word(1, 'apple'), _word(2, 'apricot'), _word(3, 'banana')],
      ),
    ];
    final session = LocalWordSearchIndex(() => books).createSession();
    session.search('ap');
    session.search('app');

    session.search('a');

    expect(session.lastEvaluatedCount, 3);
  });

  test('invalidation rebuilds normalized documents after edits', () {
    final book = WordBook(
      id: 'book',
      name: 'Book',
      words: [_word(1, 'before')],
    );
    final index = LocalWordSearchIndex(() => [book]);
    final session = index.createSession();
    expect(session.search('before'), hasLength(1));

    book.words[0] = _word(1, 'after');
    index.invalidate();

    expect(session.search('before'), isEmpty);
    expect(session.search('after').single.word.term, 'after');
  });

  test('book-scoped search excludes book-name-only matches', () {
    final books = [
      WordBook(
        id: 'a',
        name: 'JLPT collection',
        words: [_word(1, 'unrelated')],
      ),
      WordBook(
        id: 'b',
        name: 'Other',
        words: [_word(2, 'JLPT word')],
      ),
    ];
    final index = LocalWordSearchIndex(() => books);

    expect(index.createSession().search('jlpt'), hasLength(2));
    expect(index.createSession(bookId: 'a').search('jlpt'), isEmpty);
    expect(index.createSession(bookId: 'b').search('jlpt').single.word.id, 2);
  });
}

Word _word(
  int id,
  String term, {
  String reading = '',
  String meaning = '',
  String example = '',
}) =>
    Word(
      id: id,
      term: term,
      reading: reading,
      meaning: meaning,
      example: example,
    );
