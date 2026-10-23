import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/large_local_store.dart';
import 'package:vocaflow/store.dart';
import 'package:vocaflow/sync_replica.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('independent fields merge, deletions persist, clock observes remote',
      () {
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

  test('capture compares nested JSON without losing field distinctions', () {
    final replica = SyncReplica('phone')
      ..seed({
        'word/book/1': {
          'count': 1,
          'tags': ['a', 'b'],
          'nested': {'x': true, 'y': null},
        },
      });
    expect(
        replica.capture({
          'word/book/1': {
            'nested': {'y': null, 'x': true},
            'tags': ['a', 'b'],
            'count': 1,
          },
        }),
        isFalse);
    expect(
        replica.capture({
          'word/book/1': {
            'nested': {'x': true, 'y': null},
            'tags': ['a', 'b'],
            'count': 1.0,
          },
        }),
        isTrue);
    expect(replica.records['word/book/1']!['value']['count'], 1.0);
  });

  test('conflicting queues converge and preserve losing branch', () {
    final a = SyncReplica('a')
      ..seed({
        'session/s': {
          'queue': [1, 2]
        }
      });
    final b = SyncReplica('b')
      ..seed({
        'session/s': {
          'queue': [1, 2]
        }
      });
    a.capture({
      'session/s': {
        'queue': [2]
      }
    }, nowMicros: 100);
    b.capture({
      'session/s': {
        'queue': [1]
      }
    }, nowMicros: 200);
    a.merge(b.toJson());
    b.merge(a.toJson());
    expect(a.values, b.values);
    expect(a.recovery.values.any((r) => r['clock'] == 100), isTrue);
  });

  test('replica restoration preserves records and recovery before merge', () {
    final local = SyncReplica('phone')
      ..seed({
        'word/book/1': {'state': 'fresh'},
        'session/course': {
          'queue': [1, 2]
        },
      });
    local.capture({
      'word/book/1': {'state': 'memorized'},
      'session/course': {
        'queue': [2]
      },
    }, nowMicros: 100);
    final remote = SyncReplica('web')
      ..seed({
        'word/book/1': {'state': 'fresh'},
        'session/course': {
          'queue': [1, 2]
        },
      });
    remote.capture({
      'word/book/1': {'state': 'fresh'},
      'session/course': {
        'queue': [1]
      },
    }, nowMicros: 200);

    final original = SyncReplica.fromJson(local.toJson());
    final restored = SyncReplica.fromJson(local.toJson());
    expect(restored.toJson(), original.toJson());
    original.merge(remote.toJson());
    restored.merge(remote.toJson());
    expect(restored.toJson(), original.toJson());
    restored.acceptView(restored.values);
    expect(restored.capture(restored.values), isFalse);
  });

  test('background merge matches direct merge with retained session history',
      () async {
    final phone = SyncReplica('phone')
      ..seed({
        'word/book/1': {'state': 'fresh'},
        'session/course': {
          'queue': [1, 2]
        },
      });
    phone.capture({
      'word/book/1': {'state': 'memorized'},
      'session/course': {
        'queue': [2]
      },
    }, nowMicros: 100);
    final web = SyncReplica('web')
      ..seed({
        'word/book/1': {'state': 'fresh'},
        'session/course': {
          'queue': [1, 2]
        },
      });
    web.capture({
      'word/book/1': {'state': 'fresh'},
      'session/course': {
        'queue': [1]
      },
    }, nowMicros: 200);
    final direct = SyncReplica.fromJson(phone.toJson())..merge(web.toJson());
    final result = await compute(SyncReplica.mergeEnvelopes, {
      'local': phone.toJson(),
      'remote': [web.toJson()],
    });
    expect(result, direct.toJson());
  });

  test('two phones keep study progress made on different cards', () {
    final initial = {
      'word/book/1': {'state': 'fresh'},
      'word/book/2': {'state': 'fresh'},
    };
    final a = SyncReplica('a')..seed(initial);
    final b = SyncReplica('b')..seed(initial);

    a.capture({
      'word/book/1': {'state': 'memorized'},
      'word/book/2': {'state': 'fresh'},
      'completed/["book",[1]]': true,
    }, nowMicros: 100);
    b.capture({
      'word/book/1': {'state': 'fresh'},
      'word/book/2': {'state': 'review'},
      'completed/["book",[2]]': true,
    }, nowMicros: 200);

    a.merge(b.toJson());
    b.merge(a.toJson());

    expect(a.values['word/book/1'], {'state': 'memorized'});
    expect(a.values['word/book/2'], {'state': 'review'});
    expect(a.values['completed/["book",[1]]'], isTrue);
    expect(a.values['completed/["book",[2]]'], isTrue);
    expect(b.values, a.values);
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
    expect(
        store.dailyStudyStats.values.every((s) => s.studiedCards == 0), isTrue);
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
    expect(
        store.dailyStudyStats.values.fold<int>(0, (n, s) => n + s.studiedCards),
        0);
  });

  test('completed membership survives resize without moving completion',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final book = await store.addBook(
        'test',
        List.generate(
            30, (i) => Word(id: i, term: '$i', reading: '$i', meaning: '$i')));
    await store.completeSessions(book.id, [0]);
    await store.setSessionSize(20);
    expect(store.isSessionCompleted(book.id, 0), isFalse);
    await store.setSessionSize(10);
    expect(store.isSessionCompleted(book.id, 0), isTrue);
  });

  test('latest account checkpoint survives restart without replacing settings',
      () async {
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

  test('account snapshot and recovery checkpoint contain identical books',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.activateAccount('snapshot-account');
    final book = await store.addBook('snapshot book', [
      Word(id: 881001, term: '言葉', reading: 'ことば', meaning: '말'),
    ]);
    await store.mark(book.words.first, StudyState.memorized, bookId: book.id);
    await store.syncV2Snapshot();
    final prefs = await SharedPreferences.getInstance();
    final account = jsonDecode((await readLargeLocalValue(
        prefs, 'accountState.v1.snapshot-account'))!) as Map;
    final checkpoint = jsonDecode((await readLargeLocalValue(
        prefs, 'sync.v2.checkpoint.snapshot-account'))!) as Map;
    expect(checkpoint['state']['books'], account['books']);
    expect((jsonDecode(account['books'] as String) as List), isNotEmpty);
  });

  test('learning snapshots exclude settings but retain word favorites',
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
    expect(records.keys.where((key) => key.startsWith('setting/')), isEmpty);
    expect(records['favorite/default/${word.id}']['value'], isTrue);
  });

  test('legacy setting records cannot overwrite current card settings',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.setHorizontalSwipe(true);
    final stale = {
      'schema': 2,
      'deviceId': 'old-phone',
      'clock': 999999,
      'records': {
        'setting/horizontalSwipe': {
          'clock': 999999,
          'device': 'old-phone',
          'value': false,
        },
      },
      'recovery': <String, dynamic>{},
    };

    await store.applySyncV2([stale]);
    expect(store.horizontalSwipe, isTrue);
  });
}
