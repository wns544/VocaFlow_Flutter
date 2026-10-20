import 'package:shared_preferences/shared_preferences.dart';

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
  if (!await preferences.setString(key, value)) {
    throw StateError('학습 기록을 기기에 저장하지 못했습니다: $key');
  }
}

Future<void> removeLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  await preferences.remove(key);
}
