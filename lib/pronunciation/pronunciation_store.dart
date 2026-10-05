import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable reference to a card without adding pronunciation fields to it.
class PronunciationCardRef {
  const PronunciationCardRef({
    required this.bookId,
    required this.wordId,
    required this.fingerprint,
  });

  final String bookId;
  final int wordId;
  final String fingerprint;

  String get key => '$bookId:$wordId';

  static PronunciationCardRef fromCard({
    required String bookId,
    required int wordId,
    required String term,
    required String reading,
    required String meaning,
  }) =>
      PronunciationCardRef(
        bookId: bookId,
        wordId: wordId,
        fingerprint: sha256
            .convert(utf8.encode('$term\u0000$reading\u0000$meaning'))
            .toString(),
      );
}

class PronunciationSelection {
  const PronunciationSelection({
    required this.reference,
    required this.candidateId,
    required this.updatedAt,
  });

  final PronunciationCardRef reference;
  final String candidateId;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'bookId': reference.bookId,
        'wordId': reference.wordId,
        'fingerprint': reference.fingerprint,
        'candidateId': candidateId,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory PronunciationSelection.fromJson(Map<String, dynamic> json) =>
      PronunciationSelection(
        reference: PronunciationCardRef(
          bookId: json['bookId'] as String? ?? '',
          wordId: (json['wordId'] as num?)?.toInt() ?? 0,
          fingerprint: json['fingerprint'] as String? ?? '',
        ),
        candidateId: json['candidateId'] as String? ?? '',
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

/// Local-only and deliberately separate from cards, profile sync, and Firestore.
class PronunciationSelectionStore extends ChangeNotifier {
  static const _storageKey = 'pronunciationSelections.v1';
  static const transferSchemaVersion = 1;
  final Map<String, PronunciationSelection> _selections = {};
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_storageKey);
    if (raw == null) return;
    try {
      final items = jsonDecode(raw) as List<dynamic>;
      for (final item in items) {
        final selection = PronunciationSelection.fromJson(
            Map<String, dynamic>.from(item as Map));
        if (selection.reference.bookId.isNotEmpty &&
            selection.candidateId.isNotEmpty) {
          _selections[selection.reference.key] = selection;
        }
      }
    } catch (_) {
      // A damaged local selection cache must not prevent studying.
    }
  }

  PronunciationSelection? forCard(PronunciationCardRef reference) {
    final selection = _selections[reference.key];
    return selection?.reference.fingerprint == reference.fingerprint
        ? selection
        : null;
  }

  Future<void> select(
      PronunciationCardRef reference, String candidateId) async {
    _selections[reference.key] = PronunciationSelection(
      reference: reference,
      candidateId: candidateId,
      updatedAt: DateTime.now().toUtc(),
    );
    await _save();
    notifyListeners();
  }

  Future<void> clear(PronunciationCardRef reference) async {
    _selections.remove(reference.key);
    await _save();
    notifyListeners();
  }

  /// A portable local-only file. Importing never overwrites an existing choice;
  /// both phones therefore keep an intentional local correction on conflict.
  String exportTransferJson() => jsonEncode({
        'schemaVersion': transferSchemaVersion,
        'selections': _selections.values.map((item) => item.toJson()).toList(),
      });

  Future<int> importTransferJson(String source) async {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['schemaVersion'] != transferSchemaVersion) {
      throw const FormatException('Unsupported pronunciation selection file.');
    }
    final raw = decoded['selections'];
    if (raw is! List || raw.length > 20000) {
      throw const FormatException('Invalid pronunciation selection file.');
    }
    var imported = 0;
    for (final item in raw) {
      if (item is! Map) throw const FormatException('Invalid selection item.');
      final selection = PronunciationSelection.fromJson(
          Map<String, dynamic>.from(item));
      final reference = selection.reference;
      if (reference.bookId.isEmpty ||
          reference.wordId <= 0 ||
          reference.fingerprint.length != 64 ||
          selection.candidateId.isEmpty ||
          _selections.containsKey(reference.key)) {
        continue;
      }
      _selections[reference.key] = selection;
      imported++;
    }
    if (imported > 0) {
      await _save();
      notifyListeners();
    }
    return imported;
  }

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_storageKey,
        jsonEncode(_selections.values.map((e) => e.toJson()).toList()));
  }
}
