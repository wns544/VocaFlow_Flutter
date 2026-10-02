import 'dart:convert';
import 'dart:math';

/// An immutable, account-owned recovery point. Its payload is intentionally
/// separate from managedBooks so card content never needs to be changed for a
/// rollback to work.
class BookRestorePoint {
  BookRestorePoint({
    required this.id,
    required this.bookId,
    required this.kind,
    required this.createdAt,
    required this.deviceId,
    required this.payload,
  });

  factory BookRestorePoint.create({
    required String bookId,
    required String kind,
    required String deviceId,
    required Map<String, dynamic> payload,
    DateTime? now,
  }) {
    final stamp = (now ?? DateTime.now()).toUtc();
    return BookRestorePoint(
      id: 'archive-${stamp.microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}',
      bookId: bookId,
      kind: kind,
      createdAt: stamp,
      deviceId: deviceId,
      payload: payload,
    );
  }

  final String id;
  final String bookId;
  final String kind;
  final DateTime createdAt;
  final String deviceId;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'id': id,
        'bookId': bookId,
        'kind': kind,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'deviceId': deviceId,
        'payload': payload,
      };

  factory BookRestorePoint.fromJson(Map<String, dynamic> json) =>
      BookRestorePoint(
        id: json['id'] as String? ?? '',
        bookId: json['bookId'] as String? ?? '',
        kind: json['kind'] as String? ?? 'revision',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        deviceId: json['deviceId'] as String? ?? '',
        payload: Map<String, dynamic>.from(json['payload'] as Map? ?? const {}),
      );

  List<int> get utf8Bytes => utf8.encode(jsonEncode(toJson()));
}
