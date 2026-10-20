import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:vocaflow/card_sync.dart';

void main() {
  test('late account A receipt cannot clear account B edits to the same card',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = await CardChangeTracker.load();
    await tracker.activateAccount('a');
    final a = (await tracker.enqueue(
        bookId: 'same-book',
        wordId: 42,
        before: {'meaning': 'old'},
        after: {'meaning': 'account-a'}))!;
    await tracker.activateAccount('b');
    final b = (await tracker.enqueue(
        bookId: 'same-book',
        wordId: 42,
        before: {'meaning': 'old'},
        after: {'meaning': 'account-b'}))!;
    await tracker.acknowledge(a);
    expect(tracker.pending.map((op) => op.id), [b.id]);
    expect(tracker.wasAcknowledged(a.id), isFalse);
    expect(tracker.refreshCards, isEmpty);
    final restarted = await CardChangeTracker.load();
    await restarted.activateAccount('a');
    expect(restarted.pending.map((op) => op.id), [a.id]);
    await restarted.activateAccount('b');
    expect(restarted.pending.map((op) => op.id), [b.id]);
  });
  for (final batch in [false, true]) {
    test(
        'sender cannot see a ${batch ? 'batch' : 'single'} operation before durable local save',
        () async {
      SharedPreferences.setMockInitialValues({});
      final tracker = await CardChangeTracker.load();
      final original = SharedPreferencesStorePlatform.instance;
      final disk = _DelayedWrites();
      SharedPreferencesStorePlatform.instance = disk;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final Future<dynamic> saving = batch
          ? tracker.enqueueBatch([
              {
                'bookId': 'book',
                'wordId': 42,
                'kind': 'cardPatch',
                'fields': {'meaning': 'new'}
              }
            ])
          : tracker.enqueue(
              bookId: 'book',
              wordId: 42,
              before: {'meaning': 'old'},
              after: {'meaning': 'new'});
      await disk.started.future;
      expect(tracker.pending, isEmpty);
      expect(tracker.isDirty, isFalse);
      expect(tracker.pendingFields('book', 42), isEmpty);
      disk.release.complete();
      await saving;
      expect(tracker.pending, hasLength(1));
      expect(tracker.pendingFields('book', 42), {'meaning': 'new'});
    });
  }
  test(
      'failed local enqueue never leaves an undurable edit available to the sender',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = await CardChangeTracker.load();
    final existing = (await tracker.enqueue(
        bookId: 'book',
        wordId: 42,
        before: {'meaning': 'a'},
        after: {'meaning': 'b'}))!;
    final original = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _RejectedWrites();
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    var notified = false;
    tracker.onChanged = () => notified = true;
    await expectLater(
        tracker.enqueue(
            bookId: 'book',
            wordId: 43,
            before: {'meaning': 'c'},
            after: {'meaning': 'd'}),
        throwsStateError);
    expect(tracker.pending.map((op) => op.id), [existing.id]);
    expect(tracker.pendingFields('book', 43), isEmpty);
    expect(notified, isFalse);
  });
  test('missing delta in the middle or at the end requires a full recheck', () {
    CardBookChange delta(int n) =>
        CardBookChange(number: n, wordId: 42, fields: {}, operationId: '$n');
    expect(cardDeltasCover(5, 8, [delta(6), delta(8)]), isFalse);
    expect(cardDeltasCover(5, 8, [delta(6), delta(7)]), isFalse);
    expect(cardDeltasCover(5, 8, [delta(6), delta(7), delta(8)]), isTrue);
    expect(cardDeltasCover(5, 8, [delta(6), delta(7), delta(8), delta(9)]),
        isTrue);
  });
  test(
      'failed durable acknowledgement keeps operation pending, never marks saved',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = await CardChangeTracker.load();
    final op = (await tracker.enqueue(
        bookId: 'book',
        wordId: 42,
        before: {'meaning': 'old'},
        after: {'meaning': 'new'}))!;
    final original = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _RejectedWrites();
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    await expectLater(tracker.acknowledge(op), throwsStateError);
    expect(tracker.contains(op.id), isTrue);
    expect(tracker.wasAcknowledged(op.id), isFalse);
    expect(tracker.lastSuccess, isNull);
  });
  test('keeps a field-only card operation across a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = await CardChangeTracker.load();
    await tracker.activateAccount('user-a');
    final operation = await tracker.enqueue(
      bookId: 'book-a',
      wordId: 42,
      before: const {
        'term': '止める',
        'reading': 'とめる',
        'meaning': '멈추다',
        'example': '',
      },
      after: const {
        'term': '止める',
        'reading': 'とめる',
        'meaning': '그만두다',
        'example': '',
      },
    );

    expect(operation, isNotNull);
    expect(operation!.fields, {'meaning': '그만두다'});
    expect(operation.before, {'meaning': '멈추다'});

    final restarted = await CardChangeTracker.load();
    await restarted.activateAccount('user-a');
    expect(restarted.pending, hasLength(1));
    expect(restarted.pending.single.id, operation.id);
    await restarted.acknowledge(restarted.pending.single);
    expect(restarted.pending, isEmpty);
    expect(restarted.wasAcknowledged(operation.id), isTrue);
    final afterReceipt = await CardChangeTracker.load();
    await afterReceipt.activateAccount('user-a');
    expect(afterReceipt.wasAcknowledged(operation.id), isTrue);
    await afterReceipt.activateAccount('user-b');
    expect(afterReceipt.wasAcknowledged(operation.id), isFalse);
  });

  test('does not acknowledge a newer edit while an older request finishes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tracker = await CardChangeTracker.load();
    await tracker.activateAccount('user-a');
    final first = await tracker.enqueue(
      bookId: 'book-a',
      wordId: 42,
      before: const {'meaning': '첫 뜻'},
      after: const {'meaning': '둘 뜻'},
    );
    await tracker.enqueue(
      bookId: 'book-a',
      wordId: 42,
      before: const {'meaning': '둘 뜻'},
      after: const {'meaning': '셋 뜻'},
    );
    await tracker.acknowledge(first!);
    expect(tracker.pending, hasLength(1));
    expect(tracker.pending.single.fields['meaning'], '셋 뜻');
  });
}

class _RejectedWrites extends InMemorySharedPreferencesStore {
  _RejectedWrites() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

class _DelayedWrites extends InMemorySharedPreferencesStore {
  _DelayedWrites() : super.empty();
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}
