import 'package:shared_preferences/shared_preferences.dart';
import 'web_durable_storage.dart';

const _storage = WebDurableStorage();

Future<String?> readLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  final stored = await _storage.read(key);
  if (stored != null) return stored;

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
