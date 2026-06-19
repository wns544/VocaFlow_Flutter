// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vocaflow/main.dart';

void main() {
  testWidgets('home screen loads', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const VocaFlowApp());
    await tester.pumpAndSettle();

    expect(find.text('오늘도 단어 정복 💪'), findsOneWidget);
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
