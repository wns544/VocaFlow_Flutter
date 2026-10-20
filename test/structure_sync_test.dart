import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/card_sync.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Word word(int id, [String meaning = '뜻']) =>
      Word(id: id, term: 'term$id', reading: 'reading$id', meaning: meaning);
  Future<void> ack(VocaStore store) async {
    for (final op in store.cardChanges.pending) {
      await store.cardChanges.acknowledge(op);
    }
  }

  CardBookSnapshot remote(WordBook book, List<Word> words,
          {String? name, List<Map<String, dynamic>> deleted = const []}) =>
      CardBookSnapshot(book: {
        'id': book.id,
        'name': name ?? book.name,
        'wordOrder': words.map((w) => w.id).toList(),
        'sessionOverrides': {}
      }, cards: [
        ...words.map((w) => w.toJson()),
        ...deleted
      ], changeNumber: 7);

  test('creation is durably queued and reconstructs a cache-write interruption',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('신규', [word(0), word(42)]);
    expect(store.cardChanges.pending.map((op) => op.kind),
        ['bookCreate', 'cardCreate', 'cardCreate']);
    expect(store.cloudChanges.managedBookContentDirty, isFalse);
    // Only the journal survives this simulated cache-write failure.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('books', jsonEncode([store.books.first.toJson()]));
    final restarted = await VocaStore.load();
    expect(
        restarted.books
            .where((b) => b.id == book.id)
            .single
            .words
            .map((w) => w.id),
        [0, 42]);
    expect(restarted.cardChanges.pending, hasLength(3));
  });
  test('rename queues metadata only and preserves canonical learning fields',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('old', [word(42)]);
    await ack(store);
    final canonical = book.words.single;
    await store.mark(canonical, StudyState.memorized, bookId: book.id);
    await store
        .updateBook(WordBook(id: book.id, name: 'new', words: [word(42)]));
    expect(store.cardChanges.pending.single.kind, 'bookPatch');
    expect(store.cardChanges.pending.single.fields, {'name': 'new'});
    expect(identical(store.resolveCard(book.id, 42), canonical), isTrue);
    expect(canonical.state, StudyState.memorized);
    expect(canonical.correctCount, 1);
  });
  test(
      'add and delete operations overlay a partial server refresh without losing work',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('old', [word(1), word(2)]);
    await ack(store);
    await store.updateBook(
        WordBook(id: book.id, name: 'new', words: [word(2), word(3)]));
    expect(store.cardChanges.pending.map((op) => op.kind),
        containsAll(['cardCreate', 'cardDelete', 'bookPatch']));
    await store.mergeCardBooks([
      remote(book, [word(1), word(2)], name: 'old')
    ]);
    final current = store.books.where((b) => b.id == book.id).single;
    expect(current.name, 'new');
    expect(current.words.map((w) => w.id), [2, 3]);
    final restarted = await VocaStore.load();
    expect(
        restarted.books
            .where((b) => b.id == book.id)
            .single
            .words
            .map((w) => w.id),
        [2, 3]);
  });
  test('book deletion survives a stale full download and a restart', () async {
    final store = await VocaStore.load();
    final book = await store.addBook('book', [word(42)]);
    await ack(store);
    await store.deleteBook(book.id);
    expect(store.cardChanges.pending.single.kind, 'bookDelete');
    await store.mergeCardBooks([
      remote(book, [word(42)])
    ]);
    expect(store.books.any((b) => b.id == book.id), isFalse);
    final restarted = await VocaStore.load();
    expect(restarted.books.any((b) => b.id == book.id), isFalse);
    expect(restarted.cardChanges.pending.single.kind, 'bookDelete');
  });
  test(
      'server tombstones suppress stale pending creates without destroying their journal',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('book', [word(42)]);
    await store.applyCardBookDeletion(book.id);
    expect(store.books.any((b) => b.id == book.id), isFalse);
    expect(store.cardChanges.pending, hasLength(2));
    final restarted = await VocaStore.load();
    expect(restarted.books.any((b) => b.id == book.id), isFalse);
    expect(restarted.cardChanges.pending, hasLength(2));
  });
  test('card content deletion preserves its independent memorization history',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('book', [word(42), word(43)]);
    await ack(store);
    await store.mark(book.words.first, StudyState.memorized, bookId: book.id);
    final before = await store.syncV2Snapshot();
    await store.mergeCardBooks([
      remote(book, [
        word(43)
      ], deleted: [
        {'id': 42, 'deleted': true}
      ])
    ]);
    expect(store.resolveCard(book.id, 42), isNull);
    final after = await store.syncV2Snapshot();
    expect(after['records']['word/${book.id}/42'],
        before['records']['word/${book.id}/42']);
  });
  test(
      'legacy work is retained with a recovery copy when it differs from the server',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('book', [word(42, 'my text')]);
    await ack(store);
    await store.cloudChanges.markWord(book.id, 42);
    final verified = await store.verifyLegacyCardWork([
      remote(book, [word(42, 'server text')])
    ], []);
    expect(verified, isFalse);
    expect(store.cloudChanges.managedBookContentDirty, isTrue);
    expect(store.cloudChanges.logs.join(), contains('로컬 백업 보존'));
    expect(store.resolveCard(book.id, 42)!.meaning, 'my text');
  });
  test('legacy work retires only after content equality is verified', () async {
    final store = await VocaStore.load();
    final book = await store.addBook('book', [word(42)]);
    await ack(store);
    await store.cloudChanges.markWord(book.id, 42);
    expect(await store.verifyLegacyCardWork([remote(book, book.words)], []),
        isTrue);
    expect(store.cloudChanges.managedBookContentDirty, isFalse);
  });
  test('structural acknowledgement keeps an interrupted refresh retryable', () async {
    final store = await VocaStore.load();
    final book = await store.addBook('book', [word(42)]);
    await store.cardChanges.acknowledgeRemote(book.id, 7);
    await store.cardChanges.acknowledge(store.cardChanges.pending.first);
    expect(store.cardChanges.hasAppliedBook(book.id), isFalse);
    final restarted = await VocaStore.load();
    expect(restarted.cardChanges.hasAppliedBook(book.id), isFalse);
  });
}
