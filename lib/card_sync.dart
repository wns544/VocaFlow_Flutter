import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

class CardBookChange {
  const CardBookChange({
    required this.number,
    required this.wordId,
    required this.fields,
    required this.operationId,
  });

  final int number;
  final int wordId;
  final Map<String, dynamic> fields;
  final String operationId;
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
  });

  final String id;
  final String bookId;
  final int wordId;
  final Map<String, dynamic> fields;
  final Map<String, dynamic> before;
  final int localVersion;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'wordId': wordId,
        'fields': fields,
        'before': before,
        'localVersion': localVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
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
  final Map<String, int> _appliedChanges = <String, int>{};
  final Map<String, String> _savedCards = {};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  DateTime? _lastSuccess;
  void Function()? onChanged;

  static Future<CardChangeTracker> load() async =>
      CardChangeTracker._(await SharedPreferences.getInstance());

  List<CardChange> get pending => List.unmodifiable(_pending);
  int get pendingCount => _pending.length;
  bool get isDirty => _pending.isNotEmpty;
  String? get lastError => _lastError;
  DateTime? get lastSuccess => _lastSuccess;
  bool contains(String operationId) =>
      _pending.any((item) => item.id == operationId);
  Map<String, dynamic> pendingFields(String bookId, int wordId) => {
        for (final change in _pending)
          if (change.bookId == bookId && change.wordId == wordId)
            ...change.fields,
      };
  int appliedChange(String bookId) => _appliedChanges[bookId] ?? 0;
  bool hasAppliedBook(String bookId) => _appliedChanges.containsKey(bookId);
  String statusFor(String bookId, int wordId) =>
      _pending.any((item) => item.bookId == bookId && item.wordId == wordId)
          ? (_lastError == null ? '전송 대기' : '전송 실패 · 기기에는 저장됨')
          : (_savedCards.containsKey('$bookId/$wordId') ? '서버 저장됨' : '기기에 저장됨');
  void notifyChanged() {
    revision.value++;
    onChanged?.call();
  }

  Future<void> activateAccount(String uid) async {
    if (_accountId == uid) return;
    _accountId = uid;
    final encoded = _prefs.getString('$_accountPrefix$uid');
    _pending.clear();
    _appliedChanges.clear();
    _savedCards.clear();
    _version = 0;
    _lastError = null;
    _lastSuccess = null;
    if (encoded != null) {
      _restoreEncoded(encoded);
    } else {
      // Adopt pre-account work once. It is local-first work made before the
      // auth callback completed, never data borrowed from another account.
      final legacy = _prefs.getString(_legacyKey);
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
    final nonce = Random.secure().nextInt(1 << 32).toRadixString(36);
    final change = CardChange(
      id: 'op-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$nonce',
      bookId: bookId,
      wordId: wordId,
      fields: fields,
      before: previous,
      localVersion: _version,
      createdAt: DateTime.now().toUtc(),
    );
    _pending.add(change);
    _lastError = null;
    await _persist();
    if (notify) onChanged?.call();
    return change;
  }

  Future<void> acknowledge(CardChange sent) async {
    final exists = _pending.any((item) => item.id == sent.id);
    if (!exists) return;
    _pending.removeWhere((item) => item.id == sent.id);
    _lastSuccess = DateTime.now().toUtc();
    _savedCards['${sent.bookId}/${sent.wordId}'] =
        _lastSuccess!.toIso8601String();
    if (_pending.isEmpty) _lastError = null;
    await _persist();
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
      final saved = raw['savedCards'];
      if (saved is Map) {
        for (final entry in saved.entries) {
          _savedCards[entry.key.toString()] = entry.value.toString();
        }
      }
      final cursors = raw['appliedChanges'];
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
            .where((item) =>
                item.id.isNotEmpty &&
                item.bookId.isNotEmpty &&
                item.wordId != 0));
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
    final saved = await _prefs.setString(
      _accountId == null ? _legacyKey : '$_accountPrefix$_accountId',
      jsonEncode({
        'version': _version,
        'lastError': _lastError,
        'lastSuccess': _lastSuccess?.toIso8601String(),
        'savedCards': _savedCards,
        'appliedChanges': _appliedChanges,
        'pending': _pending.map((item) => item.toJson()).toList(),
      }),
    );
    if (!saved) throw StateError('카드 수정 전송 기록을 기기에 저장하지 못했습니다.');
  }
}
