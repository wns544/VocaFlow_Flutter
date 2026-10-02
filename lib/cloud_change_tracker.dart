import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'sync_diagnostic_log.dart';

enum AutoBackupNetworkPolicy { all, wifiOnly }

class CloudChangeSnapshot {
  const CloudChangeSnapshot({
    required this.generation,
    required this.profileDirty,
    required this.dictionaryOpenSettingDirty,
    required this.bookIds,
    required this.wordIdsByBook,
    required this.deletedWordIdsByBook,
    required this.deletedBookIds,
    required this.learningStateDirty,
    required this.learningStateGeneration,
  });

  final int generation;
  final bool profileDirty;
  final bool dictionaryOpenSettingDirty;
  final Set<String> bookIds;
  final Map<String, Set<int>> wordIdsByBook;
  final Map<String, Set<int>> deletedWordIdsByBook;
  final Set<String> deletedBookIds;
  final bool learningStateDirty;
  final int learningStateGeneration;

  bool get isEmpty => pendingCount == 0;
  int get pendingCount =>
      (profileDirty ? 1 : 0) +
      (dictionaryOpenSettingDirty ? 1 : 0) +
      bookIds.length +
      wordIdsByBook.values.fold<int>(0, (sum, ids) => sum + ids.length) +
      deletedWordIdsByBook.values.fold<int>(0, (sum, ids) => sum + ids.length) +
      deletedBookIds.length +
      (learningStateDirty ? 1 : 0);
}

class CloudChangeTracker {
  CloudChangeTracker._(this._prefs) {
    _diagnosticSequence = _prefs.getInt(_diagnosticSequenceKey) ?? 0;
    _restore();
  }

  static const _stateKey = 'cloudChangeTracker.v1';
  static const _enabledPrefix = 'autoBackup.enabled.';
  static const _initializedPrefix = 'autoBackup.initialized.';
  static const _networkPrefix = 'autoBackup.network.';
  static const _lastSuccessPrefix = 'autoBackup.lastSuccess.';
  static const _lastDownloadPrefix = 'autoBackup.lastDownload.';
  static const _lastErrorPrefix = 'autoBackup.lastError.';
  static const _logKey = 'autoBackup.logs.v1';
  static const _deviceIdKey = 'learningState.deviceId.v1';
  static const _diagnosticSequenceKey = 'syncDiagnostics.sequence.v1';

  final SharedPreferences _prefs;
  final SyncDiagnosticLog diagnostics = SyncDiagnosticLog();
  void Function()? onChanged;
  int _diagnosticSequence = 0;

  int _generation = 0;
  bool _profileDirty = false;
  bool _dictionaryOpenSettingDirty = false;
  final Set<String> _bookIds = {};
  final Map<String, Set<int>> _wordIdsByBook = {};
  final Map<String, Set<int>> _deletedWordIdsByBook = {};
  final Set<String> _deletedBookIds = {};
  bool _learningStateDirty = false;
  int _learningStateGeneration = 0;

  static Future<CloudChangeTracker> load() async =>
      CloudChangeTracker._(await SharedPreferences.getInstance());

  CloudChangeSnapshot get snapshot => CloudChangeSnapshot(
        generation: _generation,
        profileDirty: _profileDirty,
        dictionaryOpenSettingDirty: _dictionaryOpenSettingDirty,
        bookIds: Set.of(_bookIds),
        wordIdsByBook: _copyMap(_wordIdsByBook),
        deletedWordIdsByBook: _copyMap(_deletedWordIdsByBook),
        deletedBookIds: Set.of(_deletedBookIds),
        learningStateDirty: _learningStateDirty,
        learningStateGeneration: _learningStateGeneration,
      );

  int get pendingCount => snapshot.pendingCount;
  bool get learningStateDirty => _learningStateDirty;
  bool get managedBookContentDirty =>
      _bookIds.isNotEmpty ||
      _wordIdsByBook.isNotEmpty ||
      _deletedWordIdsByBook.isNotEmpty ||
      _deletedBookIds.isNotEmpty;

  /// Clears only book content after it reaches the dedicated managedBooks
  /// collection. Profile and learning-state work remain queued separately.
  Future<void> acknowledgeManagedBookContent(
      CloudChangeSnapshot uploaded) async {
    if (_generation != uploaded.generation) return;
    _bookIds.clear();
    _wordIdsByBook.clear();
    _deletedWordIdsByBook.clear();
    _deletedBookIds.clear();
    _generation++;
    await _persist();
    onChanged?.call();
  }

  /// Stable per-installation identity: each phone owns a separate remote
  /// learning-state document, so a stale phone cannot overwrite another.
  Future<String> deviceId() async {
    final saved = _prefs.getString(_deviceIdKey);
    if (saved != null && saved.isNotEmpty) return saved;
    final value =
        'device-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    await _prefs.setString(_deviceIdKey, value);
    return value;
  }

