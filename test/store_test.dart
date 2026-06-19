import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  test('book sorting and custom order persist', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.addBook('Zebra', []);
    await store.addBook('Alpha', []);

    await store.sortBooksByName();
    expect(store.books.map((book) => book.name), ['Alpha', 'Zebra', '기본 단어장']);

    await store.reorderBooks(2, 0);
    expect(store.books.map((book) => book.name), ['기본 단어장', 'Alpha', 'Zebra']);

    final reloaded = await VocaStore.load();
    expect(
        reloaded.books.map((book) => book.name), ['기본 단어장', 'Alpha', 'Zebra']);
  });

  test('completed session state persists', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    expect(store.isSessionCompleted('default', 0), isFalse);
    await store.completeSessions('default', [0]);
    expect(store.isSessionCompleted('default', 0), isTrue);

    final reloaded = await VocaStore.load();
    expect(reloaded.isSessionCompleted('default', 0), isTrue);
    expect(reloaded.completedCount(reloaded.quickBook), 1);
  });

  test('swipe direction settings persist', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setHorizontalSwipe(true);
    await store.setReverseSwipe(true);

    final reloaded = await VocaStore.load();
    expect(reloaded.horizontalSwipe, isTrue);
    expect(reloaded.reverseSwipe, isTrue);
  });

  test('active study position persists', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final words = store.nextWords();
    await store.saveActiveStudy(ActiveStudy(
      queueIds: words.skip(1).map((word) => word.id).toList(),
      total: words.length,
      memorized: 1,
      reviewed: const ['ephemeral'],
      revealed: true,
      bookId: 'default',
      sessionIndexes: const [0],
      lastWordId: words.first.id,
      lastState: StudyState.memorized,
    ));

    final reloaded = await VocaStore.load();
    final active = reloaded.activeStudy!;
    expect(active.queueIds, words.skip(1).map((word) => word.id).toList());
    expect(active.memorized, 1);
    expect(active.revealed, isTrue);
    expect(active.lastState, StudyState.memorized);
    expect(reloaded.resolveActiveWords(active).first.term, 'resilience');
  });
}
