import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/main.dart';
import 'package:vocaflow/web_writer_guard.dart';

void main() {
  testWidgets('second tab fails closed before loading or changing shared state',
      (tester) async {
    SharedPreferences.setMockInitialValues({'sentinel': 'keep'});
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getKeys();
    var attempts = 0;
    await tester.pumpWidget(VocaFlowApp(acquireWebWriter: () async {
      attempts++;
      throw const WebWriterUnavailable();
    }));
    await tester.pumpAndSettle();
    expect(find.text('다른 탭에서 VocaFlow를 사용 중입니다.'), findsOneWidget);
    expect(prefs.getKeys(), before);
    expect(prefs.getString('sentinel'), 'keep');
    await tester.tap(find.byKey(const ValueKey('retry-startup')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(prefs.getKeys(), before);
  });

  testWidgets(
      'retry loads fresh local state only after writer becomes available',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var blocked = true;
    await tester.pumpWidget(VocaFlowApp(
      firebaseInitialization: Future.value(false),
      acquireWebWriter: () async {
        if (blocked) throw const WebWriterUnavailable();
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('다른 탭에서 VocaFlow를 사용 중입니다.'), findsOneWidget);
    blocked = false;
    await tester.tap(find.byKey(const ValueKey('retry-startup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ready-app')), findsOneWidget);
  });

  testWidgets('unsupported browser explains safe alternative without loading',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(VocaFlowApp(acquireWebWriter: () async {
      throw const WebWriterUnavailable(unsupported: true);
    }));
    await tester.pumpAndSettle();
    expect(find.text('이 브라우저에서는 안전한 저장을 시작할 수 없습니다.'), findsOneWidget);
    expect(find.textContaining('최신 Chrome 또는 Edge'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });
}
