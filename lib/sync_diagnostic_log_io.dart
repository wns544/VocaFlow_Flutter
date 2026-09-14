import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only, device-local diagnostic journal for learning-state sync.
class SyncDiagnosticLog {
  SyncDiagnosticLog({Future<Directory> Function()? directoryProvider})
      : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static const maxBytes = 64 * 1024 * 1024;
  static const _trimToBytes = 60 * 1024 * 1024;

  final Future<Directory> Function() _directoryProvider;
  Future<void> _tail = Future<void>.value();

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
        '${support.path}${Platform.pathSeparator}sync_diagnostics');
  }

  Future<File> _file() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) await directory.create(recursive: true);
    return File(
        '${directory.path}${Platform.pathSeparator}learning-state.ndjson');
  }

  Future<void> record({
    required String deviceId,
    required int sequence,
    required String event,
    Map<String, Object?> data = const {},
    DateTime? timestamp,
  }) {
    final entry = <String, Object?>{
      'timestamp': (timestamp ?? DateTime.now()).toUtc().toIso8601String(),
      'deviceId': deviceId,
      'sequence': sequence,
      'event': event,
      'data': data,
    };
    return _enqueue(() async {
      final file = await _file();
      await file.writeAsString('${jsonEncode(entry)}\n',
          mode: FileMode.append, flush: true);
      await _trimIfNeeded(file);
    });
  }

  Future<String> readAll() async {
    await _tail;
    final file = await _file();
    if (!await file.exists()) return '';
    return file.readAsString();
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
        final file = await _file();
        if (await file.exists()) await file.writeAsString('', flush: true);
      });

  Future<void> _trimIfNeeded(File file) async {
    final length = await file.length();
    if (length <= maxBytes) return;
    final bytes = await file.readAsBytes();
    final start = (bytes.length - _trimToBytes).clamp(0, bytes.length);
    var lineStart = start;
    while (lineStart < bytes.length && bytes[lineStart] != 10) {
      lineStart++;
    }
    if (lineStart < bytes.length) lineStart++;
    await file.writeAsBytes(bytes.sublist(lineStart), flush: true);
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.catchError((_) {});
    return next;
  }
}
