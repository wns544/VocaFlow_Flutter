import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'large_local_store_keys.dart';
import 'performance_probe.dart';

/// Native durable storage for payloads that would otherwise make every
/// SharedPreferences update rewrite a very large XML document.
///
/// A write is published only after the temporary file can be read back. The
/// previous complete file is retained until the replacement is published, so
/// an interruption never turns a valid value into an empty value.
class _NativeLargeLocalStore {
  Future<void> _work = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final task = _work.then((_) => action());
    _work = task.then<void>((_) {}, onError: (_, __) {});
    return task;
  }

  Future<Directory> _directory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
        '${support.path}${Platform.pathSeparator}large_local_store_v1');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  String _name(String key) => sha256.convert(utf8.encode(key)).toString();

  Future<File> _file(String key) async => File(
      '${(await _directory()).path}${Platform.pathSeparator}${_name(key)}.json');

  Future<String?> read(String key) => _serial(() async {
        final file = await _file(key);
        final previous = File('${file.path}.previous');
        if (await file.exists()) return file.readAsString();
        if (await previous.exists()) {
          // A process stopped after moving the old value aside. Promote that
          // verified prior value before returning it.
          await previous.rename(file.path);
          return file.readAsString();
        }
        return null;
      });

  Future<void> write(String key, String value) => _serial(() async {
        final file = await _file(key);
        final previous = File('${file.path}.previous');
        final temporary =
            File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
        await temporary.writeAsString(value, flush: true);
        if (await temporary.readAsString() != value) {
          throw StateError('큰 기기 저장값 검증에 실패했습니다.');
        }
        if (await previous.exists()) await previous.delete();
        if (await file.exists()) await file.rename(previous.path);
        try {
          await temporary.rename(file.path);
        } catch (_) {
          if (!await file.exists() && await previous.exists()) {
            await previous.rename(file.path);
          }
          rethrow;
        }
        if (await previous.exists()) await previous.delete();
      });

  Future<void> remove(String key) => _serial(() async {
        final file = await _file(key);
        final previous = File('${file.path}.previous');
        if (await file.exists()) await file.delete();
        if (await previous.exists()) await previous.delete();
      });
}

final _storage = _NativeLargeLocalStore();
const _migrationChannel = MethodChannel('com.vocaflow.app/large_local_store');

bool _hasNoPlatformFileStore(Object error) =>
    error is MissingPluginException ||
    error.toString().contains('Binding has not yet been initialized');

/// Keep a giant legacy XML value out of the Dart heap.  The Android side
/// writes and verifies a file before it removes the XML entry.  A failure is
/// intentionally non-fatal: the old value remains the recovery source and a
/// later launch may retry the move.
Future<void> prepareLargeLocalStoreMigration() async {
  if (!Platform.isAndroid) return;
  try {
    await _migrationChannel.invokeMethod<Object?>('migrateLegacyLargeValues');
  } on MissingPluginException {
    // Unit tests and old embeddings use the safe Dart fallback below.
  } on PlatformException {
    // Do not turn a failed cleanup into a startup/data-loss event.
  }
}

Future<String?> readLargeLocalValue(
    SharedPreferences preferences, String key) async {
  String? stored;
  try {
    stored = await _storage.read(key);
  } catch (error) {
    if (!_hasNoPlatformFileStore(error)) rethrow;
    return preferences.getString(key);
  }
  if (stored != null) return stored;
  final legacy = preferences.getString(key);
  if (legacy == null) return null;
  // The file becomes authoritative before deleting the legacy XML entry.
  try {
    await _storage.write(key, legacy);
  } catch (error) {
    if (!_hasNoPlatformFileStore(error)) rethrow;
    return legacy;
  }
  await preferences.remove(key);
  return legacy;
}

Future<void> writeLargeLocalValue(
  SharedPreferences preferences,
  String key,
  String value,
) async {
  try {
    await PerformanceProbe.measure(
        'large_file_commit', () => _storage.write(key, value),
        data: {
          'kind': PerformanceProbe.keyKind(key),
          'characters': value.length,
        });
  } catch (error) {
    if (!_hasNoPlatformFileStore(error)) rethrow;
    if (!await preferences.setString(key, value)) {
      throw StateError('학습 기록을 기기에 저장하지 못했습니다: $key');
    }
    return;
  }
  // Failure to remove this duplicate is not allowed to make the just-verified
  // file write look like a failed user save. A later read/write retries it.
  if (preferences.containsKey(key)) await preferences.remove(key);
}

Future<void> removeLargeLocalValue(
    SharedPreferences preferences, String key) async {
  // Remove the fallback first: otherwise an interrupted delete can resurrect
  // stale data when the file is gone on the next launch.
  if (preferences.containsKey(key)) await preferences.remove(key);
  try {
    await _storage.remove(key);
  } catch (error) {
    if (!_hasNoPlatformFileStore(error)) rethrow;
  }
}

Future<void> migrateLegacyLargeLocalValues(
  SharedPreferences preferences,
) async {
  final pending = <String>[];
  for (final key in preferences.getKeys()) {
    if (!isLargeLocalValueKey(key)) continue;
    // Prefix-matched migration markers can be bools. They are small and must
    // never be coerced to a string (which used to abort app startup).
    final raw = preferences.get(key);
    if (raw is! String) continue;
    final value = raw;
    try {
      await _storage.write(key, value);
    } catch (error) {
      if (!_hasNoPlatformFileStore(error)) rethrow;
      return;
    }
    pending.add(key);
  }
  if (pending.isEmpty) return;
  if (!Platform.isAndroid) {
    for (final key in pending) {
      await preferences.remove(key);
    }
    return;
  }
  final removed = await _migrationChannel.invokeMethod<bool>(
      'removeLegacyKeys', <String, Object?>{'keys': pending});
  if (removed != true) {
    throw StateError('기존 대용량 기기 저장값 정리를 완료하지 못했습니다.');
  }
  // The native batch commit bypasses the plugin's in-memory cache. Reload it
  // before VocaStore starts, otherwise a later direct preference read could
  // briefly see the obsolete giant XML value.
  await preferences.reload();
}
