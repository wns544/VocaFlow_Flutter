import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/performance_probe.dart';

void main() {
  test('instrumentation buffer caps UTF-8 bytes and reports lost events', () {
    final buffer = BoundedPerformanceEvents(limit: 100);
    for (var i = 0; i < 1000; i++) {
      buffer.add({'event': '저장', 'i': i});
    }
    expect(buffer.bytes, lessThanOrEqualTo(100));
    expect(buffer.entries.length + buffer.dropped, 1000);
    expect(buffer.dropped, greaterThan(0));
    buffer.clear();
    expect(buffer.entries, isEmpty);
    expect(buffer.bytes, 0);
    expect(buffer.dropped, 0);
  });
  test('inactive instrumentation preserves return values and failures',
      () async {
    expect(PerformanceProbe.supported, isFalse);
    final original = Future.value(7);
    expect(
        identical(PerformanceProbe.measure('test', () => original), original),
        isTrue);
    expect(await PerformanceProbe.measure('test', () async => 42), 42);
    final error = StateError('original storage failure');
    await expectLater(PerformanceProbe.measure('test', () async => throw error),
        throwsA(same(error)));
    expect(PerformanceProbe.instance.recording, isFalse);
    expect(PerformanceProbe.instance.pending, isEmpty);
  });
}
