import 'dart:async';
import 'dart:html' as html;

import 'package:shared_preferences/shared_preferences.dart';

const _databaseName = 'vocaflow.largeLocal.v1';
const _storeName = 'values';

Future<dynamic> _openDatabase() async {
  final factory = html.window.indexedDB;
  if (factory == null) {
    throw StateError('IndexedDB is unavailable');
  }
  return factory.open(
    _databaseName,
    version: 1,
    onUpgradeNeeded: (event) {
      final dynamic database = (event.target as dynamic).result;
      if (!database.objectStoreNames!.contains(_storeName)) {
        database.createObjectStore(_storeName);
      }
    },
  );
}

Future<String?> _readIndexedDb(String key) async {
  final database = await _openDatabase();
  try {
    final transaction = database.transaction(_storeName, 'readonly');
    final value = await transaction.objectStore(_storeName).getObject(key);
    await transaction.completed;
    return value is String ? value : null;
  } finally {
    database.close();
  }
}

Future<void> _writeIndexedDb(String key, String value) async {
  final database = await _openDatabase();
  try {
    final transaction = database.transaction(_storeName, 'readwrite');
    transaction.objectStore(_storeName).put(value, key);
    await transaction.completed;
  } finally {
    database.close();
  }
}

Future<void> _removeIndexedDb(String key) async {
  final database = await _openDatabase();
  try {
    final transaction = database.transaction(_storeName, 'readwrite');
    transaction.objectStore(_storeName).delete(key);
    await transaction.completed;
  } finally {
    database.close();
  }
}

Future<String?> readLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  final stored = await _readIndexedDb(key);
  if (stored != null) return stored;

  // One-time migration from older web builds that used localStorage.
  final legacy = preferences.getString(key);
  if (legacy != null) {
    await _writeIndexedDb(key, legacy);
    await preferences.remove(key);
  }
  return legacy;
}

Future<void> writeLargeLocalValue(
  SharedPreferences preferences,
  String key,
  String value,
) async {
  await _writeIndexedDb(key, value);
  // Reclaim any duplicate left by an older web build.
  if (preferences.containsKey(key)) await preferences.remove(key);
}

Future<void> removeLargeLocalValue(
  SharedPreferences preferences,
  String key,
) async {
  await _removeIndexedDb(key);
  if (preferences.containsKey(key)) await preferences.remove(key);
}
