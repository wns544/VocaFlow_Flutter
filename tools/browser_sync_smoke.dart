// Standalone browser core check: no Flutter engine or external CDN dependency.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'package:vocaflow/sync_identifiers.dart';
import 'package:vocaflow/book_restore_archive.dart';
import 'package:vocaflow/reference_correction.dart';

void main() {
  try {
    final nonces = {for (var i = 0; i < 100; i++) createSyncNonce()};
    if (nonces.length != 100) throw StateError('nonce collision');
    final archive = BookRestorePoint.create(
        bookId: 'synthetic', kind: 'edit', deviceId: 'browser', payload: {});
    if (!archive.id.startsWith('archive-')) throw StateError('archive id');
    final original = {
      'bookId': 'synthetic',
      'wordId': 42,
      'fields': {'meaning': 'custom'},
      'fieldRevisions': {'meaning': 0}
    };
    final result = planReferenceCorrections(baseline: [
      original
    ], current: [
      original
    ], proposed: [
      {
        'bookId': 'synthetic',
        'wordId': 42,
        'fields': {'meaning': 'reference'}
      }
    ]);
    if ((result['eligible'] as List).isNotEmpty ||
        (result['held'] as List).length != 1) {
      throw StateError('revision0 custom value was not protected');
    }
    html.document.body!.text =
        jsonEncode({'status': 'PASS', 'checks': 3, 'writes': 0});
    html.document.body!.dataset['result'] = 'PASS';
  } catch (error) {
    html.document.body!.text = 'FAIL: $error';
    html.document.body!.dataset['result'] = 'FAIL';
  }
}
