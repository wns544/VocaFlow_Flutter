import 'dart:convert';

import 'dart:html' as html;

import 'book_restore_archive.dart';

class BookArchiveStore {
  String _key(String accountId, String id) => 'vocaflow.bookArchive.$accountId.$id';
  String _index(String accountId) => 'vocaflow.bookArchive.index.$accountId';

  Future<void> save(String accountId, BookRestorePoint point) async {
    final ids = (html.window.localStorage[_index(accountId)] ?? '')
        .split(',').where((id) => id.isNotEmpty).toSet()..add(point.id);
    html.window.localStorage[_index(accountId)] = ids.join(',');
    html.window.localStorage[_key(accountId, point.id)] = jsonEncode(point.toJson());
  }

  Future<BookRestorePoint?> load(String accountId, String id) async {
    final raw = html.window.localStorage[_key(accountId, id)];
    if (raw == null) return null;
    try { return BookRestorePoint.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)); } catch (_) { return null; }
  }

  Future<void> remove(String accountId, String id) async {
    final ids = (html.window.localStorage[_index(accountId)] ?? '')
        .split(',')
        .where((value) => value.isNotEmpty && value != id)
        .toList();
    html.window.localStorage[_index(accountId)] = ids.join(',');
    html.window.localStorage.remove(_key(accountId, id));
  }

  Future<List<BookRestorePoint>> list(String accountId) async {
    final result = <BookRestorePoint>[];
    for (final id in (html.window.localStorage[_index(accountId)] ?? '').split(',')) {
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
