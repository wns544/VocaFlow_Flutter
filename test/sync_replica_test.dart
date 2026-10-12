import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';
import 'package:vocaflow/sync_replica.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('independent fields merge, deletions persist, clock observes remote', () {
    final a = SyncReplica('a')..seed({'font': 20, 'url': 'old'});
    final b = SyncReplica('b')..seed({'font': 20, 'url': 'old'});
    a.capture({'font': 30, 'url': 'old'}, nowMicros: 100);
    b.capture({'font': 20, 'url': null}, nowMicros: 200);
    a.merge(b.toJson());
    expect(a.values, {'font': 30, 'url': null});
    a.acceptView(a.values);
    a.capture({'font': 25, 'url': null}, nowMicros: 50);
    expect(a.clock, 201);
    b.merge(a.toJson());
    expect(b.values, a.values);
  });

  test('conflicting queues converge and preserve losing branch', () {
    final a = SyncReplica('a')..seed({'session/s': {'queue': [1, 2]}});
    final b = SyncReplica('b')..seed({'session/s': {'queue': [1, 2]}});
    a.capture({'session/s': {'queue': [2]}}, nowMicros: 100);
    b.capture({'session/s': {'queue': [1]}}, nowMicros: 200);
    a.merge(b.toJson());
    b.merge(a.toJson());
    expect(a.values, b.values);
    expect(a.recovery.values.any((r) => r['clock'] == 100), isTrue);
  });

  test('remote memorized state cannot resurrect after reset', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final word = store.books.first.words.first;
    await store.mark(word, StudyState.memorized, bookId: 'default');
    await store.completeSessions('default', [0]);
    final old = await store.syncV2Snapshot();
    await store.resetProgress();
    await store.applySyncV2([old]);
    expect(store.books.first.words.first.state, StudyState.fresh);
    expect(store.isSessionCompleted('default', 0), isFalse);
    expect(store.dailyStudyStats.values.every((s) => s.studiedCards == 0), isTrue);
  });

  test('undo reverses stats and survives stale cloud merge', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final word = store.books.first.words.first;
    await store.mark(word, StudyState.memorized, bookId: 'default');
    final old = await store.syncV2Snapshot();
    await store.undoWordDecision(word, StudyState.fresh, bookId: 'default');
    await store.applySyncV2([old]);
    expect(store.books.first.words.first.state, StudyState.fresh);
    expect(store.dailyStudyStats.values.fold<int>(0, (n, s) => n + s.studiedCards), 0);
  });

  test('completed membership survives resize without moving completion', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final book = await store.addBook('test', List.generate(30, (i) =>
      Word(id: i, term: '$i', reading: '$i', meaning: '$i')));
    await store.completeSessions(book.id, [0]);
    await store.setSessionSize(20);
    expect(store.isSessionCompleted(book.id, 0), isFalse);
    await store.setSessionSize(10);
    expect(store.isSessionCompleted(book.id, 0), isTrue);
  });

  test('latest account checkpoint survives restart with progress and settings', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.activateAccount('a');
    await store.completeSessions('default', [0]);
    await store.setUndoHaptics(true);
    final next = await VocaStore.load();
    await next.activateAccount('a');
    expect(next.isSessionCompleted('default', 0), isTrue);
    expect(next.undoHaptics, isTrue);
  });

  test('every shared preference and a favorite are represented separately',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.setCardFontSizes(
        term: 41, reading: 17, meaning: 25, example: 18, exampleMeaning: 15);
    await store.setAutoPlayPronunciation(false);
    final word = store.books.first.words.first;
    await store.setWordFavorite(word, true, bookId: 'default');
    final snapshot = await store.syncV2Snapshot();
    final records = snapshot['records'] as Map;
    expect(records['setting/termFontSize']['value'], 41.0);
    expect(records['setting/autoPlayPronunciation']['value'], isFalse);
    expect(records['favorite/default/${word.id}']['value'], isTrue);
  });
}
