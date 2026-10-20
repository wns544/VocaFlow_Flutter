import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/sync_identifiers.dart';
import 'package:vocaflow/book_restore_archive.dart';

class _BrowserRandom implements Random {
  final limits = <int>[];
  @override
  int nextInt(int max) {
    if (max > 1 << 16) throw RangeError('browser random limit');
    limits.add(max);
    return limits.length == 1 ? 0 : max - 1;
  }

  @override
  bool nextBool() => throw UnimplementedError();
  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  test('nonce uses two browser-safe draws and preserves leading zeroes', () {
    final source = _BrowserRandom();
    expect(createSyncNonce(random: source), '00001ekf');
    expect(source.limits, [65536, 65536]);
  });
  test('secure nonce and restore IDs work on the real browser runtime', () {
    final values = {for (var i = 0; i < 100; i++) createSyncNonce()};
    expect(values, hasLength(100));
    final point = BookRestorePoint.create(
        bookId: 'book', kind: 'edit', deviceId: 'web', payload: {});
    expect(point.id, startsWith('archive-'));
  });
}
