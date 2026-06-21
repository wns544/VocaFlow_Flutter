// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vocaflow/main.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  setUp(() => shuffleNewStudyQueues = false);
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
    final surface = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('study-card-surface')));
    expect((background.decoration as BoxDecoration).color, isNot(Colors.white));
    expect((surface.decoration as BoxDecoration).color, Colors.white);
    expect(surface.transformAlignment, Alignment.centerRight);

    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('resilience'), findsOneWidget);
  });

  testWidgets('starts multiple selected sessions from the study tab',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('multi-session-study')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('multi-session-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('multi-session-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('multi-session-0')));
    await tester.tap(find.byKey(const ValueKey('multi-session-1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2개 세션'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-multi-session-study')));
    await tester.pumpAndSettle();

    expect(find.textContaining('개 남음'), findsOneWidget);
    expect(find.textContaining('세션 1 + 세션 2'), findsOneWidget);
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
    await tester.tap(find.text('단어장'));
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

    await tester.tap(find.byIcon(Icons.format_size));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('font-size-card-preview')), findsOneWidget);
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

    await tester.tap(find.byKey(const ValueKey('save-card-font-sizes')));
    await tester.pumpAndSettle();
    expect(store.termFontSize, after);
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
}
