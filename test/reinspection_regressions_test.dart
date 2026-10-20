import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:vocaflow/sync_replica.dart';
import 'package:vocaflow/cloud_change_tracker.dart';
import 'package:vocaflow/card_sync.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

Map<String, dynamic> branch(
        String id, String author, Map<String, int> vector, int clock) =>
    {
      'schema': 2,
      'records': {
        'session/book:current': {
          'clock': clock,
          'device': author,
          'value': {
            'active': {
              'progress': {
                'schema': 1,
                'id': id,
                'device': author,
                'primary': 's23',
                'vector': vector
              }
            },
            'words': {}
          }
        }
      }
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('three branches converge through permutations, restarts and regrouping',
      () {
    final a = branch('phone', 's23', {'s23': 2}, 200);
    final b = branch('offline-pc', 'pc', {'s23': 1, 'pc': 10}, 1100);
    final c =
        branch('tablet-after-phone', 'tablet', {'s23': 2, 'tablet': 1}, 300);
    for (final order in [
      [a, b, c],
      [a, c, b],
      [b, a, c],
      [b, c, a],
      [c, a, b],
      [c, b, a]
    ]) {
      for (var split = 1; split < 3; split++) {
        final first = SyncReplica('first');
        for (final e in order.take(split)) {
          first.merge(e);
        }
        final restarted = SyncReplica('restarted')..merge(first.toJson());
        for (final e in order.skip(split)) {
          restarted.merge(e);
        }
        expect(
            restarted.values['session/book:current']['active']['progress']
                ['id'],
            'tablet-after-phone');
        final peer = SyncReplica('peer')
          ..merge(order.last)
          ..merge(restarted.toJson());
        expect(peer.values, restarted.values);
      }
    }
  });

  test('acknowledged masked card has a durable independent read-back job',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('book',
        [Word(id: 42, term: 'word', reading: 'word', meaning: 'original')]);
    for (final op in store.cardChanges.pending) {
      await store.cardChanges.acknowledge(op);
    }
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: 'my patch'),
        bookId: book.id))!;
    await store.applyCardBookChanges(book.id, [
      CardBookChange(
          number: 2,
          wordId: 42,
          fields: {'meaning': 'later server value'},
          operationId: 'other-device')
    ]);
    await store.cardChanges.acknowledgeRemote(book.id, 2);
    await store.cardChanges.acknowledge(op);
    final restarted = await VocaStore.load();
    final tracker = restarted.cardChanges;
    expect(tracker.pendingCount, 0);
    expect(tracker.appliedChange(book.id), 2);
    expect(tracker.hasWork, isTrue);
    expect(tracker.refreshCards['${book.id}/42'], op.id);
    await restarted.applyCardBookChanges(book.id, [
      CardBookChange(
          number: 0,
          wordId: 42,
          fields: {'meaning': 'later server value'},
          operationId: op.id)
    ]);
    await tracker.acknowledgeRefresh('${book.id}/42', op.id);
    expect(restarted.resolveCard(book.id, 42)!.meaning, 'later server value');
    expect((await VocaStore.load()).cardChanges.hasWork, isFalse);
  });

  test('old read-back acknowledgement cannot clear a newer receipt', () async {
    final tracker = await CardChangeTracker.load();
    final a = (await tracker.enqueue(
        bookId: 'book',
        wordId: 42,
        before: {'meaning': 'a'},
        after: {'meaning': 'b'}))!;
    await tracker.acknowledge(a);
    final b = (await tracker.enqueue(
        bookId: 'book',
        wordId: 42,
        before: {'meaning': 'b'},
        after: {'meaning': 'c'}))!;
    await tracker.acknowledge(b);
    await tracker.acknowledgeRefresh('book/42', a.id);
    expect((await CardChangeTracker.load()).refreshCards['book/42'], b.id);
  });

  test('queued settings status cannot cross account activation or ABA',
      () async {
    final tracker = await CloudChangeTracker.load();
    await tracker.activateAccount('a');
    final epoch = tracker.accountEpoch;
    final late = tracker.recordSettingsFailure('a-only');
    await tracker.activateAccount('b');
    await late;
    expect(tracker.settingsLastError, isNull);
    await tracker.activateAccount('a');
    await tracker.recordSettingsFailure('stale-a', expectedAccountEpoch: epoch);
    expect(tracker.settingsLastError, isNull);
    await tracker.recordSettingsFailure('current-a');
    await tracker.activateAccount('b');
    expect(tracker.settingsLastError, isNull);
    await tracker.activateAccount('a');
    expect(tracker.settingsLastError, 'current-a');
  });
  test('account activation waits for an in-flight settings persistence',
      () async {
    final tracker = await CloudChangeTracker.load();
    await tracker.activateAccount('a');
    final original = SharedPreferencesStorePlatform.instance;
    final disk = _DelayedDisk();
    SharedPreferencesStorePlatform.instance = disk;
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    final failure = tracker.recordSettingsFailure('only-a');
    await disk.started.future;
    var activated = false;
    final activation =
        tracker.activateAccount('b').then((_) => activated = true);
    await Future<void>.delayed(Duration.zero);
    expect(activated, isFalse);
    disk.release.complete();
    await failure;
    await activation;
    expect(tracker.settingsLastError, isNull);
    expect(tracker.channelError('settings'), isNull);
    await tracker.activateAccount('a');
    expect(tracker.settingsLastError, 'only-a');
    expect(tracker.channelError('settings'), 'only-a');
  });
}

class _DelayedDisk extends InMemorySharedPreferencesStore {
  _DelayedDisk() : super.empty();
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!started.isCompleted && key.contains('cloudChangeTracker.v2.a')) {
      started.complete();
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}