  /// Full-fidelity local-only journal entry. This never writes Firestore.
  Future<void> recordDiagnostic(String event,
      {Map<String, Object?> data = const {}}) async {
    try {
      // Reserve both values before the first await. Multiple UI and platform
      // callbacks can arrive in the same frame, and each must retain its own
      // ordering and actual arrival time in the journal.
      final sequence = ++_diagnosticSequence;
      final timestamp = DateTime.now().toUtc();
      await _prefs.setInt(_diagnosticSequenceKey, sequence);
      await diagnostics.record(
        deviceId: await deviceId(),
        sequence: sequence,
        event: event,
        data: data,
        timestamp: timestamp,
      );
    } catch (_) {
      // Diagnostics must never block study or synchronization.
    }
  }

  Future<void> markLearningState() => _mutate(() {
        _learningStateDirty = true;
        _learningStateGeneration++;
        return true;
      });

  Future<void> acknowledgeLearningState(CloudChangeSnapshot uploaded) async {
    if (!_learningStateDirty ||
        _learningStateGeneration != uploaded.learningStateGeneration) return;
    _learningStateDirty = false;
    _generation++;
    await _persist();
    onChanged?.call();
  }

  Future<void> markProfile() => _mutate(() {
        if (_profileDirty) return false;
        _profileDirty = true;
        return true;
      });

  Future<void> markDictionaryOpenSetting() => _mutate(() {
        if (_dictionaryOpenSettingDirty) return false;
        _dictionaryOpenSettingDirty = true;
        return true;
      });

  Future<void> markBook(String bookId) => _mutate(() {
        if (!_deletedBookIds.contains(bookId) && _bookIds.contains(bookId)) {
          return false;
        }
        _deletedBookIds.remove(bookId);
        _bookIds.add(bookId);
        return true;
      });

  Future<void> markWord(String bookId, int wordId) => _mutate(() {
        final existingDirty = _wordIdsByBook[bookId];
        final wasDeleted = _deletedBookIds.contains(bookId) ||
            (_deletedWordIdsByBook[bookId]?.contains(wordId) ?? false);
        if ((existingDirty?.contains(wordId) ?? false) && !wasDeleted) {
          return false;
        }
        _deletedBookIds.remove(bookId);
        _deletedWordIdsByBook[bookId]?.remove(wordId);
        final dirty = _wordIdsByBook.putIfAbsent(bookId, () => {});
        dirty.add(wordId);
        return true;
      });

  Future<void> markWords(String bookId, Iterable<int> wordIds) => _mutate(() {
        final ids = wordIds.toSet();
        final existingDirty = _wordIdsByBook[bookId] ?? const <int>{};
        final deleted = _deletedWordIdsByBook[bookId] ?? const <int>{};
        if (!_deletedBookIds.contains(bookId) &&
            ids.every(existingDirty.contains) &&
            ids.every((id) => !deleted.contains(id))) {
          return false;
        }
        _deletedBookIds.remove(bookId);
        final dirty = _wordIdsByBook.putIfAbsent(bookId, () => {});
        for (final wordId in ids) {
          _deletedWordIdsByBook[bookId]?.remove(wordId);
          dirty.add(wordId);
        }
        return true;
      });

  Future<void> deleteWord(String bookId, int wordId) => _mutate(() {
        final wasPendingDelete =
            _deletedWordIdsByBook[bookId]?.contains(wordId) ?? false;
        final wasPendingWrite =
            _wordIdsByBook[bookId]?.contains(wordId) ?? false;
        if (wasPendingDelete && !wasPendingWrite) return false;
        _wordIdsByBook[bookId]?.remove(wordId);
        _deletedWordIdsByBook.putIfAbsent(bookId, () => {}).add(wordId);
        _bookIds.add(bookId);
        return true;
      });

  Future<void> deleteBook(String bookId, Iterable<int> wordIds) => _mutate(() {
        if (_deletedBookIds.contains(bookId)) return false;
        _bookIds.remove(bookId);
        _wordIdsByBook.remove(bookId);
        _deletedBookIds.add(bookId);
        _deletedWordIdsByBook[bookId] = wordIds.toSet();
        _profileDirty = true;
        return true;
      });

  Future<void> markAll(Map<String, Iterable<int>> wordsByBook) => _mutate(() {
        var changed = !_profileDirty;
        _profileDirty = true;
        for (final entry in wordsByBook.entries) {
          _deletedBookIds.remove(entry.key);
          changed = _bookIds.add(entry.key) || changed;
          final dirty = _wordIdsByBook.putIfAbsent(entry.key, () => {});
          for (final wordId in entry.value) {
            changed = dirty.add(wordId) || changed;
          }
        }
        return changed;
      });

  Future<void> acknowledge(CloudChangeSnapshot uploaded) async {
    if (_generation != uploaded.generation) return;
    await clearPending();
  }

  Future<void> clearPending() async {
    _generation++;
    _profileDirty = false;
    _dictionaryOpenSettingDirty = false;
    _bookIds.clear();
    _wordIdsByBook.clear();
    _deletedWordIdsByBook.clear();
    _deletedBookIds.clear();
    _learningStateDirty = false;
    await _persist();
    onChanged?.call();
  }

