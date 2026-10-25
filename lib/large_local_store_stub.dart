import 'package:shared_preferences/shared_preferences.dart';
import 'performance_probe.dart';
import 'large_local_store_keys.dart';

Future<String?> readLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async =>
    preferences.getString(key);

Future<void> writeLargeLocalValue(
  SharedPreferences preferences,
  String key,
  String value,
) async {
  if (!await PerformanceProbe.measure(
      'large_preference_commit', () => preferences.setString(key, value),
      data: {
        'kind': PerformanceProbe.keyKind(key),
        'characters': value.length,
      })) {
    throw StateError('학습 기록을 기기에 저장하지 못했습니다: $key');
  }
}

Future<void> removeLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  await preferences.remove(key);
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
