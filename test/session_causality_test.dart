import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';
import 'package:vocaflow/sync_replica.dart';

Map<String, dynamic> revision(
        String device, Map<String, int> vector, int count, int clock,
        {bool modern = true}) =>
    {
      'clock': clock,
      'device': device,
      'value': {
        'active': {
          'queueIds': [count + 1],
          'total': 66,
          'memorized': count,
          'updatedAt': '2026-10-20T00:00:00Z',
          if (modern)
            'progress': {
              'schema': 1,
              'id': '$device:$vector',
              'device': device,
              'primary': 's23',
              'vector': vector,
            },
        },
        'words': <String, dynamic>{},
      }
    };
Map<String, dynamic> envelope(Map<String, dynamic> record,
        {Map<String, dynamic> extra = const {}}) =>
    {
      'schema': 2,
      'clock': record['clock'],
      'records': {'session/book:current': record, ...extra},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('explicit session tombstone is not defeated by an older modern revision',
      () {
    final session = revision('s23', {'s23': 1}, 41, 100);
    final deleted = <String, dynamic>{
      'clock': 200,
      'device': 's23',
      'value': null
    };
    for (final order in [
      [session, deleted],
      [deleted, session]
    ]) {
      final replica = SyncReplica('reader');
      for (final record in order) {
        replica.merge(envelope(record));
      }
      expect(replica.values['session/book:current'], isNull);
    }
    final restarted = revision('s23', {'s23': 2}, 0, 300);
    final replica = SyncReplica('reader')
      ..merge(envelope(deleted))
      ..merge(envelope(restarted));
    expect(replica.values['session/book:current']['active']['memorized'], 0);
  });

  test('late legacy PC resume cannot replace verified modern session', () {
    final phone = revision('s23', {'s23': 1}, 41, 100);
    final pc = revision('pc', {}, 38, 999999, modern: false);
    for (final records in [
      [phone, pc],
      [pc, phone]
    ]) {
      final replica = SyncReplica('reader');
      for (final record in records) {
        replica.merge(envelope(record));
      }
      expect(replica.values['session/book:current']['active']['memorized'], 41);
      expect(replica.recovery, isNotEmpty);
    }
  });

  test('observed PC learning is accepted but concurrent primary branch wins',
      () {
    final base = revision('s23', {'s23': 1}, 41, 100);
    final pc = revision('pc', {'s23': 1, 'pc': 1}, 42, 900);
    final phone = revision('s23', {'s23': 2}, 43, 200);
    final continued = revision('pc', {'s23': 2, 'pc': 2}, 44, 1000);
    final replica = SyncReplica('reader')..merge(envelope(base));
    replica.merge(envelope(pc));
    expect(replica.values['session/book:current']['active']['memorized'], 42);
    replica.merge(envelope(phone, extra: {
      'event/phone': {'clock': 200, 'device': 's23', 'value': 1}
    }));
    expect(replica.values['session/book:current']['active']['memorized'], 43);
    replica.merge(envelope(continued, extra: {
      'event/pc': {'clock': 1000, 'device': 'pc', 'value': 1}
    }));
    expect(replica.values['session/book:current']['active']['memorized'], 44);
    expect(replica.values['event/phone'], 1);
    expect(replica.values['event/pc'], 1);
    expect(replica.recovery, isNotEmpty);
    for (final order in [
      [continued, pc, phone, base],
      [phone, base, continued, pc],
      [pc, continued, base, phone]
    ]) {
      final other = SyncReplica('other');
      for (final record in order) {
        other.merge(envelope(record));
      }
      expect(other.values['session/book:current']['active']['memorized'], 44);
    }
  });

  test('same-device delayed snapshots cannot rewind a completed round', () {
    Map<String, dynamic> at(int vector, int completed,
        {String? epoch, bool intentional = false}) {
      final item = revision('s23', {'s23': vector}, completed, vector);
      final active = item['value']['active'] as Map<String, dynamic>;
      active['bookId'] = 'ch02';
      active['roundNumber'] = 1;
      active['roundTotal'] = 366;
      active['roundCompleted'] = completed;
      final progress = active['progress'] as Map<String, dynamic>;
      if (epoch != null) progress['regressionEpoch'] = epoch;
      if (intentional) progress['allowsRegression'] = true;
      return item;
    }

    final advance = at(310, 365);
    final delayed = at(311, 329);
    final delayedAgain = at(319, 316);
    for (final order in [
      [advance, delayed, delayedAgain],
      [delayedAgain, delayed, advance],
    ]) {
      final replica = SyncReplica('reader');
      for (final item in order) {
        replica.merge(envelope(item));
      }
      expect(replica.values['session/book:current']['active']['roundCompleted'],
          365);
    }

    final undone = at(320, 364, epoch: 'undo-1', intentional: true);
    final afterUndo = at(321, 364, epoch: 'undo-1');
    final replica = SyncReplica('reader')
      ..merge(envelope(advance))
      ..merge(envelope(undone))
      ..merge(envelope(afterUndo));
    expect(replica.values['session/book:current']['active']['roundCompleted'],
        364);
  });

  test('decision sequence beats a delayed newer screen snapshot in one run',
      () {
    Map<String, dynamic> at(int clock, int completed, int sequence) {
      final item = revision('s23', {'s23': clock}, completed, clock);
      final active = item['value']['active'] as Map<String, dynamic>;
      active
        ..['bookId'] = 'ch02'
        ..['roundNumber'] = 1
        ..['roundTotal'] = 366
        ..['roundCompleted'] = completed
        ..['runId'] = 's23-ch02-run'
        ..['decisionSequence'] = sequence;
      (active['progress'] as Map<String, dynamic>)['schema'] = 2;
      return item;
    }

    // This exactly mirrors the production failure: a stale view persisted
    // later (larger replica clock) must not re-open card 316 after card 365.
    final at365 = at(365, 365, 365);
    final stale329 = at(400, 329, 329);
    final stale316 = at(401, 316, 316);
    for (final order in [
      [at365, stale329, stale316],
      [stale316, at365, stale329],
    ]) {
      final replica = SyncReplica('reader');
      for (final record in order) {
        replica.merge(envelope(record));
      }
      expect(replica.values['session/book:current']['active']['roundCompleted'],
          365);
    }
  });

  test(
      'batched device merge retains sequential results and every recovery record',
      () {
    final snapshots = <Map<String, dynamic>>[];
    for (var i = 1; i <= 70; i++) {
      final record = revision(i.isEven ? 'pc' : 's23', {'s23': i}, i, i);
      record['value']['active'].addAll({
        'bookId': 'ch02',
        'roundNumber': 1,
        'roundTotal': 366,
        'roundCompleted': i,
      });
      snapshots.add(envelope(record, extra: {
        'event/action-$i': {'clock': i, 'device': 's23', 'value': i},
      }));
    }
    for (final ordered in [snapshots, snapshots.reversed.toList()]) {
      final sequential = SyncReplica('reader');
      for (final snapshot in ordered) {
        sequential.merge(snapshot);
      }
      final batched = SyncReplica.mergeEnvelopes({
        'local': SyncReplica('reader').toJson(),
        'remote': ordered,
      });
      expect(batched, sequential.toJson());
      final repeated = SyncReplica.mergeEnvelopes({
        'local': batched,
        'remote': ordered,
      });
      expect(repeated, batched);
      expect((batched['recovery'] as Map).length, 70);
    }
  });

  test('derived view changes never advance session or change queue', () async {
    final store = await VocaStore.load();
    final book = await store
        .addBook('test', [Word(id: 1, term: 'a', reading: 'a', meaning: 'a')]);
    final active = ActiveStudy(
        queueIds: [1],
        total: 66,
        memorized: 41,
        reviewed: [],
        revealed: false,
        sessionIndexes: [],
        bookId: book.id);
    final key = store.activeStudyKey(active);
    final saved = (await store.saveActiveStudyFor(key, active))!;
    final before = await store.syncV2Snapshot();
    final generation = store.cloudChanges.snapshot.learningStateGeneration;
    final changedView = ActiveStudy.fromJson({
      ...saved.toJson(),
      'total': 300,
      'memorized': 38,
      'queueIds': [999],
      'revealed': true,
      'updatedAt': '2099-01-01T00:00:00Z'
    });
    await store.saveActiveStudyFor(key, changedView,
        progressChanged: false, expectedProgressId: saved.progress['id']);
    final current = store.getActiveStudyFor(key)!;
    expect(current.total, 66);
    expect(current.memorized, 41);
    expect(current.queueIds, [1]);
    expect(current.progress, saved.progress);
    final after = await store.syncV2Snapshot();
    expect(after['records']['session/$key'], before['records']['session/$key']);
    expect(store.cloudChanges.snapshot.learningStateGeneration, generation);
    expect(
        await store.saveActiveStudyFor(key, changedView,
            expectedProgressId: 'obsolete'),
        isNull);
  });

  test('a stale same-round snapshot cannot move study progress backward',
      () async {
    final store = await VocaStore.load();
    final book = await store.addBook('test', [
      Word(id: 1, term: 'a', reading: 'a', meaning: 'a'),
      Word(id: 2, term: 'b', reading: 'b', meaning: 'b'),
    ]);
    final active = ActiveStudy(
      queueIds: [2],
      total: 366,
      memorized: 243,
      reviewed: const [],
      revealed: false,
      bookId: book.id,
      sessionIndexes: const [],
      roundNumber: 1,
      roundTotal: 366,
      roundCompleted: 365,
      startedAt: DateTime.utc(2026, 10, 24, 8),
    );
    final key = store.activeStudyKey(active);
    final saved = (await store.saveActiveStudyFor(key, active))!;
    final stale = ActiveStudy.fromJson({
      ...saved.toJson(),
      'roundCompleted': 329,
      'queueIds': [1, 2],
    });
    expect(
        await store.saveActiveStudyFor(key, stale,
            expectedProgressId: saved.progress['id']),
        isNull);
    expect(store.getActiveStudyFor(key)!.roundCompleted, 365);

    final undo = (await store.saveActiveStudyFor(key, stale,
        expectedProgressId: saved.progress['id'],
        allowProgressRegression: true))!;
    expect(undo.roundCompleted, 329);
    expect(undo.progress['allowsRegression'], isTrue);
    expect(undo.startedAt, saved.startedAt);
  });

  test('saving one studied card preserves every other book after reload',
      () async {
    final store = await VocaStore.load();
    final first = await store.addBook(
        'first', [Word(id: 1, term: '甲', reading: 'こう', meaning: '첫째')]);
    final second = await store.addBook(
        'second', [Word(id: 2, term: '乙', reading: 'おつ', meaning: '둘째')]);
    await store.mark(first.words.first, StudyState.memorized,
        bookId: first.id, decisionId: 'first-decision');
    final restored = await VocaStore.load();
    expect(restored.resolveCard(first.id, 1)!.correctCount, 1);
    expect(restored.resolveCard(second.id, 2)!.meaning, '둘째');
  });

  test('same action ID cannot be restamped through a new view timestamp', () {
    final record = revision('s23', {'s23': 1}, 41, 100);
    final replica = SyncReplica('pc')..merge(envelope(record));
    replica.acceptView(replica.values);
    final value =
        jsonDecode(jsonEncode(replica.values)) as Map<String, dynamic>;
    value['session/book:current']['active']['updatedAt'] = '2099-01-01';
    value['session/book:current']['active']['total'] = 300;
    expect(replica.capture(value, nowMicros: 999999), isFalse);
    expect(replica.records['session/book:current']!['clock'], 100);
  });

  test('modern session cache cannot overwrite independently learned card state',
      () async {
    final store = await VocaStore.load();
    final book = await store
        .addBook('test', [Word(id: 1, term: 'a', reading: 'a', meaning: 'a')]);
    await store.mark(book.words.first, StudyState.memorized, bookId: book.id);
    final snapshot = await store.syncV2Snapshot();
    final clock = (snapshot['clock'] as int) + 1;
    final session = revision('s23', {'s23': 1}, 41, clock);
    session['value']['active']['bookId'] = book.id;
    session['value']['words'] = {
      'word/${book.id}/1': {'state': 'fresh', 'correctCount': 0}
    };
    await store.applySyncV2([envelope(session)]);
    expect(store.resolveCard(book.id, 1)!.state, StudyState.memorized);
    expect(store.resolveCard(book.id, 1)!.correctCount, 1);
  });
}
