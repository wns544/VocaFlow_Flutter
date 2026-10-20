import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'large_local_store.dart';
import 'sync_identifiers.dart';

bool cardDeltasCover(
    int cursor, int remoteNumber, Iterable<CardBookChange> changes) {
  var next = cursor + 1;
  for (final change in changes) {
    if (change.number != next++) return false;
  }
  return next > remoteNumber;
}

class CardBookChange {
  const CardBookChange({
    required this.number,
    required this.wordId,
    required this.fields,
    required this.operationId,
    this.kind = 'cardPatch',
  });

  final int number;
  final int wordId;
  final Map<String, dynamic> fields;
  final String operationId;
  final String kind;
}

class CardBookSnapshot {
  const CardBookSnapshot({
    required this.book,
    required this.cards,
    required this.changeNumber,
  });

  final Map<String, dynamic> book;
  final List<Map<String, dynamic>> cards;
  final int changeNumber;
}

/// A durable, per-card outbox.  It intentionally has no study-state fields:
/// card text and learning progress are independent replication channels.
class CardChange {
  CardChange({
    required this.id,
    required this.bookId,
    required this.wordId,
    required this.fields,
    required this.before,
    required this.localVersion,
    required this.createdAt,
    this.kind = 'cardPatch',
  });

  final String id;
  final String bookId;
  final int wordId;
  final Map<String, dynamic> fields;
  final Map<String, dynamic> before;
  final int localVersion;
  final DateTime createdAt;
  final String kind;
  bool get isBookOperation => kind.startsWith('book');
  bool get isStructural => kind != 'cardPatch';

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'wordId': wordId,
        'fields': fields,
        'before': before,
        'localVersion': localVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'kind': kind,
      };

  factory CardChange.fromJson(Map<String, dynamic> json) => CardChange(
        id: json['id']?.toString() ?? '',
        bookId: json['bookId']?.toString() ?? '',
        wordId: (json['wordId'] as num?)?.toInt() ?? 0,
        fields: Map<String, dynamic>.from(json['fields'] as Map? ?? const {}),
        before: Map<String, dynamic>.from(json['before'] as Map? ?? const {}),
        localVersion: (json['localVersion'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        kind: json['kind']?.toString() ?? 'cardPatch',
      );
}

/// Account-scoped persistence for card operations.  A successful reply clears
/// only the exact operation that was sent; a newer edit to the same card is
/// therefore never accidentally acknowledged by an older request.
class CardChangeTracker {
  CardChangeTracker._(this._prefs) {
    _restore();
  }

  static const _legacyKey = 'cardChangeTracker.v1';
  static const _accountPrefix = 'cardChangeTracker.v1.';
  final SharedPreferences _prefs;
  String? _accountId;
  int _version = 0;
  String? _lastError;
  final List<CardChange> _pending = <CardChange>[];
  final Set<String> _stagingOperations = {};
  final Map<String, int> _appliedChanges = <String, int>{};
  final Map<String, String> _savedCards = {};
  final Set<String> _acknowledgedOperations = {};
  final Set<String> _deletedBooks = {};
  final Set<String> _deletedCards = {};
  // Server receipt and local read-back are independent durable obligations.
  final Map<String, String> _refreshCards = {};
  Map<String, String> get refreshCards => Map.unmodifiable(_refreshCards);
  bool get hasWork => isDirty || _refreshCards.isNotEmpty;

  Future<void> acknowledgeRefresh(String key, String operationId) async {
    if (_refreshCards[key] != operationId) return;
    final previousError = _lastError;
    _refreshCards.remove(key);
    if (!hasWork) _lastError = null;
    try {
      await _persist();
    } catch (_) {
      _refreshCards[key] = operationId;
      _lastError = previousError;
      rethrow;
    }
    notifyChanged();
  }

  bool bookWasDeleted(String id) => _deletedBooks.contains(id);
  bool cardWasDeleted(String bookId, int id) =>
      _deletedCards.contains('$bookId/$id');
  Future<void> recordServerDeletions(String bookId,
      {required bool deleted,
      List<Map<String, dynamic>> cards = const []}) async {
    var changed =
        deleted ? _deletedBooks.add(bookId) : _deletedBooks.remove(bookId);
    for (final card in cards) {
      final key = '$bookId/${card['id']}';
      changed = (card['deleted'] == true
              ? _deletedCards.add(key)
              : _deletedCards.remove(key)) ||
          changed;
    }
    if (changed) await _persist();
  }

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  DateTime? _lastSuccess;
  void Function()? onChanged;

  static Future<CardChangeTracker> load() async {
    final tracker = CardChangeTracker._(await SharedPreferences.getInstance());
    if (kIsWeb) {
      final encoded = await readLargeLocalValue(tracker._prefs, _legacyKey);
      if (encoded != null) tracker._restoreEncoded(encoded);
    }
    return tracker;
  }

  List<CardChange> get pending => List.unmodifiable(
      _pending.where((op) => !_stagingOperations.contains(op.id)));
  int get pendingCount => pending.length;
  bool get isDirty => pending.isNotEmpty;
  String? get lastError => _lastError;
  DateTime? get lastSuccess => _lastSuccess;
  bool contains(String operationId) =>
      pending.any((item) => item.id == operationId);
  bool wasAcknowledged(String operationId) =>
      _acknowledgedOperations.contains(operationId);
  String? get accountId => _accountId;
  Map<String, dynamic> pendingFields(String bookId, int wordId) => {
        for (final change in pending)
          if (change.bookId == bookId && change.wordId == wordId)
            for (final field in change.fields.entries)
              if (const [
                'term',
                'reading',
                'meaning',
                'example',
                'exampleMeaning',
                'explanation'
              ].contains(field.key))
                field.key: field.value,
      };
  int appliedChange(String bookId) => _appliedChanges[bookId] ?? 0;
  bool hasAppliedBook(String bookId) => _appliedChanges.containsKey(bookId);
  String statusFor(String bookId, int wordId) =>
      pending.any((item) => item.bookId == bookId && item.wordId == wordId)
          ? (_lastError == null ? '전송 대기' : '전송 실패 · 기기에는 저장됨')
          : (_refreshCards.containsKey('$bookId/$wordId')
              ? '서버 저장됨 · 최신값 확인 대기'
              : (_savedCards.containsKey('$bookId/$wordId')
                  ? '서버 저장됨'
                  : '기기에 저장됨'));
  void notifyChanged() {
    revision.value++;
    onChanged?.call();
  }

  Future<void> activateAccount(String uid) async {
    if (_accountId == uid) return;
    _accountId = uid;
    final encoded = await readLargeLocalValue(_prefs, '$_accountPrefix$uid');
    _pending.clear();
    _stagingOperations.clear();
    _appliedChanges.clear();
    _savedCards.clear();
    _acknowledgedOperations.clear();
    _deletedBooks.clear();
    _deletedCards.clear();
    _refreshCards.clear();
    _version = 0;
    _lastError = null;
    _lastSuccess = null;
    if (encoded != null) {
      _restoreEncoded(encoded);
    } else {
      // Adopt pre-account work once. It is local-first work made before the
      // auth callback completed, never data borrowed from another account.
      final legacy = await readLargeLocalValue(_prefs, _legacyKey);
      if (legacy != null) _restoreEncoded(legacy);
      await _persist();
    }
    onChanged?.call();
  }

  Future<CardChange?> enqueue({
    required String bookId,
    required int wordId,
    required Map<String, dynamic> before,
    required Map<String, dynamic> after,
    bool notify = true,
  }) async {
    const allowed = <String>{
      'term',
      'reading',
      'meaning',
      'example',
      'exampleMeaning',
      'explanation',
    };
    final fields = <String, dynamic>{};
    final previous = <String, dynamic>{};
    for (final key in allowed) {
      if (before[key] != after[key]) {
        fields[key] = after[key];
        previous[key] = before[key];
      }
    }
    if (fields.isEmpty) return null;
    _version++;
    final nonce = createSyncNonce();
    final change = CardChange(
      id: 'op-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$nonce',
      bookId: bookId,
      wordId: wordId,
      fields: fields,
      before: previous,
      localVersion: _version,
      createdAt: DateTime.now().toUtc(),
    );
    _stagingOperations.add(change.id);
    _pending.add(change);
    final previousError = _lastError;
    _lastError = null;
    try {
      await _persist();
    } catch (_) {
      // A rejected local write is not an uploadable operation. An existing
      // drain must not pick it up after the editor reports local failure.
      _pending.removeWhere((item) => item.id == change.id);
      _stagingOperations.remove(change.id);
      if (_lastError == null) _lastError = previousError;
      rethrow;
    }
    _stagingOperations.remove(change.id);
    if (notify) onChanged?.call();
    return change;
  }

  /// One local action (including an imported book) is journaled in one write
  /// before any cache mutation; a restart replays the complete action.
  Future<List<CardChange>> enqueueBatch(List<Map<String, dynamic>> operations,
      {bool notify = true}) async {
    final added = <CardChange>[];
    for (final raw in operations) {
      final operation = CardChange(
          id: 'op-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${createSyncNonce()}',
          bookId: raw['bookId'] as String,
          wordId: raw['wordId'] as int? ?? 0,
          fields: Map<String, dynamic>.from(raw['fields'] as Map? ?? {}),
          before: Map<String, dynamic>.from(raw['before'] as Map? ?? {}),
          kind: raw['kind'] as String,
          localVersion: ++_version,
          createdAt: DateTime.now().toUtc());
      added.add(operation);
    }
    _stagingOperations.addAll(added.map((op) => op.id));
    _pending.addAll(added);
    try {
      await _persist();
    } catch (_) {
      _pending.removeWhere((op) => added.contains(op));
      _stagingOperations.removeAll(added.map((op) => op.id));
      rethrow;
    }
    _stagingOperations.removeAll(added.map((op) => op.id));
    if (notify && added.isNotEmpty) notifyChanged();
    return added;
  }

  Future<void> acknowledge(CardChange sent) async {
    if (_stagingOperations.contains(sent.id)) return;
    final exists = _pending.any((item) => item.id == sent.id);
    if (!exists) return;
    final index = _pending.indexWhere((item) => item.id == sent.id);
    final previousSuccess = _lastSuccess;
    final previousError = _lastError;
    final previousSaved = Map<String, String>.from(_savedCards);
    final previousOperations = Set<String>.from(_acknowledgedOperations);
    final previousCursor = _appliedChanges[sent.bookId];
    final refreshKey = '${sent.bookId}/${sent.wordId}';
    final previousRefresh = _refreshCards[refreshKey];
    if (!sent.isStructural) _refreshCards[refreshKey] = sent.id;
    // A failed post-save refresh must remain retryable after a restart.
    if (sent.isStructural) _appliedChanges.remove(sent.bookId);
    _pending.removeAt(index);
    _acknowledgedOperations.add(sent.id);
    while (_acknowledgedOperations.length > 512) {
      _acknowledgedOperations.remove(_acknowledgedOperations.first);
    }
    _lastSuccess = DateTime.now().toUtc();
    _savedCards['${sent.bookId}/${sent.wordId}'] =
        _lastSuccess!.toIso8601String();
    if (_pending.isEmpty) _lastError = null;
    try {
      await _persist();
    } catch (_) {
      _pending.insert(index, sent);
      _lastSuccess = previousSuccess;
      _lastError = previousError;
      _savedCards
        ..clear()
        ..addAll(previousSaved);
      _acknowledgedOperations
        ..clear()
        ..addAll(previousOperations);
      if (previousCursor != null) _appliedChanges[sent.bookId] = previousCursor;
      if (previousRefresh == null) {
        _refreshCards.remove(refreshKey);
      } else {
        _refreshCards[refreshKey] = previousRefresh;
      }
      rethrow;
    }
    notifyChanged();
  }

  Future<void> recordFailure(Object error) async {
    _lastError = error.toString();
    await _persist();
    notifyChanged();
  }

  Future<void> acknowledgeRemote(String bookId, int number) async {
    if (_appliedChanges.containsKey(bookId) &&
        number <= _appliedChanges[bookId]!) return;
    _appliedChanges[bookId] = number;
    await _persist();
  }

  Future<void> clearMigratedLegacyWork() async {
    _pending.clear();
    _appliedChanges.clear();
    _lastError = null;
    await _persist();
    onChanged?.call();
  }

  void _restore() {
    final encoded = _prefs.getString(_legacyKey);
    if (encoded != null) _restoreEncoded(encoded);
  }

  void _restoreEncoded(String encoded) {
    try {
      final raw = jsonDecode(encoded) as Map<String, dynamic>;
      _version = (raw['version'] as num?)?.toInt() ?? 0;
      _lastError = raw['lastError'] as String?;
      _lastSuccess = DateTime.tryParse(raw['lastSuccess']?.toString() ?? '');
      _acknowledgedOperations.addAll(
          (raw['acknowledgedOperations'] as List? ?? const [])
              .whereType<String>());
      _deletedBooks
          .addAll((raw['deletedBooks'] as List? ?? []).whereType<String>());
      _deletedCards
          .addAll((raw['deletedCards'] as List? ?? []).whereType<String>());
      final saved = raw['savedCards'];
      final refresh = raw['refreshCards'];
      if (refresh is Map) {
        for (final entry in refresh.entries) {
          _refreshCards[entry.key.toString()] = entry.value.toString();
        }
      }
      if (saved is Map) {
        for (final entry in saved.entries) {
          _savedCards[entry.key.toString()] = entry.value.toString();
        }
      }
      final cursors = raw['appliedChanges'];
      // Old receipts may have masked a server value without a read-back job.
      if (!raw.containsKey('refreshCards')) {
        for (final key in _savedCards.keys) {
          if (!key.endsWith('/0')) _refreshCards[key] = 'legacy-readback';
        }
      }
      if (cursors is Map) {
        for (final entry in cursors.entries) {
          if (entry.value is num) {
            _appliedChanges[entry.key.toString()] =
                (entry.value as num).toInt();
          }
        }
      }
      _pending
        ..clear()
        ..addAll((raw['pending'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => CardChange.fromJson(Map<String, dynamic>.from(item)))
            .where((item) => item.id.isNotEmpty && item.bookId.isNotEmpty));
    } catch (_) {
      // Preserve the original bytes for recovery instead of silently losing
      // the only copy of a user's edits on the next write.
      _lastError = '카드 전송 기록을 읽지 못했습니다. 복구가 필요합니다.';
      unawaitedRecovery(encoded);
    }
  }

  void unawaitedRecovery(String encoded) {
    _prefs.setString(
        'cardChangeTracker.corrupt.${DateTime.now().microsecondsSinceEpoch}',
        encoded);
  }

  Future<void> _persist() async {
    await writeLargeLocalValue(
      _prefs,
      _accountId == null ? _legacyKey : '$_accountPrefix$_accountId',
      jsonEncode({
        'version': _version,
        'lastError': _lastError,
        'lastSuccess': _lastSuccess?.toIso8601String(),
        'savedCards': _savedCards,
        'refreshCards': _refreshCards,
        'acknowledgedOperations': _acknowledgedOperations.toList(),
        'deletedBooks': _deletedBooks.toList(),
        'deletedCards': _deletedCards.toList(),
        'appliedChanges': _appliedChanges,
        'pending': _pending.map((item) => item.toJson()).toList(),
      }),
    );
  }
}
