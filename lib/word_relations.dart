import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_backup.dart';

/// Stable identity for a card without changing the card document itself.
class RelatedWordRef implements Comparable<RelatedWordRef> {
  const RelatedWordRef({required this.bookId, required this.wordId});

  final String bookId;
  final int wordId;

  String get key => '$bookId:$wordId';

  Map<String, dynamic> toJson() => {'bookId': bookId, 'wordId': wordId};

  factory RelatedWordRef.fromJson(Map<String, dynamic> json) => RelatedWordRef(
        bookId: json['bookId'] as String? ?? '',
        wordId: (json['wordId'] as num?)?.toInt() ?? 0,
      );

  @override
  int compareTo(RelatedWordRef other) => key.compareTo(other.key);

  @override
  bool operator ==(Object other) =>
      other is RelatedWordRef &&
      other.bookId == bookId &&
      other.wordId == wordId;

  @override
  int get hashCode => Object.hash(bookId, wordId);
}

/// One undirected relation. A tombstone is retained so an older offline phone
/// cannot restore a relation that was already removed on another device.
class WordRelation {
  const WordRelation({
    required this.id,
    required this.first,
    required this.second,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
  });

  final String id;
  final RelatedWordRef first;
  final RelatedWordRef second;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool deleted;

  bool involves(RelatedWordRef reference) =>
      first == reference || second == reference;

  RelatedWordRef otherThan(RelatedWordRef reference) =>
      first == reference ? second : first;

