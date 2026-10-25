import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/large_local_store.dart';

void main() {
  test('routes every growing account and sync payload outside preferences', () {
    for (final key in [
      'books',
      'sync.v2.replica',
      'sync.v2.checkpoint.user',
      'sync.v2.beforeMigration.user',
      'sync.v2.imported.user.backup',
      'accountState.v1.user',
      'cardChangeTracker.v1',
      'cardChangeTracker.v1.user',
      'cloudChangeTracker.v1',
      'cloudChangeTracker.v2.user',
    ]) {
      expect(isLargeLocalValueKey(key), isTrue, reason: key);
    }
  });

  test('keeps small settings in preferences', () {
    for (final key in [
      'fontSize.term',
      'autoBackup.enabled.user',
      'syncDiagnostics.sequence.v1',
      'wordRelations.v1',
    ]) {
      expect(isLargeLocalValueKey(key), isFalse, reason: key);
    }
  });
}
