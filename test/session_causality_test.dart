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
  test('explicit session tombstone is not defeated by an older modern revision', () {
    final session = revision('s23', {'s23': 1}, 41, 100);
    final deleted = <String, dynamic>{'clock': 200, 'device': 's23', 'value': null};
    for (final order in [[session, deleted], [deleted, session]]) {
      final replica = SyncReplica('reader');
      for (final record in order) { replica.merge(envelope(record)); }
      expect(replica.values['session/book:current'], isNull);
    }
    final restarted = revision('s23', {'s23': 2}, 0, 300);
    final replica = SyncReplica('reader')..merge(envelope(deleted))..merge(envelope(restarted));
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
