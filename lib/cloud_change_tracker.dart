import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum AutoBackupNetworkPolicy { all, wifiOnly }

class CloudChangeSnapshot {
  const CloudChangeSnapshot({
    required this.generation,
    required this.profileDirty,
    required this.bookIds,
    required this.wordIdsByBook,
    required this.deletedWordIdsByBook,
    required this.deletedBookIds,
  });

  final int generation;
  final bool profileDirty;
  final Set<String> bookIds;
  final Map<String, Set<int>> wordIdsByBook;
  final Map<String, Set<int>> deletedWordIdsByBook;
  final Set<String> deletedBookIds;

  bool get isEmpty => pendingCount == 0;
  int get pendingCount =>
      (profileDirty ? 1 : 0) +
      bookIds.length +
      wordIdsByBook.values.fold<int>(0, (sum, ids) => sum + ids.length) +
      deletedWordIdsByBook.values.fold<int>(0, (sum, ids) => sum + ids.length) +
      deletedBookIds.length;
}

class CloudChangeTracker {
  CloudChangeTracker._(this._prefs) {
    _restore();
  }

  static const _stateKey = 'cloudChangeTracker.v1';
  static const _enabledPrefix = 'autoBackup.enabled.';
  static const _initializedPrefix = 'autoBackup.initialized.';
  static const _networkPrefix = 'autoBackup.network.';
  static const _lastSuccessPrefix = 'autoBackup.lastSuccess.';
  static const _lastErrorPrefix = 'autoBackup.lastError.';

  final SharedPreferences _prefs;
  void Function()? onChanged;

  int _generation = 0;
  bool _profileDirty = false;
  final Set<String> _bookIds = {};
  final Map<String, Set<int>> _wordIdsByBook = {};
  final Map<String, Set<int>> _deletedWordIdsByBook = {};
  final Set<String> _deletedBookIds = {};

  static Future<CloudChangeTracker> load() async =>
      CloudChangeTracker._(await SharedPreferences.getInstance());

  CloudChangeSnapshot get snapshot => CloudChangeSnapshot(
        generation: _generation,
        profileDirty: _profileDirty,
        bookIds: Set.of(_bookIds),
        wordIdsByBook: _copyMap(_wordIdsByBook),
        deletedWordIdsByBook: _copyMap(_deletedWordIdsByBook),
        deletedBookIds: Set.of(_deletedBookIds),
      );

  int get pendingCount => snapshot.pendingCount;

  Future<void> markProfile() => _mutate(() => _profileDirty = true);

  Future<void> markBook(String bookId) => _mutate(() {
        _deletedBookIds.remove(bookId);
        _bookIds.add(bookId);
      });

  Future<void> markWord(String bookId, int wordId) => _mutate(() {
        _deletedBookIds.remove(bookId);
        _deletedWordIdsByBook[bookId]?.remove(wordId);
        _wordIdsByBook.putIfAbsent(bookId, () => {}).add(wordId);
      });

  Future<void> markWords(String bookId, Iterable<int> wordIds) => _mutate(() {
        _deletedBookIds.remove(bookId);
        final dirty = _wordIdsByBook.putIfAbsent(bookId, () => {});
        for (final wordId in wordIds) {
          _deletedWordIdsByBook[bookId]?.remove(wordId);
          dirty.add(wordId);
        }
      });

  Future<void> deleteWord(String bookId, int wordId) => _mutate(() {
        _wordIdsByBook[bookId]?.remove(wordId);
        _deletedWordIdsByBook.putIfAbsent(bookId, () => {}).add(wordId);
        _bookIds.add(bookId);
      });

  Future<void> deleteBook(String bookId, Iterable<int> wordIds) => _mutate(() {
        _bookIds.remove(bookId);
        _wordIdsByBook.remove(bookId);
        _deletedBookIds.add(bookId);
        _deletedWordIdsByBook[bookId] = wordIds.toSet();
        _profileDirty = true;
      });

  Future<void> markAll(Map<String, Iterable<int>> wordsByBook) => _mutate(() {
        _profileDirty = true;
        for (final entry in wordsByBook.entries) {
          _deletedBookIds.remove(entry.key);
          _bookIds.add(entry.key);
          _wordIdsByBook.putIfAbsent(entry.key, () => {}).addAll(entry.value);
        }
      });

  Future<void> acknowledge(CloudChangeSnapshot uploaded) async {
    if (_generation != uploaded.generation) return;
    await clearPending();
  }

  Future<void> clearPending() async {
    _generation++;
    _profileDirty = false;
    _bookIds.clear();
    _wordIdsByBook.clear();
    _deletedWordIdsByBook.clear();
    _deletedBookIds.clear();
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

  Future<void> recordError(String uid, Object error) async {
    await _prefs.setString('$_lastErrorPrefix$uid', error.toString());
    onChanged?.call();
  }

  Future<void> _mutate(void Function() mutation) async {
    mutation();
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
      _bookIds.addAll((json['bookIds'] as List<dynamic>? ?? []).cast<String>());
      _restoreMap(json['wordIdsByBook'], _wordIdsByBook);
      _restoreMap(json['deletedWordIdsByBook'], _deletedWordIdsByBook);
      _deletedBookIds.addAll(
          (json['deletedBookIds'] as List<dynamic>? ?? []).cast<String>());
    } catch (_) {
      // A corrupt journal must not prevent the local app from opening.
    }
  }

  Future<void> _persist() => _prefs.setString(
        _stateKey,
        jsonEncode({
          'generation': _generation,
          'profileDirty': _profileDirty,
          'bookIds': _bookIds.toList(),
          'wordIdsByBook': _encodeMap(_wordIdsByBook),
          'deletedWordIdsByBook': _encodeMap(_deletedWordIdsByBook),
          'deletedBookIds': _deletedBookIds.toList(),
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
