import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  test('resume merge keeps newest queue even with lower memorized count',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final book = store.books.first;
    final old = ActiveStudy(
      queueIds: [book.words.last.id],
      total: book.words.length,
      memorized: book.words.length - 1,
      reviewed: const [],
      revealed: false,
      sessionIndexes: const [],
      bookId: book.id,
      updatedAt: DateTime.utc(2026, 10, 1),
    );
    final recent = ActiveStudy(
      queueIds: book.words.map((word) => word.id).toList(),
      total: book.words.length,
      memorized: 0,
      reviewed: const [],
      revealed: true,
      sessionIndexes: const [],
      bookId: book.id,
      updatedAt: DateTime.utc(2026, 10, 2),
    );
    final key = store.activeStudyKey(old);
    for (final snapshots in [
      [old, recent],
      [recent, old],
    ]) {
      await store.applyLearningStateSnapshots(snapshots.map((active) => {
            'activeStudies': {key: active.toJson()},
          }));
      expect(store.activeStudy!.memorized, 0);
      expect(store.activeStudy!.queueIds, recent.queueIds);
      expect(store.activeStudy!.revealed, isTrue);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('active study persists current round progress and held cards', () {
    final active = ActiveStudy(
      queueIds: const [3, 4],
      queueBookIds: const ['book-a', 'book-a'],
      total: 10,
      memorized: 4,
      reviewed: const ['보류'],
      revealed: false,
      sessionIndexes: const [],
      roundNumber: 2,
      roundTotal: 6,
      roundCompleted: 4,
      roundUnknownIds: const [8, 9],
      roundUnknownBookIds: const ['book-a', 'book-b'],
    );

    final restored = ActiveStudy.fromJson(active.toJson());

    expect(restored.roundNumber, 2);
    expect(restored.roundTotal, 6);
    expect(restored.roundCompleted, 4);
    expect(restored.roundUnknownIds, [8, 9]);
    expect(restored.roundUnknownBookIds, ['book-a', 'book-b']);
  });

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

  test('book library cache is isolated per signed-in account', () async {
    final store = await VocaStore.load();
    await store.activateAccount('account-a');
    await store.addBook('Account A', []);

    await store.activateAccount('account-b');
    expect(store.books.any((book) => book.name == 'Account A'), isFalse);
    await store.addBook('Account B', []);

    await store.activateAccount('account-a');
    expect(store.books.any((book) => book.name == 'Account A'), isTrue);
    expect(store.books.any((book) => book.name == 'Account B'), isFalse);
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

  test('study attempts and completed sessions update daily stats and log',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final word = store.books.first.words.first;

    await store.mark(
      word,
      StudyState.review,
      bookId: store.books.first.id,
      sessionIndexes: const [0],
    );

    final today = store.recentDayKeys(count: 1).single;
    expect(store.dailyStudyStats[today]?.studiedCards, 1);
    expect(store.dailyStudyStats[today]?.wrongCount, 1);
    expect(store.dailyStudyStatus(today), DailyStudyStatus.low);
    expect(store.studyEventLog, hasLength(1));
    expect(store.studyEventLog.single.wordId, word.id);
    expect(store.studyEventLog.single.sessionIndexes, [0]);
    expect(store.studyEventLog.single.previousState, StudyState.fresh);
    expect(store.studyEventLog.single.previousCorrectCount, 0);
    expect(store.studyEventLog.single.previousWrongCount, 0);
    expect(store.studyEventLog.single.previousLastStudiedAt, isNull);
    expect(store.studyEventLog.single.previousLastWrongAt, isNull);

    await store.completeSessions(store.books.first.id, const [0]);
    expect(store.dailyStudyStats[today]?.completedSessions, 1);
    expect(store.dailyStudyStatus(today), DailyStudyStatus.completed);

    await store.resetProgress();
    expect(store.dailyStudyStats, isEmpty);
    expect(store.studyEventLog, isEmpty);
  });

  test('backup restore prunes cached study event logs', () async {
    final store = await VocaStore.load();
    // Keep the generated records inside the production 90-day retention
    // window regardless of when the test suite is run.
    final now = DateTime.now().toUtc();
    final events = List.generate(3010, (index) {
      final timestamp = now.subtract(Duration(minutes: index));
      return {
        'id': 'event-$index',
        'date': timestamp.toIso8601String().substring(0, 10),
        'timestamp': timestamp.toIso8601String(),
        'bookId': 'default',
        'wordId': index,
        'sessionIndexes': [0],
        'decision': StudyState.review.name,
      };
    });

    await store.replaceWithBackupJson({
      ...store.toBackupJson(),
      'studyEventLog': events,
    });

    expect(store.studyEventLog, hasLength(VocaStore.studyEventLogMaxItems));
    expect(store.toBackupJson()['studyEventLog'], hasLength(3000));

    await store.resetProgress();
    expect(store.studyEventLog, isEmpty);
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

  test('study card display settings persist', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setReadingAboveTerm(true);
    await store.setShowExamples(false);
    await store.setFlipCard(true);
    await store.setAutoPlayPronunciation(false);

    final reloaded = await VocaStore.load();
    expect(reloaded.readingAboveTerm, isTrue);
    expect(reloaded.showExamples, isFalse);
    expect(reloaded.flipCard, isTrue);
    expect(reloaded.autoPlayPronunciation, isFalse);
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
      undoHistory: [
        StudyDecision(
          wordId: words.first.id,
          previousState: StudyState.fresh,
          decision: StudyState.memorized,
        ),
      ],
    ));

    final reloaded = await VocaStore.load();
    final active = reloaded.activeStudy!;
    expect(active.queueIds, words.skip(1).map((word) => word.id).toList());
    expect(active.memorized, 1);
    expect(active.revealed, isTrue);
    expect(active.lastState, StudyState.memorized);
    expect(active.undoHistory, hasLength(1));
    expect(active.undoHistory.single.wordId, words.first.id);
    expect(reloaded.resolveActiveWords(active).first.term, 'resilience');
  });

  test('learning state snapshot merges study status without changing card text',
      () async {
    SharedPreferences.setMockInitialValues({});
    final first = await VocaStore.load();
    final firstWord = first.books.first.words.first;
    final originalTerm = firstWord.term;
    final originalMeaning = firstWord.meaning;
    await first.mark(firstWord, StudyState.memorized,
        bookId: first.books.first.id, sessionIndexes: const [0]);
    final snapshot = first.toLearningStateJson();

    SharedPreferences.setMockInitialValues({});
    final second = await VocaStore.load();
    final secondWord = second.books.first.words.first;
    await second.applyLearningStateSnapshots([snapshot]);

    expect(secondWord.term, originalTerm);
    expect(secondWord.meaning, originalMeaning);
    expect(secondWord.state, StudyState.memorized);
    expect(secondWord.correctCount, 1);
  });
  test('Japanese font setting persists', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setJapaneseFont('sourceHanSerifJP');

    final reloaded = await VocaStore.load();
    expect(reloaded.japaneseFont, 'sourceHanSerifJP');
  });

  test('study card font sizes persist', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setCardFontSizes(
      term: 40,
      reading: 18,
      meaning: 26,
      example: 19,
      exampleMeaning: 17,
    );

    final reloaded = await VocaStore.load();
    expect(reloaded.termFontSize, 40);
    expect(reloaded.readingFontSize, 18);
    expect(reloaded.meaningFontSize, 26);
    expect(reloaded.exampleFontSize, 19);
    expect(reloaded.exampleMeaningFontSize, 17);
  });

  test('meaning style persists and is included in backup data', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setMeaningStyle(fontWeight: 600, opacity: .55);

    final reloaded = await VocaStore.load();
    expect(reloaded.meaningFontWeight, 600);
    expect(reloaded.meaningOpacity, .55);
    expect(reloaded.toBackupJson()['cardMeaningStyle'], {
      'fontWeight': 600,
      'opacity': .55,
    });
  });

  test('ChatGPT conversation URL is backed up and restored', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    expect(
      await store.setChatGptConversationUrl(
        'https://chatgpt.com/c/private-id?temporary=true',
      ),
      isTrue,
    );
    expect(store.chatGptConversationUrl, 'https://chatgpt.com/c/private-id');
    final backup = store.toBackupJson();
    expect(
      backup['chatGptConversationUrl'],
      'https://chatgpt.com/c/private-id',
    );
    expect(
      await store.setChatGptConversationUrl('https://example.com/c/id'),
      isFalse,
    );

    final reloaded = await VocaStore.load();
    expect(reloaded.chatGptConversationUrl, 'https://chatgpt.com/c/private-id');

    SharedPreferences.setMockInitialValues({});
    final restored = await VocaStore.load();
    await restored.replaceWithBackupJson(backup);
    expect(
      restored.chatGptConversationUrl,
      'https://chatgpt.com/c/private-id',
    );
  });

  test('in-app dictionary setting persists and ignores older cloud values',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setOpenDictionaryInApp(true);
    final localUpdatedAt = store.openDictionaryInAppUpdatedAt!;
    final backup = store.toBackupJson();

    expect(store.openDictionaryInApp, isTrue);
    expect(backup['openDictionaryInAppSetting'], {
      'value': true,
      'updatedAt': localUpdatedAt.toIso8601String(),
    });

    final reloaded = await VocaStore.load();
    expect(reloaded.openDictionaryInApp, isTrue);

    await reloaded.applyOpenDictionaryInAppSettingFromCloud({
      'value': false,
      'updatedAt':
          localUpdatedAt.subtract(const Duration(minutes: 1)).toIso8601String(),
    });
    expect(reloaded.openDictionaryInApp, isTrue);

    await reloaded.applyOpenDictionaryInAppSettingFromCloud({
      'value': false,
      'updatedAt':
          localUpdatedAt.add(const Duration(minutes: 1)).toIso8601String(),
    });
    expect(reloaded.openDictionaryInApp, isFalse);
  });

  test('mixed-book active study preserves word ownership and selections',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.addBook('A', [
      Word(id: 77, term: 'from A', meaning: '', reading: ''),
    ]);
    await store.addBook('B', [
      Word(id: 77, term: 'from B', meaning: '', reading: ''),
    ]);
    final first = store.books[store.books.length - 2];
    final second = store.books.last;
    await store.saveActiveStudy(ActiveStudy(
      queueIds: const [77, 77],
      queueBookIds: [first.id, second.id],
      total: 2,
      memorized: 0,
      reviewed: const [],
      revealed: false,
      sessionIndexes: const [],
      sessionSelections: {
        first.id: const [0],
        second.id: const [0],
      },
    ));

    final reloaded = await VocaStore.load();
    final active = reloaded.activeStudy!;
    expect(reloaded.resolveActiveWords(active).map((word) => word.term),
        ['from A', 'from B']);
    expect(active.sessionSelections, {
      first.id: [0],
      second.id: [0],
    });
  });

  test('completed sessions ignore stale active study resumes', () async {
    final store = await VocaStore.load();
    final book = store.books.first;
    await store.saveActiveStudy(ActiveStudy(
      queueIds: book.words.skip(3).map((word) => word.id).toList(),
      queueBookIds: book.words.skip(3).map((_) => book.id).toList(),
      total: book.words.length,
      memorized: 3,
      reviewed: const [],
      revealed: false,
      bookId: book.id,
      sessionIndexes: const [0],
    ));
    final key = store.activeStudyKeyFor(
      bookId: book.id,
      sessionIndexes: const [0],
      sessionSelections: const {},
    );

    await store.completeSessions(book.id, const [0]);

    expect(store.getActiveStudyFor(key), isNull);
    expect(store.activeStudy, isNull);
  });

  test('cloud restore ignores active study for completed sessions', () async {
    final store = await VocaStore.load();
    final book = store.books.first;
    final active = ActiveStudy(
      queueIds: book.words.skip(3).map((word) => word.id).toList(),
      queueBookIds: book.words.skip(3).map((_) => book.id).toList(),
      total: book.words.length,
      memorized: 3,
      reviewed: const [],
      revealed: false,
      bookId: book.id,
      sessionIndexes: const [0],
    );

    final restored = await store.restoreActiveStudyFromBackupJson({
      'completed': ['${book.id}:0'],
      'activeStudy': active.toJson(),
      'activeStudies': {
        store.activeStudyKeyFor(
          bookId: book.id,
          sessionIndexes: const [0],
          sessionSelections: const {},
        ): active.toJson(),
      },
    });

    expect(restored, isNull);
    expect(store.activeStudy, isNull);
  });

  test('finds active study for a specific session', () async {
    final store = await VocaStore.load();
    final book = store.books.first;
    final active = ActiveStudy(
      queueIds: book.words.take(4).map((word) => word.id).toList(),
      queueBookIds: book.words.take(4).map((_) => book.id).toList(),
      total: 10,
      memorized: 6,
      reviewed: const [],
      revealed: false,
      bookId: book.id,
      sessionIndexes: const [0],
    );

    await store.saveActiveStudy(active, markCloudChange: false);

    expect(store.getActiveStudyForSession(book.id, 0)?.memorized, 6);
    expect(store.getActiveStudyForSession(book.id, 1), isNull);
  });

  test('repairs clearly swapped Japanese reading and Korean meaning once',
      () async {
    final book = WordBook(
      id: 'japanese',
      name: 'Japanese',
      words: [Word(id: 88, term: '遺跡', reading: '유적', meaning: 'いせき')],
    );
    SharedPreferences.setMockInitialValues({
      'books': jsonEncode([book.toJson()]),
    });

    final store = await VocaStore.load();
    final repaired = store.books.single.words.single;

    expect(repaired.reading, 'いせき');
    expect(repaired.meaning, '유적');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('readingMeaningMigrationV1'), isTrue);
    expect(store.cloudChanges.snapshot.wordIdsByBook['japanese'], {88});
  });

  test('last main tab persists and clamps invalid values', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setLastMainTab(2);
    expect((await VocaStore.load()).lastMainTab, 2);

    await store.setLastMainTab(99);
    expect((await VocaStore.load()).lastMainTab, 3);
  });

  test('book restore payload is scoped to the selected book', () async {
    final store = await VocaStore.load();
    final first = await store.addBook('first', [
      Word(id: 11, term: 'one', reading: 'one', meaning: 'one'),
    ]);
    final second = await store.addBook('second', [
      Word(id: 22, term: 'two', reading: 'two', meaning: 'two'),
    ]);
    await store.completeSessions(first.id, const [0]);
    await store.completeSessions(second.id, const [0]);

    final payload = store.createBookRestorePayload(first.id);
    final learning = Map<String, dynamic>.from(payload['learning'] as Map);
    expect((payload['book'] as Map)['id'], first.id);
    expect(learning['completed'], everyElement(startsWith('${first.id}:')));
    expect((learning['wordStates'] as Map).keys, [first.id]);

    await store.deleteBook(first.id);
    await store.restoreBookFromPayload(payload);
    expect(store.books.any((book) => book.id == first.id), isTrue);
    expect(store.books.any((book) => book.id == second.id), isTrue);
    expect(store.isSessionCompleted(second.id, 0), isTrue);
  });
}
