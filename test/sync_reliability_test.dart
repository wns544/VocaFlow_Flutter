import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/card_sync.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  test('pausing or flipping an old session never makes its progress newer',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final book = store.books.first;
    final active = ActiveStudy(
        queueIds: book.words.map((w) => w.id).toList(),
        total: book.words.length,
        memorized: 0,
        reviewed: [],
        revealed: false,
        bookId: book.id,
        sessionIndexes: [0]);
    final key = store.activeStudyKey(active);
    final saved = (await store.saveActiveStudyFor(key, active))!;
    final before = await store.syncV2Snapshot();
    final generation = store.cloudChanges.snapshot.learningStateGeneration;
    final paused = ActiveStudy.fromJson({...saved.toJson(), 'revealed': true});
    final afterSave = (await store.saveActiveStudyFor(key, paused))!;
    final after = await store.syncV2Snapshot();
    expect(afterSave.updatedAt, saved.updatedAt);
    expect(store.cloudChanges.snapshot.learningStateGeneration, generation);
    expect(after['records']['session/$key']['clock'],
        before['records']['session/$key']['clock']);
    expect(
        after['records']['session/$key']['value']['active']['revealed'], false);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'first card download hydrates existing learning without authoring fresh states',
      () async {
    final store = await VocaStore.load();
    const wordKey = 'word/server-book/42';
    final server = {
      'schema': 2,
      'deviceId': 'server',
      'clock': 123,
      'records': {
        wordKey: {
          'clock': 123,
          'device': 'phone',
          'value': {
            'state': 'memorized',
            'correctCount': 7,
            'wrongCount': 2,
            'lastStudiedAt': '2026-10-19T12:00:00.000',
            'lastWrongAt': null
          }
        }
      },
      'recovery': <String, dynamic>{}
    };
    await store.applySyncV2([server]);
    await store.mergeCardBooks([
      const CardBookSnapshot(book: {
        'id': 'server-book',
        'name': 'server',
        'wordOrder': [42]
      }, cards: [
        {'id': 42, 'term': 'つくづく', 'reading': 'つくづく', 'meaning': '절실히'}
      ], changeNumber: 0)
    ]);
    final word = store.resolveCard('server-book', 42)!;
    expect(word.state, StudyState.memorized);
    expect(word.correctCount, 7);
    final result = await store.syncV2Snapshot();
    expect(result['records'][wordKey], (server['records'] as Map)[wordKey]);
  });

  Future<(VocaStore, WordBook)> seed() async {
    final store = await VocaStore.load();
    final book = await store.addBook('검증', [
      Word(id: 42, term: 'つくづく', reading: 'つくづく', meaning: '절실히'),
      Word(id: 43, term: '次', reading: 'つぎ', meaning: '다음'),
    ]);
    for (final op in store.cardChanges.pending) {
      await store.cardChanges.acknowledge(op);
    }
    return (store, book);
  }

  CardBookSnapshot remote(WordBook book, {String meaning = '서버의 옛 뜻'}) =>
      CardBookSnapshot(
        book: {
          'id': book.id,
          'name': book.name,
          'wordOrder': [42, 43]
        },
        cards: [
          for (final word in book.words)
            {...word.toJson(), if (word.id == 42) 'meaning': meaning}
        ],
        changeNumber: 1,
      );

  test('full and incremental pulls preserve pending edits and live references',
      () async {
    final (store, book) = await seed();
    final visible = book.words.first;
    final change = await store.updateWord(visible.copyWith(meaning: '뼈저리게'),
        bookId: book.id);
    expect(change!.fields, {'meaning': '뼈저리게'});
    await store.mergeCardBooks([remote(book)]);
    expect(identical(store.resolveCard(book.id, 42), visible), isTrue);
    expect(visible.meaning, '뼈저리게');
    await store.applyCardBookChanges(book.id, [
      const CardBookChange(
          number: 2,
          wordId: 42,
          fields: {'meaning': '다른 기기', 'example': '새 예문'},
          operationId: 'remote')
    ]);
    expect(visible.meaning, '뼈저리게');
    expect(visible.example, '새 예문');
    await store.mark(visible, StudyState.memorized,
        bookId: book.id, decisionId: 'decision-1');
    expect(store.resolveCard(book.id, 42)!.correctCount, 1);
    expect(store.cardChanges.pending.single.id, change.id);
  });

  test(
      'older receipt cannot erase a newer edit and recovery overlay survives restart',
      () async {
    final (store, book) = await seed();
    final first = await store.updateWord(
        book.words.first.copyWith(meaning: '첫 수정'),
        bookId: book.id);
    await store.updateWord(book.words.first.copyWith(meaning: '마지막 수정'),
        bookId: book.id);
    await store.cardChanges.acknowledge(first!);
    await store.mergeCardBooks([remote(book)]);
    final restarted = await VocaStore.load();
    expect(restarted.resolveCard(book.id, 42)!.meaning, '마지막 수정');
    expect(restarted.cardChanges.pending.single.fields['meaning'], '마지막 수정');
  });

  test('durable outbox repairs a crash before the card cache was written',
      () async {
    final (store, book) = await seed();
    await store.cardChanges.enqueue(
        bookId: book.id,
        wordId: 42,
        before: {'meaning': '절실히'},
        after: {'meaning': '뼈저리게'});
    final restarted = await VocaStore.load();
    expect(restarted.resolveCard(book.id, 42)!.meaning, '뼈저리게');
  });

  test(
      'detached same-id card cannot lose a learning decision or edit another book',
      () async {
    final (store, book) = await seed();
    final other = await store.addBook(
        '다른 책', [Word(id: 42, term: '同', reading: 'どう', meaning: '같다')]);
    final detached = book.words.first.copyWith(meaning: '오래된 화면 객체');
    await store.mark(detached, StudyState.memorized,
        bookId: book.id, decisionId: 'one');
    await store.mark(detached, StudyState.memorized,
        bookId: book.id, decisionId: 'one');
    expect(store.resolveCard(book.id, 42)!.correctCount, 1);
    expect(store.resolveCard(other.id, 42)!.correctCount, 0);
    expect(store.studyEventLog.where((event) => event.bookId == book.id),
        hasLength(1));
  });

  test(
      'interrupted decision rolls back partial writes and replays once with its session',
      () async {
    final (store, book) = await seed();
    final prefs = await SharedPreferences.getInstance();
    final beforeWord = book.words.first.toJson();
    final keys = [
      'dailyStudyStats',
      'studyEventLog',
      'studyDays',
      'activeStudies',
      'activeStudy',
      'activeStudyTombstones',
      'sync.v2.events',
      'localDecisionReceipts.local'
    ];
    final before = {for (final key in keys) key: prefs.get(key)};
    final active = ActiveStudy(
        queueIds: [43],
        queueBookIds: [book.id],
        total: 2,
        memorized: 1,
        reviewed: [],
        revealed: false,
        sessionIndexes: [0],
        bookId: book.id);
    await store.mark(book.words.first, StudyState.memorized,
        bookId: book.id, decisionId: 'interrupted');
    await prefs.setString(
        'learning.localDecision.local',
        jsonEncode({
          'bookId': book.id,
          'word': beforeWord,
          'state': 'memorized',
          'id': 'interrupted',
          'at': DateTime.now().toIso8601String(),
          'sessions': [0],
          'active': active.toJson(),
          'before': before
        }));
    final recovered = await VocaStore.load();
    expect(recovered.resolveCard(book.id, 42)!.correctCount, 1);
    expect(
        recovered.getActiveStudyFor(recovered.activeStudyKey(active))!.queueIds,
        [43]);
    expect(prefs.getString('learning.localDecision.local'), isNull);
    final again = await VocaStore.load();
    expect(again.resolveCard(book.id, 42)!.correctCount, 1);
    expect(again.studyEventLog.where((event) => event.bookId == book.id),
        hasLength(1));
  });
}
