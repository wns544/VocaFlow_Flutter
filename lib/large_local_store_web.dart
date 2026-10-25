import 'package:shared_preferences/shared_preferences.dart';
import 'large_local_store_keys.dart';
import 'web_durable_storage.dart';

const _storage = WebDurableStorage();

Future<String?> readLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  final stored = await _storage.read(key);
  if (stored != null) {
    // A previous interruption may have left the superseded localStorage copy.
    // IndexedDB is already durable, so release that scarce quota now.
    if (preferences.containsKey(key)) await preferences.remove(key);
    return stored;
  }

  // One-time migration from older web builds that used localStorage.
  final legacy = preferences.getString(key);
  if (legacy != null) {
    await _storage.write(key, legacy);
    await preferences.remove(key);
  }
  return legacy;
}

Future<void> writeLargeLocalValue(
  SharedPreferences preferences,
  String key,
  String value,
) async {
  await _storage.write(key, value);
  // Reclaim any duplicate left by an older web build.
  if (preferences.containsKey(key)) await preferences.remove(key);
}

Future<void> removeLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  await _storage.remove(key);
  if (preferences.containsKey(key)) await preferences.remove(key);
}

Future<void> migrateLegacyLargeLocalValues(
  SharedPreferences preferences,
) async {
  for (final key in preferences.getKeys()) {
    if (!isLargeLocalValueKey(key)) continue;
    final value = preferences.getString(key);
    if (value == null) continue;
    await writeLargeLocalValue(preferences, key, value);
  }
}

Future<void> prepareLargeLocalStoreMigration() async {}
