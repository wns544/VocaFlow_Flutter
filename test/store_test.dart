import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  test('study card display settings persist', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();

    await store.setReadingAboveTerm(true);
    await store.setShowExamples(false);
    await store.setFlipCard(true);

    final reloaded = await VocaStore.load();
    expect(reloaded.readingAboveTerm, isTrue);
    expect(reloaded.showExamples, isFalse);
    expect(reloaded.flipCard, isTrue);
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
    expect((await VocaStore.load()).lastMainTab, 2);
  });
}