  bool isInitialized(String uid) =>
      _prefs.getBool('$_initializedPrefix$uid') ?? false;
  bool isEnabled(String uid) => _prefs.getBool('$_enabledPrefix$uid') ?? false;
  AutoBackupNetworkPolicy networkPolicy(String uid) =>
      (_prefs.getString('$_networkPrefix$uid') == 'wifiOnly')
          ? AutoBackupNetworkPolicy.wifiOnly
          : AutoBackupNetworkPolicy.all;
  DateTime? lastSuccess(String uid) =>
      DateTime.tryParse(_prefs.getString('$_lastSuccessPrefix$uid') ?? '');
  DateTime? lastDownload(String uid) =>
      DateTime.tryParse(_prefs.getString('$_lastDownloadPrefix$uid') ?? '');
  List<String> get logs => _prefs.getStringList(_logKey) ?? <String>[];

  Future<void> recordLog(String message) async {
    final entries = <String>[
      DateTime.now().toIso8601String() + ' ' + message,
      ...logs
    ];
    await _prefs.setStringList(_logKey, entries.take(200).toList());
    // A human-readable sync log is not sync data. Notifying the backup
    // coordinator here used to re-enter its scheduler and reset the timer.
  }

  Future<void> clearLogs() async {
    await _prefs.remove(_logKey);
  }

  String? lastError(String uid) => _prefs.getString('$_lastErrorPrefix$uid');

  Future<void> setInitialized(String uid, bool value) async {
    await _prefs.setBool('$_initializedPrefix$uid', value);
    onChanged?.call();
  }

  Future<void> setEnabled(String uid, bool value) async {
    await _prefs.setBool('$_enabledPrefix$uid', value);
    onChanged?.call();
  }

  Future<void> setNetworkPolicy(
      String uid, AutoBackupNetworkPolicy policy) async {
    await _prefs.setString('$_networkPrefix$uid', policy.name);
    onChanged?.call();
  }

  Future<void> recordSuccess(String uid, DateTime time) async {
    await _prefs.setString('$_lastSuccessPrefix$uid', time.toIso8601String());
    await _prefs.remove('$_lastErrorPrefix$uid');
    onChanged?.call();
  }

  Future<void> recordDownload(String uid, DateTime time) async {
    await _prefs.setString('$_lastDownloadPrefix$uid', time.toIso8601String());
    onChanged?.call();
  }

  Future<void> recordError(String uid, Object error) async {
    await _prefs.setString('$_lastErrorPrefix$uid', error.toString());
    onChanged?.call();
  }

  Future<void> _mutate(bool Function() mutation) async {
    if (!mutation()) return;
    _generation++;
    _removeEmptySets();
    await _persist();
    onChanged?.call();
  }

  void _restore() {
    final encoded = _prefs.getString(_stateKey);
    if (encoded == null) return;
    try {
      final json = jsonDecode(encoded) as Map<String, dynamic>;
      _generation = json['generation'] as int? ?? 0;
      _profileDirty = json['profileDirty'] as bool? ?? false;
      _dictionaryOpenSettingDirty =
          json['dictionaryOpenSettingDirty'] as bool? ?? false;
      _bookIds.addAll((json['bookIds'] as List<dynamic>? ?? []).cast<String>());
      _restoreMap(json['wordIdsByBook'], _wordIdsByBook);
      _restoreMap(json['deletedWordIdsByBook'], _deletedWordIdsByBook);
      _deletedBookIds.addAll(
          (json['deletedBookIds'] as List<dynamic>? ?? []).cast<String>());
      _learningStateDirty = json['learningStateDirty'] as bool? ?? false;
      _learningStateGeneration =
          (json['learningStateGeneration'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // A corrupt journal must not prevent the local app from opening.
    }
  }

  Future<void> _persist() => _prefs.setString(
        _stateKey,
        jsonEncode({
          'generation': _generation,
          'profileDirty': _profileDirty,
          'dictionaryOpenSettingDirty': _dictionaryOpenSettingDirty,
          'bookIds': _bookIds.toList(),
          'wordIdsByBook': _encodeMap(_wordIdsByBook),
          'deletedWordIdsByBook': _encodeMap(_deletedWordIdsByBook),
          'deletedBookIds': _deletedBookIds.toList(),
          'learningStateDirty': _learningStateDirty,
          'learningStateGeneration': _learningStateGeneration,
        }),
      );

  void _removeEmptySets() {
    _wordIdsByBook.removeWhere((_, ids) => ids.isEmpty);
    _deletedWordIdsByBook.removeWhere((_, ids) => ids.isEmpty);
  }

  static Map<String, Set<int>> _copyMap(Map<String, Set<int>> source) =>
      source.map((key, value) => MapEntry(key, Set.of(value)));
  static Map<String, List<int>> _encodeMap(Map<String, Set<int>> source) =>
      source.map((key, value) => MapEntry(key, value.toList()));
  static void _restoreMap(dynamic raw, Map<String, Set<int>> target) {
    if (raw is! Map<String, dynamic>) return;
    for (final entry in raw.entries) {
      target[entry.key] = (entry.value as List<dynamic>)
          .map((value) => (value as num).toInt())
          .toSet();
    }
  }
}
