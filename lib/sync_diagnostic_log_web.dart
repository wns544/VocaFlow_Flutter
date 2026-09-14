import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'dart:html' as html;
import 'package:archive/archive.dart';

/// Browser counterpart of the device-local diagnostic journal.
///
/// The journal stays in this browser only; it is never written to Firestore.
class SyncDiagnosticLog {
  static const _storageKey = 'vocaflow.syncDiagnostics.v1';
  static const maxBytes = 64 * 1024 * 1024;
  static const _trimToBytes = 60 * 1024 * 1024;

  Future<void> _tail = Future<void>.value();

  Future<void> record({
    required String deviceId,
    required int sequence,
    required String event,
    Map<String, Object?> data = const {},
    DateTime? timestamp,
  }) =>
      _enqueue(() async {
        final entry = <String, Object?>{
          'timestamp': (timestamp ?? DateTime.now()).toUtc().toIso8601String(),
          'deviceId': deviceId,
          'sequence': sequence,
          'event': event,
          'data': data,
        };
        final next = '${await readAll()}${jsonEncode(entry)}\n';
        final bytes = utf8.encode(next);
        final kept = bytes.length <= maxBytes
            ? next
            : utf8
                .decode(bytes.sublist(bytes.length - _trimToBytes),
                    allowMalformed: true)
                .split('\n')
                .skip(1)
                .join('\n');
        html.window.localStorage[_storageKey] = kept;
      });

  Future<String> readAll() async {
    await _tail;
    return html.window.localStorage[_storageKey] ?? '';
  }

  Future<List<String>> readRecent({int limit = 300}) async => (await readAll())
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList()
      .reversed
      .take(limit)
      .toList();

  Future<String> exportText() => readAll();

  Future<Uint8List> gzipBytes() async => Uint8List.fromList(
      GZipEncoder().encode(utf8.encode(await exportText())) ?? const []);

  Future<void> clear() => _enqueue(() async {
        html.window.localStorage.remove(_storageKey);
      });

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.catchError((_) {});
    return next;
  }
}
