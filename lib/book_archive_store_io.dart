import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'book_restore_archive.dart';

class BookArchiveStore {
  Future<Directory> _directory(String accountId) async {
    final support = await getApplicationSupportDirectory();
    final safe = base64Url.encode(utf8.encode(accountId)).replaceAll('=', '');
    final directory = Directory('${support.path}${Platform.pathSeparator}book_archives${Platform.pathSeparator}$safe');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<void> save(String accountId, BookRestorePoint point) async {
    final directory = await _directory(accountId);
    await File('${directory.path}${Platform.pathSeparator}${point.id}.json')
        .writeAsString(jsonEncode(point.toJson()), flush: true);
  }

  Future<BookRestorePoint?> load(String accountId, String id) async {
    final directory = await _directory(accountId);
    final file = File('${directory.path}${Platform.pathSeparator}$id.json');
    if (!await file.exists()) return null;
    try {
      return BookRestorePoint.fromJson(
          Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map));
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String accountId, String id) async {
    final directory = await _directory(accountId);
    final file = File('${directory.path}${Platform.pathSeparator}$id.json');
    if (await file.exists()) await file.delete();
  }

  Future<List<BookRestorePoint>> list(String accountId) async {
    final directory = await _directory(accountId);
    final result = <BookRestorePoint>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        result.add(BookRestorePoint.fromJson(
            Map<String, dynamic>.from(jsonDecode(await entity.readAsString()) as Map)));
      } catch (_) {}
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<int> totalBytes(String accountId) async {
    final directory = await _directory(accountId);
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }
}
