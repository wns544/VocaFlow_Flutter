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
  await preferences.setString(key, value);
}

Future<void> removeLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  await preferences.remove(key);
}
