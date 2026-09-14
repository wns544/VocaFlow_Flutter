import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/word_relations.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a relation is one bidirectional record with a stable id', () {
    const first = RelatedWordRef(bookId: 'book-a', wordId: 1);
    const second = RelatedWordRef(bookId: 'book-b', wordId: 2);

    expect(relationIdFor(first, second), relationIdFor(second, first));
  });

  test('toggle creates and removes a relation without touching card data',
      () async {
    final relations = WordRelationStore();
    await relations.load();
    const first = RelatedWordRef(bookId: 'book-a', wordId: 1);
    const second = RelatedWordRef(bookId: 'book-b', wordId: 2);

    await relations.toggle(first, second);
    expect(relations.isRelated(first, second), isTrue);
    expect(relations.forWord(second), hasLength(1));

    await relations.toggle(first, second);
    expect(relations.isRelated(first, second), isFalse);
    expect(relations.forWord(first), isEmpty);
  });
  test('addAll creates relations idempotently without toggling them off',
      () async {
    final relations = WordRelationStore();
    await relations.load();
    const first = RelatedWordRef(bookId: 'book-a', wordId: 1);
    const second = RelatedWordRef(bookId: 'book-a', wordId: 2);

    expect(await relations.addAll(const [WordRelationPair(first, second)]), 1);
    expect(await relations.addAll(const [WordRelationPair(second, first)]), 0);

    expect(relations.isRelated(first, second), isTrue);
    expect(relations.all, hasLength(1));
  });
}