  Map<String, dynamic> toJson() => {
        'id': id,
        'first': first.toJson(),
        'second': second.toJson(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'deleted': deleted,
      };

  factory WordRelation.fromJson(Map<String, dynamic> json) {
    final first = RelatedWordRef.fromJson(
        Map<String, dynamic>.from(json['first'] as Map? ?? const {}));
    final second = RelatedWordRef.fromJson(
        Map<String, dynamic>.from(json['second'] as Map? ?? const {}));
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final updatedAt =
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? createdAt;
    return WordRelation(
      id: json['id'] as String? ?? relationIdFor(first, second),
      first: first,
      second: second,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  WordRelation copyWith({DateTime? updatedAt, bool? deleted}) => WordRelation(
        id: id,
        first: first,
        second: second,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
      );
}

String relationIdFor(RelatedWordRef one, RelatedWordRef two) {
  final pair = [one, two]..sort();
  return Uri.encodeComponent('${pair[0].key}|${pair[1].key}');
}

/// Local-first relation store. It only uses its own preferences key and the
/// dedicated Firestore `relations` collection; it never edits `words`.
class WordRelationPair {
  const WordRelationPair(this.first, this.second);

  final RelatedWordRef first;
  final RelatedWordRef second;
}

class WordRelationStore extends ChangeNotifier {
  static const _storageKey = 'wordRelations.v1';

  SharedPreferences? _prefs;
  final Map<String, WordRelation> _relations = {};
  bool _loaded = false;

  bool get isLoaded => _loaded;
  List<WordRelation> get all => _relations.values
      .where((relation) => !relation.deleted)
      .toList(growable: false);

  Future<void> load() async {
    if (_loaded) return;
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs!.getString(_storageKey);
    if (saved != null) {
      try {
        final rows = jsonDecode(saved) as List<dynamic>;
        for (final raw in rows) {
          final relation = WordRelation.fromJson(
              Map<String, dynamic>.from(raw as Map<dynamic, dynamic>));
          if (relation.first.bookId.isNotEmpty &&
              relation.second.bookId.isNotEmpty &&
              relation.first != relation.second) {
            _relations[relation.id] = relation;
          }
        }
      } catch (_) {
        // A malformed local relation cache should not affect vocab cards.
      }
    }
    _loaded = true;
    notifyListeners();
  }

  List<WordRelation> forWord(RelatedWordRef reference) => all
      .where((relation) => relation.involves(reference))
      .toList(growable: false);

  List<Map<String, dynamic>> snapshotForBook(String bookId) => _relations.values
      .where((relation) =>
          relation.first.bookId == bookId || relation.second.bookId == bookId)
      .map((relation) => relation.toJson())
      .toList(growable: false);

  /// Restores archived relation records with their original timestamps and
  /// IDs. A newer relation change made after the archive wins instead.
  Future<void> restoreArchived(Iterable<Map<String, dynamic>> rows) async {
    await load();
    final uploads = <WordRelation>[];
    for (final row in rows) {
      final archived = WordRelation.fromJson(row);
      final current = _relations[archived.id];
      final chosen = _newer(current, archived);
      if (!identical(chosen, current) && chosen != null) {
        _relations[archived.id] = chosen;
        uploads.add(chosen);
      }
    }
    if (uploads.isEmpty) return;
    await _persist();
    notifyListeners();
    for (final relation in uploads) {
      await _uploadOne(relation);
    }
  }

  bool isRelated(RelatedWordRef first, RelatedWordRef second) {
    if (first == second) return false;
    return _relations[relationIdFor(first, second)]?.deleted == false;
  }

  Future<void> toggle(RelatedWordRef first, RelatedWordRef second) async {
    if (first == second) return;
    await load();
    final id = relationIdFor(first, second);
    final existing = _relations[id];
    final now = DateTime.now().toUtc();
    final ordered = [first, second]..sort();
    final next = existing == null
        ? WordRelation(
            id: id,
            first: ordered[0],
            second: ordered[1],
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(updatedAt: now, deleted: !existing.deleted);
    _relations[id] = next;
    await _persist();
    notifyListeners();
    unawaited(_uploadOne(next));
  }

  Future<int> addAll(Iterable<WordRelationPair> pairs) async {
    await load();
    final now = DateTime.now().toUtc();
    final uploads = <WordRelation>[];
    var changed = 0;
    for (final pair in pairs) {
      if (pair.first == pair.second) continue;
      final id = relationIdFor(pair.first, pair.second);
      final existing = _relations[id];
      if (existing?.deleted == false) continue;
      final ordered = [pair.first, pair.second]..sort();
      final next = existing == null
          ? WordRelation(
              id: id,
              first: ordered[0],
              second: ordered[1],
              createdAt: now,
              updatedAt: now,
            )
          : existing.copyWith(updatedAt: now, deleted: false);
      _relations[id] = next;
      uploads.add(next);
      changed++;
    }
    if (changed == 0) return 0;
    await _persist();
    notifyListeners();
    for (final relation in uploads) {
      unawaited(_uploadOne(relation));
    }
    return changed;
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final rows =
        _relations.values.map((relation) => relation.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(rows));
  }

  Future<void> _uploadOne(WordRelation relation) async {
    try {
      await CloudBackup().uploadRelation(relation.toJson());
    } catch (_) {
      // Local data remains durable and will retry during the next pull/merge.
    }
  }

  Future<void> syncFromCloud() async {
    await load();
    try {
      final remoteRows = await CloudBackup().downloadRelations();
      final remote = <String, WordRelation>{
        for (final row in remoteRows)
          WordRelation.fromJson(row).id: WordRelation.fromJson(row),
      };
      final ids = {..._relations.keys, ...remote.keys};
      final uploads = <WordRelation>[];
      for (final id in ids) {
        final local = _relations[id];
        final cloud = remote[id];
        final chosen = _newer(local, cloud);
        if (chosen == null) continue;
        _relations[id] = chosen;
        if (identical(chosen, local) &&
            (cloud == null || local!.updatedAt.isAfter(cloud.updatedAt))) {
          uploads.add(chosen);
        }
      }
      await _persist();
      notifyListeners();
      for (final relation in uploads) {
        await _uploadOne(relation);
      }
    } catch (_) {
      // Cloud is optional; no relation or card is lost when it is unavailable.
    }
  }

  WordRelation? _newer(WordRelation? local, WordRelation? cloud) {
    if (local == null) return cloud;
    if (cloud == null) return local;
    final comparison = local.updatedAt.compareTo(cloud.updatedAt);
    if (comparison != 0) return comparison > 0 ? local : cloud;
    // A same-time delete wins to avoid resurrecting a removed relation.
    if (local.deleted != cloud.deleted) return local.deleted ? local : cloud;
    return local;
  }
}

final wordRelations = WordRelationStore();
