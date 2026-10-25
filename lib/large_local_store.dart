import 'package:shared_preferences/shared_preferences.dart';

import 'large_local_store_stub.dart'
    if (dart.library.io) 'large_local_store_io.dart'
    if (dart.library.html) 'large_local_store_web.dart' as implementation;
export 'large_local_store_keys.dart';

/// Stores large recovery/sync payloads outside the small browser localStorage
/// quota while preserving SharedPreferences behavior on native platforms.
Future<String?> readLargeLocalValue(
  SharedPreferences preferences,
  String key,
) =>
    implementation.readLargeLocalValue(preferences, key);

Future<void> writeLargeLocalValue(
  SharedPreferences preferences,
  String key,
  String value,
) =>
    implementation.writeLargeLocalValue(preferences, key, value);

Future<void> removeLargeLocalValue(
  SharedPreferences preferences,
  String key,
) =>
    implementation.removeLargeLocalValue(preferences, key);

Future<void> migrateLegacyLargeLocalValues(SharedPreferences preferences) =>
    implementation.migrateLegacyLargeLocalValues(preferences);

/// On Android, migrate before the Flutter SharedPreferences plugin materializes
/// the legacy XML in the Dart heap.
Future<void> prepareLargeLocalStoreMigration() =>
    implementation.prepareLargeLocalStoreMigration();
