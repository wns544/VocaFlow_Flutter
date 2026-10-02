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
    required this.bookBaseRevisions,
    required this.archiveIds,
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
  /// Server revision observed before the local edit. A managed-book write may
  /// only replace the exact revision it was based on.
  final Map<String, int> bookBaseRevisions;
  final Set<String> archiveIds;

  bool get isEmpty => pendingCount == 0;
  int get pendingCount =>
      (profileDirty ? 1 : 0) +
      (dictionaryOpenSettingDirty ? 1 : 0) +
      bookIds.length +
      wordIdsByBook.values.fold<int>(0, (sum, ids) => sum + ids.length) +
      deletedWordIdsByBook.values.fold<int>(0, (sum, ids) => sum + ids.length) +
      deletedBookIds.length +
      archiveIds.length +
      (learningStateDirty ? 1 : 0);
}

class CloudChangeTracker {
  CloudChangeTracker._(this._prefs) {
    _diagnosticSequence = _prefs.getInt(_diagnosticSequenceKey) ?? 0;
    _restore();
  }

  static const _stateKey = 'cloudChangeTracker.v1';
  static const _accountStatePrefix = 'cloudChangeTracker.v2.';
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
  String? _activeAccountId;
  bool _profileDirty = false;
  bool _dictionaryOpenSettingDirty = false;
  final Set<String> _bookIds = {};
  final Map<String, Set<int>> _wordIdsByBook = {};
  final Map<String, Set<int>> _deletedWordIdsByBook = {};
  final Set<String> _deletedBookIds = {};
  final Map<String, int> _remoteBookRevisions = {};
  final Map<String, int> _bookBaseRevisions = {};
  final Set<String> _archiveIds = {};
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
        bookBaseRevisions: Map.of(_bookBaseRevisions),
        archiveIds: Set.of(_archiveIds),
      );

  /// Switches the durable upload queue to the signed-in account. Old builds
  /// had one unscoped queue; its pending work is adopted once by the first
  /// account that signs in, never shared with a later account.
  Future<void> activateAccount(String uid) async {
    if (_activeAccountId == uid) return;
    final accountKey = '$_accountStatePrefix$uid';
    final scoped = _prefs.getString(accountKey);
    if (scoped != null) {
      _clearInMemory();
      _restoreEncoded(scoped);
    } else {
      // Only the first signed-in account may adopt old unscoped work. A
      // second account starts with an empty queue, never a copy of account A.
      if (_activeAccountId != null) _clearInMemory();
      await _prefs.setString(accountKey, _encodeState());
    }
    _activeAccountId = uid;
    await _persist();
    onChanged?.call();
  }

  int get pendingCount => snapshot.pendingCount;
  bool get learningStateDirty => _learningStateDirty;
  bool get managedBookContentDirty =>
      _bookIds.isNotEmpty ||
      _wordIdsByBook.isNotEmpty ||
      _deletedWordIdsByBook.isNotEmpty ||
      _deletedBookIds.isNotEmpty;
  bool get archiveContentDirty => _archiveIds.isNotEmpty;

  /// Clears only book content after it reaches the dedicated managedBooks
  /// collection. Profile and learning-state work remain queued separately.
  Future<void> acknowledgeManagedBookContent(
      CloudChangeSnapshot uploaded) async {
    if (_generation != uploaded.generation) return;
    _bookIds.clear();
    _wordIdsByBook.clear();
    _deletedWordIdsByBook.clear();
    _deletedBookIds.clear();
    _bookBaseRevisions.clear();
    _generation++;
    await _persist();
    onChanged?.call();
  }

  /// Stable per-installation identity: each phone owns a separate remote
  /// learning-state document, so a stale phone cannot overwrite another.
  Future<String> deviceId() async {
    final key = _activeAccountId == null
        ? _deviceIdKey
        : '$_deviceIdKey.$_activeAccountId';
    final saved = _prefs.getString(key);
    if (saved != null && saved.isNotEmpty) return saved;
    final value =
        'device-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    await _prefs.setString(key, value);
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

  Future<void> markArchive(String archiveId) =>
      _mutate(() => _archiveIds.add(archiveId));

  Future<void> acknowledgeArchives(Iterable<String> archiveIds) =>
      _mutate(() {
        var changed = false;
        for (final archiveId in archiveIds) {
          changed = _archiveIds.remove(archiveId) || changed;
        }
        return changed;
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
        _captureBookBaseRevision(bookId);
        _deletedBookIds.remove(bookId);
        _bookIds.add(bookId);
        return true;
      });

  Future<void> markWord(String bookId, int wordId) => _mutate(() {
        _captureBookBaseRevision(bookId);
        _deletedBookIds.remove(bookId);
        _deletedWordIdsByBook[bookId]?.remove(wordId);
        final dirty = _wordIdsByBook.putIfAbsent(bookId, () => {});
        dirty.add(wordId);
        return true;
      });

  Future<void> markWords(String bookId, Iterable<int> wordIds) => _mutate(() {
        final ids = wordIds.toSet();
        _captureBookBaseRevision(bookId);
        _deletedBookIds.remove(bookId);
        final dirty = _wordIdsByBook.putIfAbsent(bookId, () => {});
        for (final wordId in ids) {
          _deletedWordIdsByBook[bookId]?.remove(wordId);
          dirty.add(wordId);
        }
        return true;
      });

  Future<void> deleteWord(String bookId, int wordId) => _mutate(() {
        _captureBookBaseRevision(bookId);
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
        _captureBookBaseRevision(bookId);
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
          _captureBookBaseRevision(entry.key);
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
    _archiveIds.clear();
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
      _restoreEncoded(encoded);
    } catch (_) {
      // A corrupt journal must not prevent the local app from opening.
    }
  }

  void _restoreEncoded(String encoded) {
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
      _archiveIds.addAll(
          (json['archiveIds'] as List<dynamic>? ?? []).cast<String>());
      _learningStateDirty = json['learningStateDirty'] as bool? ?? false;
      _learningStateGeneration =
          (json['learningStateGeneration'] as num?)?.toInt() ?? 0;
      final revisions = json['remoteBookRevisions'] as Map<String, dynamic>?;
      revisions?.forEach((key, value) {
        if (value is num) _remoteBookRevisions[key] = value.toInt();
      });
      final bases = json['bookBaseRevisions'] as Map<String, dynamic>?;
      bases?.forEach((key, value) {
        if (value is num) _bookBaseRevisions[key] = value.toInt();
      });
    } catch (_) {
      // A corrupt journal must not prevent the local app from opening.
    }
  }

  Future<void> _persist() => _prefs.setString(
        _activeAccountId == null ? _stateKey : '$_accountStatePrefix$_activeAccountId',
        _encodeState(),
      );

  String _encodeState() => jsonEncode({
          'generation': _generation,
          'profileDirty': _profileDirty,
          'dictionaryOpenSettingDirty': _dictionaryOpenSettingDirty,
          'bookIds': _bookIds.toList(),
          'wordIdsByBook': _encodeMap(_wordIdsByBook),
          'deletedWordIdsByBook': _encodeMap(_deletedWordIdsByBook),
          'deletedBookIds': _deletedBookIds.toList(),
          'archiveIds': _archiveIds.toList(),
          'learningStateDirty': _learningStateDirty,
          'learningStateGeneration': _learningStateGeneration,
          'remoteBookRevisions': _remoteBookRevisions,
          'bookBaseRevisions': _bookBaseRevisions,
        });

  /// A downloaded revision is bookkeeping only: it must not schedule an
  /// upload. It is nevertheless durable so a restarted phone cannot write an
  /// edit against an unknown server version.
  Future<void> recordRemoteBookRevisions(Map<String, int> revisions) async {
    _remoteBookRevisions.addAll(revisions);
    await _persist();
  }

  void _captureBookBaseRevision(String bookId) {
    _bookBaseRevisions.putIfAbsent(bookId, () => _remoteBookRevisions[bookId] ?? 0);
  }

  void _clearInMemory() {
    _generation = 0;
    _profileDirty = false;
    _dictionaryOpenSettingDirty = false;
    _bookIds.clear();
    _wordIdsByBook.clear();
    _deletedWordIdsByBook.clear();
    _deletedBookIds.clear();
    _archiveIds.clear();
    _remoteBookRevisions.clear();
    _bookBaseRevisions.clear();
    _learningStateDirty = false;
    _learningStateGeneration = 0;
  }

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
