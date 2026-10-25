import 'dart:convert';

import 'dart:html' as html;

import 'book_restore_archive.dart';
import 'web_durable_storage.dart';

class BookArchiveStore {
  static const _storage = WebDurableStorage();

  String _key(String accountId, String id) =>
      'vocaflow.bookArchive.$accountId.$id';
  String _index(String accountId) => 'vocaflow.bookArchive.index.$accountId';

  Set<String> _ids(String? encoded) =>
      (encoded ?? '').split(',').where((id) => id.isNotEmpty).toSet();

  /// Move the old localStorage archives only after the IndexedDB copies and
  /// their index are durable. A failed migration keeps every old copy intact.
  Future<void> _migrateLegacy(String accountId) async {
    final legacyIndex = _index(accountId);
    final oldIds = _ids(html.window.localStorage[legacyIndex]);
    if (oldIds.isEmpty) return;
    final ids = _ids(await _storage.read(legacyIndex));
    for (final id in oldIds) {
      final key = _key(accountId, id);
      final legacy = html.window.localStorage[key];
      if (legacy == null) continue;
      if (await _storage.read(key) == null) {
        await _storage.write(key, legacy);
      }
      ids.add(id);
    }
    await _storage.write(legacyIndex, ids.join(','));
    for (final id in oldIds) {
      html.window.localStorage.remove(_key(accountId, id));
    }
    html.window.localStorage.remove(legacyIndex);
  }

  Future<void> save(String accountId, BookRestorePoint point) async {
    await _migrateLegacy(accountId);
    final index = _index(accountId);
    final ids = _ids(await _storage.read(index))..add(point.id);
    await _storage.write(_key(accountId, point.id), jsonEncode(point.toJson()));
    await _storage.write(index, ids.join(','));
  }

  Future<BookRestorePoint?> load(String accountId, String id) async {
    final raw = await _storage.read(_key(accountId, id)) ??
        html.window.localStorage[_key(accountId, id)];
    if (raw == null) return null;
    try {
      return BookRestorePoint.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String accountId, String id) async {
    await _migrateLegacy(accountId);
    final index = _index(accountId);
    final ids = _ids(await _storage.read(index))..remove(id);
    await _storage.remove(_key(accountId, id));
    await _storage.write(index, ids.join(','));
  }

  Future<List<BookRestorePoint>> list(String accountId) async {
    await _migrateLegacy(accountId);
    final result = <BookRestorePoint>[];
    for (final id in _ids(await _storage.read(_index(accountId)))) {
      final point = await load(accountId, id);
      if (point != null) result.add(point);
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<int> totalBytes(String accountId) async =>
      (await list(accountId)).fold<int>(
        0,
        (int sum, BookRestorePoint point) => sum + point.utf8Bytes.length,
      );
}
