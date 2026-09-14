import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/navigation_trace.dart';

void main() {
  test('a popped route reserves the immediately following back action', () {
    final gate = NavigationBackGate(window: const Duration(seconds: 1));

    gate.reserveAfterRoutePop(
      route: 'ModalBottomSheetRoute',
      routeType: 'ModalBottomSheetRoute<dynamic>',
      previousRoute: '/study',
    );

    expect(gate.accept('study_pop_scope'), isFalse);
  });

  test('reset permits an intentional later back action', () {
    final gate = NavigationBackGate(window: const Duration(seconds: 1));
    gate.reserveAfterRoutePop(
      route: 'DialogRoute',
      routeType: 'DialogRoute<dynamic>',
    );

    gate.reset('dialog_cancelled');

    expect(gate.accept('study_pop_scope'), isTrue);
  });
}