// Same IndexedDB schema as existing installations. Kept independent of Flutter
// so the real transaction path can be tested in a standalone browser lab.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

class WebDurableStorage {
  const WebDurableStorage({this.databaseName = 'vocaflow.largeLocal.v1'});
  final String databaseName;
  static const _storeName = 'values';

  Future<dynamic> _open() async {
    final factory = html.window.indexedDB;
    if (factory == null) throw StateError('IndexedDB is unavailable');
    return factory.open(databaseName, version: 1, onUpgradeNeeded: (event) {
      final dynamic database = (event.target as dynamic).result;
      if (!database.objectStoreNames!.contains(_storeName)) {
        database.createObjectStore(_storeName);
      }
    });
  }

  Future<String?> read(String key) async {
    final database = await _open();
    try {
      final transaction = database.transaction(_storeName, 'readonly');
      final results = await Future.wait<dynamic>([
        transaction.completed as Future<dynamic>,
        Future<dynamic>.sync(
            () => transaction.objectStore(_storeName).getObject(key)),
      ]);
      final value = results[1];
      return value is String ? value : null;
    } finally {
      database.close();
    }
  }

  Future<void> write(String key, String value) async {
    final database = await _open();
    try {
      final transaction = database.transaction(_storeName, 'readwrite');
      // Observe BOTH failures. A failed request must not escape as an unhandled
      // future, and a successful request is not durable until commit succeeds.
      await Future.wait<dynamic>([
        transaction.completed as Future<dynamic>,
        Future<dynamic>.sync(
            () => transaction.objectStore(_storeName).put(value, key)),
      ]);
    } finally {
      database.close();
    }
  }

  Future<void> remove(String key) async {
    final database = await _open();
    try {
      final transaction = database.transaction(_storeName, 'readwrite');
      await Future.wait<dynamic>([
        transaction.completed as Future<dynamic>,
        Future<dynamic>.sync(
            () => transaction.objectStore(_storeName).delete(key)),
      ]);
    } finally {
      database.close();
    }
  }
}
