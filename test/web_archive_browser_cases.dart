// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/book_archive_store_web.dart';
import 'package:vocaflow/book_restore_archive.dart';
import 'package:vocaflow/web_durable_storage.dart';

void registerWebArchiveTests() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy archive is copied before localStorage is reclaimed', () async {
    final account = 'browser-migration-test';
    final point = BookRestorePoint.create(
      bookId: 'book',
      kind: 'before_edit',
      deviceId: 'web',
      payload: {'name': 'original'},
    );
    final index = 'vocaflow.bookArchive.index.$account';
    final key = 'vocaflow.bookArchive.$account.${point.id}';
    html.window.localStorage[index] = point.id;
    html.window.localStorage[key] = jsonEncode(point.toJson());

    final archives = BookArchiveStore();
    final restored = await archives.list(account);
    expect(restored.single.id, point.id);
    expect(html.window.localStorage[index], isNull);
    expect(html.window.localStorage[key], isNull);
    expect(await const WebDurableStorage().read(key), isNotNull);

    await archives.remove(account, point.id);
    expect(await archives.list(account), isEmpty);
  });

  test('new archive uses IndexedDB and remains readable', () async {
    final account = 'browser-archive-test';
    final point = BookRestorePoint.create(
      bookId: 'book',
      kind: 'before_edit',
      deviceId: 'web',
      payload: {'explanation': 'original'},
    );
    final archives = BookArchiveStore();
    await archives.save(account, point);
    expect((await archives.load(account, point.id))?.payload,
        {'explanation': 'original'});
    expect(html.window.localStorage[
        'vocaflow.bookArchive.$account.${point.id}'], isNull);
    await archives.remove(account, point.id);
  });
}
