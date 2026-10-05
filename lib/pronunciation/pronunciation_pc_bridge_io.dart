import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'pronunciation_pack_archive.dart';
import 'pronunciation_pack_store.dart';

/// A deliberately separate, app-private-external USB handoff area.
///
/// It contains only Japanese spellings/readings awaiting locally generated
/// audio. It never reads or writes a Firestore card or its learning record.
class PronunciationPcBridge {
  PronunciationPcBridge(this._store);

  final PronunciationPackStore _store;
  static const _requestFile = 'requests.json';
  static const _incomingDirectory = 'incoming';

  Future<Directory?> _root() async {
    if (!Platform.isAndroid) return null;
    final external = await getExternalStorageDirectory();
    if (external == null) return null;
    final root = Directory('${external.path}${Platform.pathSeparator}'
        'pronunciation-bridge');
    await root.create(recursive: true);
    return root;
  }

  /// Adds one exact spelling/reading only once. Japanese is intentionally
  /// required so ordinary Korean/English card TTS is never sent to the PC.
  Future<void> queueIfNeeded(String term, String reading) async {
    final normalizedTerm = term.trim();
    final normalizedReading = reading.trim();
    if (!_looksJapanese(normalizedTerm) || normalizedReading.isEmpty) return;
    final root = await _root();
    if (root == null) return;
    final file = File('${root.path}${Platform.pathSeparator}$_requestFile');
    final pending = await _readRequests(file);
    final key = '$normalizedTerm\u0000$normalizedReading';
    if (pending.any((item) => item.key == key)) return;
    pending.add(_BridgeRequest(normalizedTerm, normalizedReading));
    final temporary = File('${file.path}.next');
    await temporary.writeAsString(
      jsonEncode({'schemaVersion': 1, 'requests': pending.map((e) => e.json).toList()}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  /// Imports packs put into `incoming` by the USB PC companion. A malformed
  /// file stays in place for diagnosis; a successfully installed one is
  /// removed and its completed requests leave the queue.
  Future<bool> importIncoming() async {
    final root = await _root();
    if (root == null) return false;
    final incoming = Directory('${root.path}${Platform.pathSeparator}$_incomingDirectory');
    if (!await incoming.exists()) return false;
    var imported = false;
    await for (final entity in incoming.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.vfpitch.zip')) continue;
      try {
        final bytes = await entity.readAsBytes();
        final archive = PronunciationPackArchive.inspect(Uint8List.fromList(bytes));
        await _store.install(bytes);
        await entity.delete();
        await _removeFulfilledRequests(root, archive.manifest.entries
            .map((entry) => '${entry.term}\u0000${entry.reading}').toSet());
        imported = true;
      } catch (_) {
        // Do not lose a transferred pack merely because it needs inspection.
      }
    }
    return imported;
  }

  Future<List<_BridgeRequest>> _readRequests(File file) async {
    if (!await file.exists()) return [];
    try {
      final root = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (root['schemaVersion'] != 1 || root['requests'] is! List) return [];
      return (root['requests'] as List)
          .whereType<Map>()
          .map((raw) => _BridgeRequest.fromJson(Map<String, dynamic>.from(raw)))
          .where((item) => item.term.isNotEmpty && item.reading.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _removeFulfilledRequests(Directory root, Set<String> fulfilled) async {
    if (fulfilled.isEmpty) return;
    final file = File('${root.path}${Platform.pathSeparator}$_requestFile');
    final pending = await _readRequests(file);
    final remaining = pending.where((item) => !fulfilled.contains(item.key)).toList();
    if (remaining.length == pending.length) return;
    final temporary = File('${file.path}.next');
    await temporary.writeAsString(
      jsonEncode({'schemaVersion': 1, 'requests': remaining.map((e) => e.json).toList()}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  static bool _looksJapanese(String value) => RegExp(r'[\u3040-\u30ff\u3400-\u9fff]').hasMatch(value);
}

class _BridgeRequest {
  const _BridgeRequest(this.term, this.reading);
  factory _BridgeRequest.fromJson(Map<String, dynamic> json) => _BridgeRequest(
        (json['term'] as String? ?? '').trim(),
        (json['reading'] as String? ?? '').trim(),
      );
  final String term;
  final String reading;
  String get key => '$term\u0000$reading';
  Map<String, String> get json => {'term': term, 'reading': reading};
}
