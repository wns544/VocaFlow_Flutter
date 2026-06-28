// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vocaflow/main.dart';
import 'package:vocaflow/kanji_lookup.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  setUp(() => shuffleNewStudyQueues = false);

  test('study speech selects a language from the word text', () {
    expect(studySpeechLanguage('遺跡'), 'ja-JP');
    expect(studySpeechLanguage('안녕하세요'), 'ko-KR');
    expect(studySpeechLanguage('resilience'), 'en-US');
  });

  test('review cards return within the next three to ten cards', () {
    final indexes = List.generate(
      100,
      (seed) => reviewReinsertIndex(49, random: Random(seed)),
    );
    expect(indexes.every((index) => index >= 3 && index <= 10), isTrue);
    expect(indexes, isNot(contains(49)));
    expect(reviewReinsertIndex(2, random: Random(1)), 2);
    expect(reviewReinsertIndex(0, random: Random(1)), 0);
  });
  tearDown(() => shuffleNewStudyQueues = true);

  test('new study queues are shuffled without losing words', () {
    final original = List.generate(30, (index) => index);
    final shuffled = shuffledStudyQueue(original, random: Random(42));

    expect(shuffled.toSet(), original.toSet());
    expect(shuffled, isNot(orderedEquals(original)));
  });

  testWidgets('home screen loads', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    expect(find.text('오늘도 단어 정복 💪'), findsNothing);
    expect(find.text('VOCAFLOW'), findsOneWidget);
    expect(find.text('즐겨찾기 단어장'), findsOneWidget);
    expect(find.textContaining('즐겨찾기한 단어장이 없습니다.'), findsOneWidget);
  });

  testWidgets('local UI does not wait for Firebase initialization',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final firebase = Completer<bool>();

    await tester
        .pumpWidget(VocaFlowApp(firebaseInitialization: firebase.future));
    await tester.pumpAndSettle();

    expect(find.text('VOCAFLOW'), findsOneWidget);
    expect(firebase.isCompleted, isFalse);
    firebase.complete(false);
    await tester.pump();
  });

  testWidgets('cold start restores the last main tab',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'lastMainTab': 2});

    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
            .currentIndex,
        2);
  });

  testWidgets('creates a word book from the add dialog',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 단어장 만들기'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('text-input-dialog')), '여행 영어');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('여행 영어'), findsOneWidget);
  });

  testWidgets('study card flips and follows an upward swipe',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('학습하기'));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('study-card'));
    expect(find.byKey(const ValueKey('next-study-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-word')), findsWidgets);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('덧없는, 순간적인'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('word-meaning')), '수정된 뜻');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('수정된 뜻'), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, -50));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    final background = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('study-card-background')));
    final surface = tester
        .widget<Transform>(find.byKey(const ValueKey('study-card-surface')));
    expect((background.decoration as BoxDecoration).color, isNot(Colors.white));
    expect(surface.alignment, Alignment.center);

    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('resilience'), findsOneWidget);
  });

  testWidgets('study card follows a diagonal touch with limited rotation',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('학습하기'));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('study-card'));
    final gesture = await tester
        .startGesture(tester.getCenter(card) + const Offset(70, -80));
    await gesture.moveBy(const Offset(25, -30));
    await gesture.moveBy(const Offset(25, -30));
    await tester.pump();

    final surface = tester
        .widget<Transform>(find.byKey(const ValueKey('study-card-surface')));
    final matrix = surface.transform;
    expect(matrix.storage[12], greaterThan(10));
    expect(matrix.storage[13], lessThan(-10));
    expect(matrix.storage[1].abs(), greaterThan(0.001));
    expect(matrix.storage[1].abs(), lessThan(0.09));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('warm resume keeps the exact study card and revealed face',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(resumeSnapshotChannel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(resumeSnapshotChannel, null));
    final store = await VocaStore.load();
    final word =
        Word(id: 9150, term: 'resume', reading: 'reading', meaning: 'meaning');
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: [word]),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-card')));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('resume'), findsOneWidget);
    expect(find.text('meaning'), findsOneWidget);
    expect(
        calls.any((call) =>
            call.method == 'capture' && call.arguments['target'] == 'study'),
        isTrue);
  });

  testWidgets('study card follows the pointer beyond the old drag clamp',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final words = [
      Word(id: 9201, term: 'first', reading: '', meaning: 'one'),
      Word(id: 9202, term: 'second', reading: '', meaning: 'two'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: words),
    ));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('study-card'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -160));
    await gesture.moveBy(const Offset(0, -160));
    await tester.pump();

    final surface = tester
        .widget<Transform>(find.byKey(const ValueKey('study-card-surface')));
    expect(surface.transform.storage[13], lessThan(-300));
    await gesture.cancel();
    await tester.pumpAndSettle();
    final reset = tester
        .widget<Transform>(find.byKey(const ValueKey('study-card-surface')));
    expect(reset.transform.storage[12], closeTo(0, .01));
    expect(reset.transform.storage[13], closeTo(0, .01));
  });

  testWidgets('the waiting card stays fixed while it becomes the front card',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final words = [
      Word(id: 9301, term: 'front', reading: '', meaning: 'one'),
      Word(id: 9302, term: 'waiting', reading: '', meaning: 'two'),
      Word(id: 9303, term: 'third', reading: '', meaning: 'three'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: words),
    ));
    await tester.pumpAndSettle();

    final waiting = find.byKey(const ValueKey('next-study-card'));
    final waitingRect = tester.getRect(waiting);
    final card = find.byKey(const ValueKey('study-card'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.getRect(waiting), waitingRect);

    await tester.pumpAndSettle();
    expect(find.text('waiting'), findsOneWidget);
    final promoted = tester
        .widget<Transform>(find.byKey(const ValueKey('study-card-surface')));
    expect(tester.getRect(find.byKey(const ValueKey('study-card-surface'))),
        waitingRect);
    expect(promoted.transform.storage[12], closeTo(0, .01));
    expect(promoted.transform.storage[13], closeTo(0, .01));
  });

  testWidgets('the next card does not wait for decision persistence',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final write = Completer<void>();
    final words = [
      Word(id: 9401, term: 'front', reading: '', meaning: 'one'),
      Word(id: 9402, term: 'next', reading: '', meaning: 'two'),
      Word(id: 9403, term: 'third', reading: '', meaning: 'three'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(
        store: store,
        words: words,
        decisionWriter: (_, __) => write.future,
      ),
    ));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('study-card'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final surface = find.byKey(const ValueKey('study-card-surface'));
    expect(find.descendant(of: surface, matching: find.text('next')),
        findsOneWidget);
    expect(write.isCompleted, isFalse);

    write.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('starts multiple selected sessions from the study tab',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final defaultBook = store.books.first..isFavorite = true;
    await store.updateBook(defaultBook);
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    final controls = find.byKey(const ValueKey('home-study-controls'));
    final favoritesList = find.byKey(const ValueKey('favorite-books-list'));
    final normalControlsHeight = tester.getSize(controls).height;
    final normalListTop = tester.getTopLeft(favoritesList).dy;
    await tester.tap(find.byKey(const ValueKey('multi-session-study')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final middleControlsHeight = tester.getSize(controls).height;
    expect(middleControlsHeight, lessThan(normalControlsHeight));
    await tester.pumpAndSettle();
    expect(
        tester.getSize(controls).height, lessThan(normalControlsHeight - 70));
    expect(tester.getTopLeft(favoritesList).dy, lessThan(normalListTop - 70));
    expect(find.byType(BottomSheet), findsNothing);
    final firstSession =
        find.byKey(const ValueKey('favorite-session-checkbox-default-0'));
    final secondSession =
        find.byKey(const ValueKey('favorite-session-checkbox-default-1'));
    expect(firstSession, findsNothing);
    expect(secondSession, findsNothing);
    await tester.tap(find.byKey(const ValueKey('favorite-sessions-default')));
    await tester.pumpAndSettle();
    expect(firstSession, findsOneWidget);
    expect(secondSession, findsOneWidget);

    await tester.tap(firstSession);
    await tester.pumpAndSettle();
    await tester.ensureVisible(secondSession);
    await tester.pumpAndSettle();
    await tester.tap(secondSession);
    await tester.pumpAndSettle();
    expect(find.textContaining('2개 세션'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-multi-session-study')));
    await tester.pumpAndSettle();

    expect(find.textContaining('개 남음'), findsOneWidget);
    expect(find.textContaining('단어 1~10 + 단어 11~'), findsOneWidget);
  });

  testWidgets('leaving an active study saves progress immediately',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('학습하기'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('학습을 나갈까요?'), findsNothing);
    expect(find.byKey(const ValueKey('study-card')), findsNothing);
    expect((await VocaStore.load()).activeStudy, isNotNull);

    await tester.tap(find.text('이어서 학습'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('학습을 나갈까요?'), findsNothing);
    expect(find.byKey(const ValueKey('study-card')), findsNothing);
    expect((await VocaStore.load()).activeStudy, isNotNull);
  });

  testWidgets('selects sessions across multiple favorite word books',
      (WidgetTester tester) async {
    final first = WordBook(
      id: 'favorite-a',
      name: 'Favorite A',
      isFavorite: true,
      words: [Word(id: 9001, term: 'alpha', reading: '', meaning: 'A')],
    );
    final second = WordBook(
      id: 'favorite-b',
      name: 'Favorite B',
      isFavorite: true,
      words: [Word(id: 9002, term: 'beta', reading: '', meaning: 'B')],
    );
    SharedPreferences.setMockInitialValues({
      'books': jsonEncode([first.toJson(), second.toJson()]),
      'quickBook': first.id,
    });

    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('multi-session-study')));
    await tester.pumpAndSettle();

    final firstSession =
        find.byKey(ValueKey('favorite-session-checkbox-${first.id}-0'));
    final secondSession =
        find.byKey(ValueKey('favorite-session-checkbox-${second.id}-0'));
    expect(firstSession, findsNothing);
    expect(secondSession, findsNothing);
    await tester.tap(find.byKey(ValueKey('favorite-sessions-${first.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(firstSession);
    await tester.pumpAndSettle();
    await tester.tap(firstSession);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('favorite-sessions-${second.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(secondSession);
    await tester.pumpAndSettle();
    await tester.tap(secondSession);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('start-multi-session-study')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('study-card')), findsOneWidget);
    final active = (await VocaStore.load()).activeStudy!;
    expect(active.sessionSelections.keys, containsAll([first.id, second.id]));
    expect(active.queueBookIds, hasLength(2));
  });

  testWidgets('completes every selected session across word books',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.addBook('A', [
      Word(id: 9101, term: 'alpha', reading: '', meaning: 'A'),
    ]);
    await store.addBook('B', [
      Word(id: 9102, term: 'beta', reading: '', meaning: 'B'),
    ]);
    final first = store.books[store.books.length - 2];
    final second = store.books.last;
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(
        store: store,
        words: [first.words.single, second.words.single],
        sessionSelections: {
          first.id: const [0],
          second.id: const [0],
        },
      ),
    ));
    await tester.pumpAndSettle();

    for (var index = 0; index < 2; index++) {
      await tester.drag(
          find.byKey(const ValueKey('study-card')), const Offset(0, -240));
      await tester.pumpAndSettle();
    }

    expect(store.isSessionCompleted(first.id, 0), isTrue);
    expect(store.isSessionCompleted(second.id, 0), isTrue);
  });

  testWidgets('card ink effects are clipped to the rounded card shape',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Card).first);
    expect(Theme.of(context).cardTheme.clipBehavior, Clip.antiAlias);
  });

  testWidgets('favorite book appears on the study tab',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-default')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.star), findsOneWidget);

    await tester.tap(find.text('학습'));
    await tester.pumpAndSettle();

    expect(find.text('즐겨찾기 단어장'), findsOneWidget);
    expect(find.textContaining('즐겨찾기한 단어장이 없습니다.'), findsNothing);
    expect(find.text('기본 단어장'), findsWidgets);

    final favoriteHeader = find.ancestor(
      of: find.byKey(const ValueKey('favorite-sessions-default')),
      matching: find.byType(ListTile),
    );
    await tester.tap(favoriteHeader);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorite-default-session-0')),
        findsOneWidget);
  });

  testWidgets('completed favorite session ignores stale saved resume',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'completed': ['default:0'],
    });
    final store = await VocaStore.load();
    final book = store.books.first..isFavorite = true;
    await store.updateBook(book);
    final firstSession = book.sessions(store.sessionSize).first;
    await store.saveActiveStudy(ActiveStudy(
      queueIds: firstSession.words.skip(6).map((word) => word.id).toList(),
      queueBookIds: firstSession.words.skip(6).map((_) => book.id).toList(),
      total: firstSession.words.length,
      memorized: 6,
      reviewed: const [],
      revealed: false,
      bookId: book.id,
      sessionIndexes: const [0],
    ));

    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-sessions-default')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-default-session-0')));
    await tester.pumpAndSettle();

    expect(find.textContaining('4개 남음'), findsNothing);
    expect(find.textContaining('${firstSession.words.length}개 남음'),
        findsOneWidget);
  });

  testWidgets('horizontal reversed swipe uses the opposite decision color',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'horizontalSwipe': true,
      'reverseSwipe': true,
    });
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('학습하기'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.keyboard_arrow_left), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_right), findsOneWidget);
    expect(find.text('알아요'), findsNothing);
    expect(find.text('모르겠어요'), findsNothing);

    final card = find.byKey(const ValueKey('study-card'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();

    final background = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('study-card-background')));
    expect((background.decoration as BoxDecoration).color,
        const Color(0xFFFFE8E6));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('resilience'), findsOneWidget);
  });

  testWidgets('vertical mode accepts a right swipe as memorized',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final word = Word(term: 'right-swipe', reading: '', meaning: 'known');
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: [word]),
    ));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('study-card'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(word.state, StudyState.memorized);
  });

  testWidgets('completed sessions use a light gray background',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'sessionSize': 5,
      'completed': ['default:0'],
    });
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('기본 단어장'));
    await tester.pumpAndSettle();

    final completedRow = find.ancestor(
      of: find.byKey(const ValueKey('book-default-session-0')),
      matching: find.byType(Material),
    );
    expect(tester.widget<Material>(completedRow.first).color,
        const Color(0xFFEDEDED));

    final bookCard = find.byKey(const ValueKey('book-card-default'));
    expect(tester.widget<Card>(bookCard).color, Colors.white);

    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
        'completed', ['default:0', 'default:1', 'default:2', 'default:3']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    final completedBookCard = find.byKey(const ValueKey('book-card-default'));
    expect(
        tester.widget<Card>(completedBookCard).color, const Color(0xFFEDEDED));
  });

  testWidgets('kanji controls preserve exact term centering',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final word = Word(term: '漢字', reading: 'かんじ', meaning: '한자');
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: [word]),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('copy-han-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-han-1')), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    final termCenter =
        tester.getCenter(find.byKey(const ValueKey('tappable-study-term')));
    expect(tester.getCenter(find.byKey(const ValueKey('copy-han-0'))).dy,
        closeTo(termCenter.dy, 1));
    expect(tester.getCenter(find.byKey(const ValueKey('copy-han-1'))).dy,
        closeTo(termCenter.dy, 1));
    final cardCenter =
        tester.getCenter(find.byKey(const ValueKey('study-card-surface')));
    expect((termCenter.dx - cardCenter.dx).abs(), lessThan(1));
    expect(tester.getCenter(find.byKey(const ValueKey('copy-word'))).dx,
        greaterThan(termCenter.dx));
  });

  testWidgets('kanji tap copies and long press opens lookup actions',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.setChatGptConversationUrl('https://chatgpt.com/c/study-kanji');
    final service = KanjiLookupService(
      koreanDataLoader: () async => '{"遺":"남길 유"}',
      japaneseFetcher: (_) async => {
        'kanji': '遺',
        'meanings': ['leave behind'],
        'on_readings': ['イ'],
        'kun_readings': <String>[],
      },
    );
    final externalCalls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(externalLinkChannel, (call) async {
      externalCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': '遺'};
      }
      return null;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(externalLinkChannel, null));
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final word = Word(
      term: '遺跡',
      reading: 'いせき',
      meaning: '유적',
    );
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(
        store: store,
        words: [word],
        kanjiLookupService: service,
      ),
    ));
    await tester.pumpAndSettle();

    final firstKanji = find.byKey(const ValueKey('copy-han-0'));
    await tester.tap(firstKanji);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('kanji-detail-character')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1200));

    await tester.longPress(firstKanji);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
        find.byKey(const ValueKey('kanji-detail-character')), findsOneWidget);
    expect(find.text('남길 유'), findsOneWidget);
    expect(find.textContaining('음독: イ'), findsOneWidget);
    expect(find.textContaining('영문 뜻: leave behind'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-naver-hanja')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(externalCalls.single.arguments, {
      'url': 'https://hanja.dict.naver.com/#/search?query=%E9%81%BA',
    });

    await tester.tap(find.byKey(const ValueKey('open-chatgpt-kanji')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(externalCalls.last.arguments, {
      'url': 'https://chatgpt.com/c/study-kanji',
    });
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('study card fades details in term-reading-meaning order',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final speechCalls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(studySpeechChannel, (call) async {
      speechCalls.add(call);
      return null;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(studySpeechChannel, null));
    final store = await VocaStore.load();
    final word = Word(
      term: 'target-word',
      reading: 'いせき',
      meaning: '유적',
      example: 'example sentence',
      exampleMeaning: '예문 뜻',
    );
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: [word]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('target-word'), findsOneWidget);
    expect(find.text('いせき'), findsNothing);
    expect(find.text('유적'), findsNothing);
    final termRichText = tester.widget<Text>(
      find.byKey(const ValueKey('tappable-study-term')),
    );
    expect(termRichText.maxLines, 1);
    expect(termRichText.softWrap, isFalse);

    await tester.tap(find.byKey(const ValueKey('study-card')));
    await tester.pumpAndSettle();
    expect(speechCalls, hasLength(1));
    expect(speechCalls.single.method, 'speak');
    expect(speechCalls.single.arguments, {
      'text': 'target-word',
      'language': 'en-US',
    });
    expect(find.text('いせき'), findsOneWidget);
    expect(find.text('유적'), findsOneWidget);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);

    final positions = [
      'target-word',
      'いせき',
      '유적',
      'example sentence',
      '예문 뜻',
    ].map((text) => tester.getCenter(find.text(text)).dy).toList();
    expect(positions, orderedEquals([...positions]..sort()));

    await tester.tap(find.byKey(const ValueKey('study-card')));
    await tester.pumpAndSettle();
    expect(speechCalls, hasLength(1));
  });

  testWidgets('study card can put reading above and hide examples',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'readingAboveTerm': true,
      'showExamples': false,
    });
    final store = await VocaStore.load();
    final word = Word(
      term: '遺跡',
      reading: 'いせき',
      meaning: '유적',
      example: 'example sentence',
      exampleMeaning: '예문 뜻',
    );
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: [word]),
    ));
    await tester.pumpAndSettle();
    final termBefore =
        tester.getCenter(find.byKey(const ValueKey('tappable-study-term'))).dy;
    await tester.tap(find.byKey(const ValueKey('study-card')));
    await tester.pumpAndSettle();

    expect(
        tester.getCenter(find.text('いせき')).dy,
        lessThan(tester
            .getCenter(find.byKey(const ValueKey('tappable-study-term')))
            .dy));
    expect(
      tester.getCenter(find.byKey(const ValueKey('tappable-study-term'))).dy,
      closeTo(termBefore, 1),
    );
    expect(find.text('example sentence'), findsNothing);
    expect(find.text('예문 뜻'), findsNothing);
  });

  testWidgets('flipped card keeps drag movement in screen direction',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'flipCard': true});
    final store = await VocaStore.load();
    final word =
        Word(term: 'target-word', reading: 'reading', meaning: 'meaning');
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: [word]),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-card')));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey('study-card-surface'));
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await gesture.moveBy(const Offset(25, 0));
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    final moved = tester.widget<Transform>(surface);
    expect(moved.transform.storage[12], greaterThan(0));
    await gesture.cancel();
  });

  testWidgets('study card font editor shows a live preview',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    final word = Word(
      term: '日本語',
      reading: 'にほんご',
      meaning: '일본어',
      example: '日本語を勉強します。',
      exampleMeaning: '일본어를 공부합니다.',
    );
    await tester.pumpWidget(MaterialApp(
      home: CardStudyPage(store: store, words: [word]),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('font-size-card-preview')), findsOneWidget);
    final defaultMeaning = tester
        .widget<Text>(find.byKey(const ValueKey('font-preview-meaning')))
        .style!;
    expect(defaultMeaning.fontWeight, FontWeight.w500);
    expect(defaultMeaning.color?.a, closeTo(.70, .01));
    await tester.ensureVisible(
        find.byKey(const ValueKey('preview-reading-above-setting')));
    await tester
        .tap(find.byKey(const ValueKey('preview-reading-above-setting')));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byKey(const ValueKey('font-preview-reading'))).dy,
      lessThan(
          tester.getCenter(find.byKey(const ValueKey('font-preview-term'))).dy),
    );
    await tester.ensureVisible(
        find.byKey(const ValueKey('preview-show-examples-setting')));
    await tester
        .tap(find.byKey(const ValueKey('preview-show-examples-setting')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font-preview-example')), findsNothing);
    final before = tester
        .widget<Text>(find.byKey(const ValueKey('font-preview-term')))
        .style!
        .fontSize!;

    await tester.drag(find.byType(Slider).first, const Offset(90, 0));
    await tester.pumpAndSettle();
    final after = tester
        .widget<Text>(find.byKey(const ValueKey('font-preview-term')))
        .style!
        .fontSize!;
    expect(after, greaterThan(before));

    final weightControl = find.byKey(const ValueKey('meaning-weight-slider'));
    await tester.ensureVisible(weightControl);
    final weightSlider =
        find.descendant(of: weightControl, matching: find.byType(Slider));
    await tester.drag(weightSlider, const Offset(90, 0));
    await tester.pumpAndSettle();

    final opacityControl = find.byKey(const ValueKey('meaning-opacity-slider'));
    await tester.ensureVisible(opacityControl);
    final opacitySlider =
        find.descendant(of: opacityControl, matching: find.byType(Slider));
    await tester.drag(opacitySlider, const Offset(-90, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('save-card-font-sizes')));
    await tester.pumpAndSettle();
    expect(store.termFontSize, after);
    expect(store.readingAboveTerm, isTrue);
    expect(store.showExamples, isFalse);
    expect(store.meaningFontWeight, greaterThan(500));
    expect(store.meaningOpacity, lessThan(.70));
  });

  testWidgets('undo restores multiple dismissed cards in order',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('학습하기'));
    await tester.pumpAndSettle();

    Future<void> swipeUp() async {
      final card = find.byKey(const ValueKey('study-card'));
      final gesture = await tester.startGesture(tester.getCenter(card));
      await gesture.moveBy(const Offset(0, -80));
      await gesture.moveBy(const Offset(0, -80));
      await gesture.moveBy(const Offset(0, -80));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    await swipeUp();
    expect(find.text('resilience'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('undo-study'))).dy,
      greaterThan(
        tester.getCenter(find.byKey(const ValueKey('study-card'))).dy,
      ),
    );
    await swipeUp();
    expect(find.text('ambiguous'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(find.text('resilience'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(find.text('ephemeral'), findsOneWidget);
  });

  testWidgets('restores the exact study card after an app restart',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('학습하기'));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('study-card'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('resilience'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('study-card')));
    await tester.pumpAndSettle();
    expect(find.text('회복력, 탄력성'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    expect(find.text('resilience'), findsOneWidget);
    expect(find.text('회복력, 탄력성'), findsOneWidget);
  });

  testWidgets('searches and edits a word from a word book',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('기본 단어장'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('book-default-session-0')), findsOneWidget);
    await tester.tap(find.text('단어장 전체 보기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('word-search')), 'ephem');
    await tester.pumpAndSettle();

    expect(find.text('ephemeral'), findsOneWidget);
    await tester.tap(find.text('ephemeral'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('word-meaning')), '잠깐만 존재하는');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.textContaining('잠깐만 존재하는'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('searches across every word book', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('global-word-search')), 'resilience');
    await tester.pumpAndSettle();

    expect(
        find.descendant(
            of: find.byType(ListTile), matching: find.text('resilience')),
        findsOneWidget);
    expect(find.textContaining('기본 단어장'), findsOneWidget);
  });

  testWidgets('debounces rapid search input and shows only the latest query',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('global-word-search'));
    await tester.enterText(field, 'ephemeral');
    await tester.enterText(field, 'resilience');
    await tester.pump(const Duration(milliseconds: 119));

    final resilienceResult = find.descendant(
      of: find.byType(ListTile),
      matching: find.text('resilience'),
    );
    expect(resilienceResult, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(resilienceResult, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('ephemeral'),
      ),
      findsNothing,
    );
  });

  testWidgets('Japanese font applies to word book search results',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await VocaStore.load();
    await store.addBook(
      '日本語',
      [Word(term: '漢字', reading: 'かんじ', meaning: '한자')],
    );
    await store.setJapaneseFont('notoSerifJP');

    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('global-word-search')), '漢');
    await tester.pumpAndSettle();

    final result = find.text('漢字');
    expect(result, findsOneWidget);
    final theme = Theme.of(tester.element(result));
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback,
        contains('NotoSerifJP'));
  });

  testWidgets('requires confirmation before deleting a word book',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 단어장 만들기'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('text-input-dialog')), '삭제 테스트');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('편집'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('단어장을 삭제할까요?'), findsOneWidget);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('삭제 테스트'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    expect(find.text('삭제 테스트'), findsNothing);
  });

  testWidgets('settings exposes word book Excel export selection',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();

    final exportTile = find.byKey(const ValueKey('export-word-book-excel'));
    await tester.scrollUntilVisible(
      exportTile,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(exportTile);
    await tester.pumpAndSettle();

    expect(find.text('내보낼 단어장 선택'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('export-word-book-default')), findsOneWidget);
  });

  testWidgets('settings validates and saves a dedicated ChatGPT conversation',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();

    final setting =
        find.byKey(const ValueKey('chatgpt-conversation-url-setting'));
    await tester.scrollUntilVisible(
      setting,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    final settingTopLeft = tester.getTopLeft(setting);
    await tester.tapAt(settingTopLeft + const Offset(120, 12));
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('chatgpt-conversation-url-input'));
    await tester.enterText(input, 'https://example.com/c/wrong');
    await tester
        .tap(find.byKey(const ValueKey('save-chatgpt-conversation-url')));
    await tester.pumpAndSettle();
    expect(find.textContaining('chatgpt.com/c/'), findsWidgets);

    await tester.enterText(
        input, 'https://chatgpt.com/c/hanja-study?temporary=true');
    await tester
        .tap(find.byKey(const ValueKey('save-chatgpt-conversation-url')));
    await tester.pumpAndSettle();

    final reloaded = await VocaStore.load();
    expect(
        reloaded.chatGptConversationUrl, 'https://chatgpt.com/c/hanja-study');
  });

  testWidgets('Japanese font dropdown fits a narrow settings screen',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'japaneseFont': 'notoSerifJP'});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();

    final dropdown = find.byKey(const ValueKey('japanese-font-setting'));
    await tester.scrollUntilVisible(
      dropdown,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('일본어 명조체'), findsNothing);
    expect(find.text('Noto Serif JP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('word book reorder defines a rounded drag proxy',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('단어장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('편집'));
    await tester.pumpAndSettle();

    final reorderable = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    expect(reorderable.proxyDecorator, isNotNull);
  });
}
