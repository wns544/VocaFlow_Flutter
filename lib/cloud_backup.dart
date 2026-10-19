import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'cloud_change_tracker.dart';
import 'card_sync.dart';
import 'book_restore_archive.dart';
import 'models.dart';
import 'store.dart';

Uint8List _encodeSyncPayload(Map<String, dynamic> payload) =>
    Uint8List.fromList(utf8.encode(jsonEncode(payload)));

Map<String, dynamic> _decodeSyncPayload(List<int> bytes) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)));

Map<String, int> _manifestRevisions(Map<String, dynamic>? data) {
  final revisions = <String, int>{};
  final entries = data?['entries'];
  if (entries is! List) return revisions;
  for (final raw in entries) {
    if (raw is! Map) continue;
    final id = raw['id']?.toString() ?? '';
    final revision = (raw['revision'] as num?)?.toInt();
    if (id.isNotEmpty && revision != null) revisions[id] = revision;
  }
  return revisions;
}

List<Map<String, Object>> _manifestEntries(Map<String, int> revisions) {
  final ids = revisions.keys.toList()..sort();
  return [
    for (final id in ids) {'id': id, 'revision': revisions[id]!},
  ];
}

class CloudQuotaExceededException implements Exception {
  const CloudQuotaExceededException();

  @override
  String toString() => 'CloudQuotaExceededException';
}

class CloudSyncTimeoutException implements Exception {
  const CloudSyncTimeoutException();

  @override
  String toString() => 'CloudSyncTimeoutException';
}

/// The exact local values captured before a settings upload, plus the merged
/// document returned by Firestore. Keeping the captured values lets callers
/// preserve a newer on-device edit made while the request was in flight.
class SettingsSyncResult {
  const SettingsSyncResult({
    required this.fields,
    required this.submitted,
  });

  final Map<String, dynamic> fields;
  final Map<String, Map<String, dynamic>> submitted;
}

/// The book changed on another device after this phone began its edit. The
/// caller must keep the local edit intact and show it as a conflict rather
/// than silently replacing either copy.
class ManagedBookConflictException implements Exception {
  const ManagedBookConflictException(this.bookId, this.expected, this.actual);

  final String bookId;
  final int expected;
  final int actual;

  @override
  String toString() =>
      'ManagedBookConflictException(book: $bookId, expected: $expected, actual: $actual)';
}

/// A compact, ordered server delta.  The monotonically increasing [number]
/// is the conflict order: later committed transactions win only for fields
/// they changed, while unrelated fields are merged.

class ManagedBookManifest {
  const ManagedBookManifest({
    required this.generation,
    required this.complete,
    required this.revisions,
  });

  final int generation;
  final bool complete;
  final Map<String, int> revisions;
}

Set<String> managedBookIdsNeedingDownload({
  required Map<String, int> localRevisions,
  required Map<String, int> remoteRevisions,
}) =>
    remoteRevisions.entries
        .where((entry) => localRevisions[entry.key] != entry.value)
        .map((entry) => entry.key)
        .toSet();

class CloudBookOverview {
  const CloudBookOverview({
    required this.id,
    required this.name,
    required this.wordCount,
    required this.isFavorite,
  });

  final String id;
  final String name;
  final int wordCount;
  final bool isFavorite;
}

class CloudActiveStudyOverview {
  const CloudActiveStudyOverview({
    required this.title,
    required this.memorized,
    required this.total,
    required this.remaining,
    required this.updatedAt,
  });

  final String title;
  final int memorized;
  final int total;
  final int remaining;
  final DateTime? updatedAt;

  double get progress => total <= 0 ? 0 : memorized / total;
}

class CloudBookArchiveOverview {
  const CloudBookArchiveOverview({
    required this.id,
    required this.bookId,
    required this.kind,
    required this.createdAt,
    required this.byteSize,
  });

  final String id;
  final String bookId;
  final String kind;
  final DateTime createdAt;
  final int byteSize;
}

class CloudBackupOverview {
  const CloudBackupOverview({
    required this.updatedAt,
    required this.books,
    required this.activeStudies,
    required this.completedSessionCount,
    required this.studyDayCount,
    required this.sessionSize,
    required this.targetName,
    required this.japaneseFont,
  });

  final DateTime? updatedAt;
  final List<CloudBookOverview> books;
  final List<CloudActiveStudyOverview> activeStudies;
  final int completedSessionCount;
  final int studyDayCount;
  final int sessionSize;
  final String targetName;
  final String japaneseFont;

  int get totalWords => books.fold(0, (total, book) => total + book.wordCount);
}

class CloudBackup {
  CloudBackup({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : auth = auth ?? FirebaseAuth.instance,
        firestore = firestore ?? FirebaseFirestore.instance,
        storage = storage ?? FirebaseStorage.instance;

  final FirebaseAuth auth;
  final FirebaseFirestore firestore;
  final FirebaseStorage storage;

  static const _operationTimeout = Duration(seconds: 90);
  // A stalled learning-state stream must not keep the coordinator locked.
  static const _learningStateOperationTimeout = Duration(seconds: 25);
  static const maxBookArchiveBytes = 100 * 1024 * 1024;

  Future<T> _runCloudOperation<T>(Future<T> Function() operation,
      {Duration? timeout}) async {
    try {
      return await operation().timeout(timeout ?? _operationTimeout);
    } on FirebaseException catch (error) {
      if (error.code == 'resource-exhausted') {
        throw const CloudQuotaExceededException();
      }
      rethrow;
    } on TimeoutException {
      throw const CloudSyncTimeoutException();
    }
  }

  User get _user {
    final current = auth.currentUser;
    if (current == null) {
      throw StateError('Google login is required.');
    }
    return current;
  }

  DocumentReference<Map<String, dynamic>> get _profileRef => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('profile')
      .doc('main');

  DocumentReference<Map<String, dynamic>> get _settingsRef => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('settings')
      .doc('main');

  CollectionReference<Map<String, dynamic>> get _booksRef =>
      firestore.collection('users').doc(_user.uid).collection('vocabBooks');

  /// Separate from vocabBooks/words. Learning progress never rewrites card
  /// documents, including their content and legacy study fields.
  CollectionReference<Map<String, dynamic>> get _learningStatesRef =>
      firestore.collection('users').doc(_user.uid).collection('learningState');

  CollectionReference<Map<String, dynamic>> get _syncV2Ref => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('learningStateV2');
  // Keep each sync channel on its own document. A shared document used to let
  // a book notification replace the device id attached to a learning
  // revision, which could make another phone ignore that revision.
  DocumentReference<Map<String, dynamic>> get _legacySyncSignal => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('syncSignals')
      .doc('main');
  DocumentReference<Map<String, dynamic>> get _learningSyncSignal => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('syncSignals')
      .doc('learning');
  DocumentReference<Map<String, dynamic>> get _managedBookSyncSignal =>
      firestore
          .collection('users')
          .doc(_user.uid)
          .collection('syncSignals')
          .doc('managedBookChanges');
  DocumentReference<Map<String, dynamic>> get _settingsSyncSignal => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('syncSignals')
      .doc('settings');
  DocumentReference<Map<String, dynamic>> get _managedBookManifest => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('syncSignals')
      .doc('managedBooks');
  final Map<String, Map<String, dynamic>> _syncPayloadCache = {};

  Stream<Map<String, dynamic>?> watchLegacySyncSignal() =>
      _legacySyncSignal.snapshots().map((event) => event.data());

  Stream<Map<String, dynamic>?> watchLearningSyncSignal() =>
      _learningSyncSignal.snapshots().map((event) => event.data());

  Stream<Map<String, dynamic>?> watchManagedBookSyncSignal() =>
      _managedBookSyncSignal.snapshots().map((event) => event.data());

  Stream<Map<String, dynamic>?> watchSettingsSyncSignal() =>
      _settingsSyncSignal.snapshots().map((event) => event.data());

  Future<void> publishSyncSignal(String deviceId, String revision) =>
      _learningSyncSignal.set({
        'deviceId': deviceId,
        'revision': revision,
        'updatedAt': FieldValue.serverTimestamp()
      });

  /// Imported/user-authored card content. This deliberately never writes the
  /// legacy vocabBooks/*/words documents.
  CollectionReference<Map<String, dynamic>> get _managedBooksRef =>
      firestore.collection('users').doc(_user.uid).collection('managedBooks');

  DocumentReference<Map<String, dynamic>> get _cardSyncMeta => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('cardSync')
      .doc('meta');

  CollectionReference<Map<String, dynamic>> get _cardBooksRef =>
      firestore.collection('users').doc(_user.uid).collection('cardBooks');

  DocumentReference<Map<String, dynamic>> get _cardBookSignal => firestore
      .collection('users')
      .doc(_user.uid)
      .collection('syncSignals')
      .doc('cardBookChanges');

  /// This flag is deliberately server-owned during migration.  New builds can
  /// be shipped before it flips, without a half-migrated phone ever treating
  /// an empty cardBooks collection as the source of truth.
  Future<bool> isCardSyncCutoverEnabled() => _runCloudOperation(() async {
        final snapshot = await _cardSyncMeta.get();
        return snapshot.data()?['cutover'] == true;
      });

  Stream<Map<String, dynamic>?> watchCardBookSyncSignal() =>
      _cardBookSignal.snapshots().map((event) => event.data());

  /// Applies one local operation exactly once.  The transaction reserves the
  /// next book change number, writes only edited fields, and creates an
  /// immutable record containing the prior values for recovery.
  Future<void> uploadCardChange(CardChange change,
          {required String deviceId}) =>
      _runCloudOperation(() async {
        final bookRef = _cardBooksRef.doc(change.bookId);
        final cardRef =
            bookRef.collection('cards').doc(change.wordId.toString());
        final operationRef = bookRef.collection('operations').doc(change.id);
        final signalRef = _cardBookSignal;
        await firestore.runTransaction((transaction) async {
          final operation = await transaction.get(operationRef);
          if (operation.exists) return;
          final book = await transaction.get(bookRef);
          if (!book.exists) {
            throw StateError('카드 동기화 단어장을 찾을 수 없습니다: ${change.bookId}');
          }
          final card = await transaction.get(cardRef);
          if (!card.exists) {
            throw StateError(
                '카드 동기화 카드를 찾을 수 없습니다: ${change.bookId}/${change.wordId}');
          }
          final previousCard = card.data() ?? const <String, dynamic>{};
          final previous = <String, dynamic>{
            for (final key in change.fields.keys) key: previousCard[key],
          };
          final bookData = book.data() ?? const <String, dynamic>{};
          final next = ((bookData['nextChange'] as num?)?.toInt() ?? 0) + 1;
          final fieldRevisions = <String, dynamic>{
            ...(previousCard['fieldRevisions'] as Map? ?? const {}),
            for (final key in change.fields.keys) key: next,
          };
          transaction.update(cardRef, {
            ...change.fields,
            'fieldRevisions': fieldRevisions,
            'updatedAt': FieldValue.serverTimestamp(),
            'lastOperationId': change.id,
          });
          transaction.update(bookRef, {
            'nextChange': next,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          final changeRef = bookRef
              .collection('changes')
              .doc(next.toString().padLeft(12, '0'));
          transaction.set(changeRef, {
            'schema': 1,
            'number': next,
            'kind': 'cardPatch',
            'wordId': change.wordId,
            'fields': change.fields,
            'before': previous,
            'operationId': change.id,
            'deviceId': deviceId,
            'localVersion': change.localVersion,
            'createdAt': FieldValue.serverTimestamp(),
          });
          transaction.set(operationRef, {
            'schema': 1,
            'operationId': change.id,
            'changeNumber': next,
            'wordId': change.wordId,
            'createdAt': FieldValue.serverTimestamp(),
          });
        });
        await signalRef.set({
          'deviceId': deviceId,
          'bookId': change.bookId,
          'operationId': change.id,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

  Future<Map<String, dynamic>?> downloadCard(String bookId, int wordId) =>
      _runCloudOperation(() async {
        final card = await _cardBooksRef
            .doc(bookId)
            .collection('cards')
            .doc(wordId.toString())
            .get(const GetOptions(source: Source.server));
        return card.data();
      });

  Future<List<CardBookSnapshot>> downloadCardBooks({
    Iterable<String>? ids,
  }) =>
      _runCloudOperation(() async {
        final List<DocumentSnapshot<Map<String, dynamic>>> parents;
        if (ids == null) {
          parents = (await _cardBooksRef.get()).docs;
        } else {
          parents = await Future.wait(
            ids.map((id) => _cardBooksRef.doc(id).get()),
          );
        }
        final result = <CardBookSnapshot>[];
        for (final parent in parents) {
          if (!parent.exists) continue;
          final data = parent.data()!;
          if (data['deleted'] == true) continue;
          final cards = await parent.reference.collection('cards').get();
          result.add(CardBookSnapshot(
            book: Map<String, dynamic>.from(data),
            cards: cards.docs
                .map((item) => Map<String, dynamic>.from(item.data()))
                .toList(growable: false),
            changeNumber: (data['nextChange'] as num?)?.toInt() ?? 0,
          ));
        }
        return result;
      });

  Future<List<Map<String, dynamic>>> downloadCardBookMetadata() =>
      _runCloudOperation(() async {
        final snapshot = await _cardBooksRef.get();
        return snapshot.docs
            .map((item) => Map<String, dynamic>.from(item.data()))
            .where((item) => item['deleted'] != true)
            .toList(growable: false);
      });

  Future<List<CardBookChange>> downloadCardChanges(
    String bookId,
    int after,
  ) =>
      _runCloudOperation(() async {
        final snapshot = await _cardBooksRef
            .doc(bookId)
            .collection('changes')
            .where('number', isGreaterThan: after)
            .orderBy('number')
            .get();
        return snapshot.docs
            .map((document) {
              final data = document.data();
              return CardBookChange(
                number: (data['number'] as num?)?.toInt() ?? 0,
                wordId: (data['wordId'] as num?)?.toInt() ?? 0,
                fields: Map<String, dynamic>.from(
                    data['fields'] as Map? ?? const {}),
                operationId: data['operationId']?.toString() ?? '',
              );
            })
            .where((item) => item.number > 0 && item.wordId != 0)
            .toList();
      });

  CollectionReference<Map<String, dynamic>> get _bookArchivesRef =>
      firestore.collection('users').doc(_user.uid).collection('bookArchives');

  /// Stores a recovery point in small chunks, avoiding Firestore's per-document
  /// size limit even for a large imported book. Existing card documents are
  /// never read or changed here.
  Future<void> uploadBookArchive(BookRestorePoint point) =>
      _runCloudOperation(() async {
        const chunkBytes = 350 * 1024;
        final bytes = point.utf8Bytes;
        final chunks = <String>[];
        for (var offset = 0; offset < bytes.length; offset += chunkBytes) {
          final end = offset + chunkBytes < bytes.length
              ? offset + chunkBytes
              : bytes.length;
          chunks.add(base64Encode(bytes.sublist(offset, end)));
        }
        final ref = _bookArchivesRef.doc(point.id);
        final existing = await ref.get();
        if (!existing.exists) {
          final current = await _bookArchivesRef.get();
          final used = current.docs.fold<int>(
            0,
            (sum, document) =>
                sum + ((document.data()['byteSize'] as num?)?.toInt() ?? 0),
          );
          if (used + bytes.length > maxBookArchiveBytes) {
            throw StateError(
                '복원 보관함 100MB 한도가 가득 찼습니다. 오래된 기록을 지운 뒤 다시 시도해 주세요.');
          }
        }
        await ref.set({
          'schema': 1,
          'id': point.id,
          'bookId': point.bookId,
          'kind': point.kind,
          'createdAt': point.createdAt.toUtc().toIso8601String(),
          'deviceId': point.deviceId,
          'byteSize': bytes.length,
          'chunkCount': chunks.length,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        var batch = firestore.batch();
        var count = 0;
        Future<void> commit() async {
          if (count == 0) return;
          await batch.commit();
          batch = firestore.batch();
          count = 0;
        }

        for (var index = 0; index < chunks.length; index++) {
          batch.set(
              ref.collection('chunks').doc(index.toString().padLeft(6, '0')),
              {'index': index, 'data': chunks[index]});
          count++;
          if (count >= 400) await commit();
        }
        await commit();
      });

  Future<List<Map<String, dynamic>>> downloadBookArchiveMetadata() =>
      _runCloudOperation(() async {
        final snapshot = await _bookArchivesRef.get();
        return snapshot.docs
            .map((doc) => Map<String, dynamic>.from(doc.data()))
            .toList(growable: false);
      });

  Future<List<CloudBookArchiveOverview>> listBookArchives() async {
    final rows = await downloadBookArchiveMetadata();
    final result = <CloudBookArchiveOverview>[];
    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      result.add(CloudBookArchiveOverview(
        id: id,
        bookId: row['bookId']?.toString() ?? '',
        kind: row['kind']?.toString() ?? 'revision',
        createdAt: DateTime.tryParse(row['createdAt']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        byteSize: (row['byteSize'] as num?)?.toInt() ?? 0,
      ));
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<int> bookArchiveBytes() async => (await listBookArchives())
      .fold<int>(0, (sum, archive) => sum + archive.byteSize);

  Future<BookRestorePoint?> downloadBookArchive(String id) =>
      _runCloudOperation(() async {
        final ref = _bookArchivesRef.doc(id);
        final metadata = await ref.get();
        if (!metadata.exists) return null;
        final chunks = await ref.collection('chunks').get();
        final rows = chunks.docs.map((doc) => doc.data()).toList()
          ..sort((a, b) => ((a['index'] as num?)?.toInt() ?? 0)
              .compareTo((b['index'] as num?)?.toInt() ?? 0));
        final bytes = <int>[];
        for (final row in rows) {
          final data = row['data'];
          if (data is String) bytes.addAll(base64Decode(data));
        }
        if (bytes.isEmpty) return null;
        return BookRestorePoint.fromJson(
            Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map));
      });

  Future<void> deleteBookArchive(String id) => _runCloudOperation(() async {
        final ref = _bookArchivesRef.doc(id);
        final chunks = await ref.collection('chunks').get();
        var batch = firestore.batch();
        var count = 0;
        Future<void> commit() async {
          if (count == 0) return;
          await batch.commit();
          batch = firestore.batch();
          count = 0;
        }

        for (final chunk in chunks.docs) {
          batch.delete(chunk.reference);
          count++;
          if (count >= 400) await commit();
        }
        batch.delete(ref);
        await commit();
      });

  Future<void> uploadManagedBooks(
          VocaStore store, CloudChangeSnapshot changes) =>
      _runCloudOperation(() async {
        final touched = <String>{
          ...changes.bookIds,
          ...changes.wordIdsByBook.keys,
          ...changes.deletedWordIdsByBook.keys,
          ...changes.deletedBookIds,
        }..remove('default');
        if (touched.isEmpty) return;
        final deviceId = await store.cloudChanges.deviceId();
        final byId = {for (final book in store.books) book.id: book};
        for (final id in touched) {
          final book = byId[id];
          final ref = _managedBooksRef.doc(id);
          final expected = changes.bookBaseRevisions[id] ?? 0;
          await firestore.runTransaction((transaction) async {
            final current = await transaction.get(ref);
            final currentManifest = await transaction.get(_managedBookManifest);
            final rawRevision = current.data()?['revision'];
            final actual = rawRevision is num ? rawRevision.toInt() : 0;
            if (actual != expected) {
              throw ManagedBookConflictException(id, expected, actual);
            }
            final nextRevision = actual + 1;
            transaction.set(
              ref,
              {
                'schema': 2,
                'id': id,
                'revision': nextRevision,
                'deleted': book == null,
                if (book != null) 'content': store.toManagedBookJson(book),
                'clientUpdatedAt': DateTime.now().toUtc().toIso8601String(),
                'updatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
            final manifestData = currentManifest.data();
            final revisions = _manifestRevisions(manifestData);
            revisions[id] = nextRevision;
            final nextGeneration =
                ((manifestData?['generation'] as num?)?.toInt() ?? 0) + 1;
            transaction.set(_managedBookManifest, {
              'schema': 1,
              'complete': manifestData?['complete'] == true,
              'generation': nextGeneration,
              'entries': _manifestEntries(revisions),
              'updatedAt': FieldValue.serverTimestamp(),
            });
            transaction.set(
              _managedBookSyncSignal,
              {
                'deviceId': deviceId,
                'bookRevision': nextGeneration,
                'updatedAt': FieldValue.serverTimestamp(),
              },
            );
          });
        }
      });

  Future<ManagedBookManifest?> downloadManagedBookManifest() =>
      _runCloudOperation(() async {
        final snapshot = await _managedBookManifest.get();
        final data = snapshot.data();
        if (!snapshot.exists || data == null) return null;
        return ManagedBookManifest(
          generation: (data['generation'] as num?)?.toInt() ?? 0,
          complete: data['complete'] == true,
          revisions: _manifestRevisions(data),
        );
      });

  Future<void> reconcileManagedBookManifest(
    Map<String, int> revisions, {
    required String deviceId,
  }) =>
      _runCloudOperation(() async {
        await firestore.runTransaction((transaction) async {
          final current = await transaction.get(_managedBookManifest);
          final data = current.data();
          final merged = Map<String, int>.of(revisions);
          for (final entry in _manifestRevisions(data).entries) {
            if ((merged[entry.key] ?? -1) < entry.value) {
              merged[entry.key] = entry.value;
            }
          }
          final unchanged = data?['complete'] == true &&
              mapEquals(_manifestRevisions(data), merged);
          var generation = (data?['generation'] as num?)?.toInt() ?? 0;
          if (!unchanged) {
            generation++;
            transaction.set(_managedBookManifest, {
              'schema': 1,
              'complete': true,
              'generation': generation,
              'entries': _manifestEntries(merged),
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
          transaction.set(
            _managedBookSyncSignal,
            {
              'deviceId': deviceId,
              'bookRevision': generation,
              'updatedAt': FieldValue.serverTimestamp(),
            },
          );
        });
      });

  Future<List<Map<String, dynamic>>> downloadManagedBooks() =>
      _runCloudOperation(() async {
        // Tombstones are data too. Filtering them out was the reason a book
        // deleted on one phone could remain visible on another phone.
        final snapshot = await _managedBooksRef.get();
        return snapshot.docs
            .map((doc) => Map<String, dynamic>.from(doc.data()))
            .toList(growable: false);
      });

  Future<List<Map<String, dynamic>>> downloadManagedBooksByIds(
          Iterable<String> ids) =>
      _runCloudOperation(() async {
        final documents = await Future.wait(
          ids.map((id) => _managedBooksRef.doc(id).get()),
        );
        return documents
            .where((document) => document.exists)
            .map((document) => <String, dynamic>{
                  ...document.data()!,
                  'id': document.data()!['id'] ?? document.id,
                })
            .toList(growable: false);
      });

  /// User-authored card relations live beside learningState, never inside
  /// vocabBooks/*/words. Existing card documents stay read-only.
  CollectionReference<Map<String, dynamic>> get _relationsRef =>
      firestore.collection('users').doc(_user.uid).collection('relations');

  Future<bool> hasLearningState() => _runCloudOperation(
      () async =>
          !(await _syncV2Ref.limit(1).get()).docs.isEmpty ||
          !(await _learningStatesRef.limit(1).get()).docs.isEmpty,
      timeout: _learningStateOperationTimeout);

  Future<void> uploadLearningState(
    VocaStore store,
    CloudChangeSnapshot changes,
  ) =>
      _runCloudOperation(() async {
        // Learning progress belongs exclusively to learningStateV2. The
        // legacy incremental writer targets the now read-only vocabBooks and
        // words collections; keeping it here made a permission failure there
        // abort the independent session upload before V2 was even captured.
        final deviceId = await store.cloudChanges.deviceId();
        final payload = await store.syncV2Snapshot();
        final bytes = await compute(_encodeSyncPayload, payload);
        final revision = sha256.convert(bytes).toString();
        final head = _syncV2Ref.doc(deviceId);
        final previous = await head.get();
        if (previous.data()?['revision'] == revision) return;
        final version = head.collection('versions').doc(revision);
        const chunkBytes = 256 * 1024;
        final chunkCount = (bytes.length / chunkBytes).ceil();
        for (var i = 0; i < chunkCount; i++) {
          final end = ((i + 1) * chunkBytes).clamp(0, bytes.length);
          await version.collection('chunks').doc('$i').set({
            'index': i,
            'data': base64Encode(bytes.sublist(i * chunkBytes, end)),
          });
        }
        final metadata = {
          'schema': 2,
          'deviceId': deviceId,
          'revision': revision,
          'chunkCount': chunkCount,
          'byteLength': bytes.length,
          'sequence': changes.learningStateGeneration,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        await version.set(metadata);
        // Publish only after every immutable chunk exists. A failed upload
        // leaves the previous complete version readable.
        final batch = firestore.batch();
        batch.set(head, metadata);
        batch.set(
          _learningSyncSignal,
          {
            'deviceId': deviceId,
            'revision': revision,
            'updatedAt': FieldValue.serverTimestamp()
          },
        );
        // Temporary compatibility signal for phones still running a build
        // from before the channels were split. Current builds do not use this
        // mixed document as their source of truth.
        batch.set(
          _legacySyncSignal,
          {
            'deviceId': deviceId,
            'revision': revision,
            'updatedAt': FieldValue.serverTimestamp()
          },
          SetOptions(merge: true),
        );
        await batch.commit();
      });

  Future<List<Map<String, dynamic>>> downloadLegacyLearningStates() =>
      _runCloudOperation(() async {
        final snapshot = await _learningStatesRef.get();
        return snapshot.docs
            .map((doc) => doc.data()['payload'])
            .whereType<Map>()
            .map((payload) => Map<String, dynamic>.from(payload))
            .toList();
      }, timeout: _learningStateOperationTimeout);

  Future<List<Map<String, dynamic>>> downloadLearningStates() =>
      _runCloudOperation(() async {
        final uid = _user.uid;
        final heads = await _syncV2Ref.get();
        if (heads.docs.isEmpty) return downloadLegacyLearningStates();
        final result = <Map<String, dynamic>>[];
        for (final doc in heads.docs) {
          final head = doc.data();
          final revision = head['revision'] as String;
          final key = '$uid/${doc.id}/$revision';
          var payload = _syncPayloadCache[key];
          if (payload == null) {
            final chunks = await doc.reference
                .collection('versions')
                .doc(revision)
                .collection('chunks')
                .get();
            final sorted = chunks.docs.map((d) => d.data()).toList()
              ..sort(
                  (a, b) => (a['index'] as int).compareTo(b['index'] as int));
            if (sorted.length != head['chunkCount'])
              throw StateError('동기화 조각이 누락되었습니다.');
            final bytes = <int>[];
            for (var i = 0; i < sorted.length; i++) {
              if (sorted[i]['index'] != i) throw StateError('동기화 조각 순서 오류');
              bytes.addAll(base64Decode(sorted[i]['data'] as String));
            }
            if (bytes.length != head['byteLength'] ||
                sha256.convert(bytes).toString() != revision) {
              throw StateError('동기화 데이터 검증 실패');
            }
            payload = await compute<List<int>, Map<String, dynamic>>(
                _decodeSyncPayload, bytes);
            _syncPayloadCache
                .removeWhere((old, _) => old.startsWith('$uid/${doc.id}/'));
            _syncPayloadCache[key] = payload;
          }
          result.add(payload);
        }
        return result;
      });

  Future<void> uploadRelation(Map<String, dynamic> relation) =>
      _runCloudOperation(() async {
        final id = relation['id'] as String?;
        if (id == null || id.isEmpty)
          throw ArgumentError('Missing relation id');
        await _relationsRef.doc(id).set({
          ...relation,
          'serverUpdatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });

  Future<List<Map<String, dynamic>>> downloadRelations() =>
      _runCloudOperation(() async {
        final snapshot = await _relationsRef.get();
        return snapshot.docs
            .map((document) => Map<String, dynamic>.from(document.data()))
            .toList(growable: false);
      });

  /// Uploads an explicitly user-requested local diagnostic archive. It never
  /// reads or writes profile or vocabBooks/words documents.
  Future<String> uploadDiagnosticArchive(Uint8List archive,
          {required String deviceId}) =>
      _runCloudOperation(() async {
        final stamp =
            DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
        final ref = storage.ref(
            'users/${_user.uid}/diagnostics/$deviceId/learning-state-$stamp.ndjson.gz');
        await ref.putData(
          archive,
          SettableMetadata(contentType: 'application/gzip'),
        );
        return ref.fullPath;
      });
  Future<bool> hasBackup() =>
      _runCloudOperation(() async => (await _profileRef.get()).exists);

  int _compareSettingsVersion(Map<String, dynamic> a, Map<String, dynamic> b) {
    final clock = ((a['updatedAtMicros'] as num?)?.toInt() ?? 0)
        .compareTo((b['updatedAtMicros'] as num?)?.toInt() ?? 0);
    return clock != 0
        ? clock
        : '${a['deviceId'] ?? ''}'.compareTo('${b['deviceId'] ?? ''}');
  }

  Map<String, dynamic> _legacySettingsFields(Map<String, dynamic> profile) {
    final updatedAt = profile['updatedAt'];
    final micros =
        updatedAt is Timestamp ? updatedAt.microsecondsSinceEpoch : 0;
    Map<String, dynamic> entry(dynamic value) => {
          'value': value,
          'updatedAtMicros': micros,
          'deviceId': 'legacy-profile',
        };
    final fields = <String, dynamic>{};
    void copy(String key, [dynamic value]) {
      final source = value ?? profile[key];
      if (source != null) fields[key] = entry(source);
    }

    for (final key in VocaStore.settingsPreferenceKeys) copy(key);
    final sizes = profile['cardFontSizes'];
    if (sizes is Map) {
      for (final key in const [
        'termFontSize',
        'readingFontSize',
        'meaningFontSize',
        'exampleFontSize',
        'exampleMeaningFontSize',
      ]) {
        final legacyKey = switch (key) {
          'termFontSize' => 'term',
          'readingFontSize' => 'reading',
          'meaningFontSize' => 'meaning',
          'exampleFontSize' => 'example',
          _ => 'exampleMeaning',
        };
        if (sizes[legacyKey] != null) copy(key, sizes[legacyKey]);
      }
    }
    final style = profile['cardMeaningStyle'];
    if (style is Map) {
      copy('meaningFontWeight', style['fontWeight']);
      copy('meaningOpacity', style['opacity']);
    }
    final dictionary = profile['openDictionaryInAppSetting'];
    if (dictionary is Map) copy('openDictionaryInApp', dictionary['value']);
    return fields;
  }

  Future<Map<String, dynamic>> _loadOrMigrateSettings() async {
    final existing = await _settingsRef.get();
    if (existing.exists) return existing.data()!;
    final legacy = await _profileRef.get();
    final seed = legacy.exists ? _legacySettingsFields(legacy.data()!) : {};
    await firestore.runTransaction((transaction) async {
      final current = await transaction.get(_settingsRef);
      if (current.exists) return;
      transaction.set(_settingsRef, {
        'schema': 1,
        'fields': seed,
        'migratedFromProfile': legacy.exists,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
    return (await _settingsRef.get()).data() ?? {'schema': 1, 'fields': seed};
  }

  /// Merges only changed preference fields. It never reads or writes card,
  /// vocabulary, session, or learning-state documents.
  Future<SettingsSyncResult> syncSettings(
    Map<String, Map<String, dynamic>> local,
  ) =>
      _runCloudOperation(() async {
        final document = await _loadOrMigrateSettings();
        final remote =
            Map<String, dynamic>.from(document['fields'] as Map? ?? {});
        final outgoing = <String, dynamic>{};
        final resolved = <String, dynamic>{...remote};
        for (final entry in local.entries) {
          final remoteEntry = remote[entry.key];
          if (remoteEntry is! Map ||
              _compareSettingsVersion(
                      entry.value, Map<String, dynamic>.from(remoteEntry)) >=
                  0) {
            outgoing[entry.key] = entry.value;
            resolved[entry.key] = entry.value;
          }
        }
        if (outgoing.isNotEmpty) {
          final deviceIds = outgoing.values
              .whereType<Map>()
              .map((value) => '${value['deviceId'] ?? ''}')
              .where((value) => value.isNotEmpty)
              .toSet();
          final batch = firestore.batch();
          batch.set(
              _settingsRef,
              {
                'schema': 1,
                'fields': outgoing,
                'updatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true));
          batch.set(_settingsSyncSignal, {
            'deviceId': deviceIds.length == 1 ? deviceIds.single : '',
            'revision': outgoing.values
                .whereType<Map>()
                .map(
                    (value) => (value['updatedAtMicros'] as num?)?.toInt() ?? 0)
                .fold<int>(
                    0, (latest, value) => value > latest ? value : latest),
            'updatedAt': FieldValue.serverTimestamp(),
          });
          await batch.commit();
        }
        return SettingsSyncResult(fields: resolved, submitted: local);
      });

  Future<void> uploadIncremental(
    VocaStore store,
    CloudChangeSnapshot changes, {
    bool forceProfile = false,
  }) =>
      uploadLearningState(store, changes);

  Future<void> upload(VocaStore store) async {
    await store.cloudChanges.markLearningState();
    await uploadLearningState(store, store.cloudChanges.snapshot);
  }

  Future<Map<String, dynamic>> downloadBackupJson() =>
      _runCloudOperation(_downloadBackupJson);

  Future<Map<String, dynamic>> _downloadBackupJson() async {
    final profile = await _profileRef.get();
    if (!profile.exists) {
      throw StateError('No cloud backup found.');
    }

    final profileData = profile.data()!;
    final booksSnapshot = await _booksRef.orderBy('order').get();
    final books = <Map<String, dynamic>>[];

    for (final bookDoc in booksSnapshot.docs) {
      final bookData = bookDoc.data();
      final wordsSnapshot =
          await bookDoc.reference.collection('words').orderBy('order').get();
      books.add({
        'id': bookData['id'] as String? ?? bookDoc.id,
        'name': bookData['name'] as String? ?? '',
        'isFavorite': bookData['isFavorite'] as bool? ?? false,
        'sessionOverrides': bookData['sessionOverrides'] ?? <String, dynamic>{},
        'words': wordsSnapshot.docs
            .map((wordDoc) => _wordData(wordDoc.data()))
            .toList(),
      });
    }

    return {
      'version': profileData['version'] as int? ?? 1,
      'rangeCourseSchema': profileData['rangeCourseSchema'] as int? ?? 1,
      'rangeCoursePasses':
          profileData['rangeCoursePasses'] as Map<String, dynamic>? ?? {},
      'books': books,
      'quickBook': profileData['quickBook'] as String? ?? 'default',
      'sessionSize': profileData['sessionSize'] as int? ?? 10,
      'completed': profileData['completed'] as List<dynamic>? ?? <String>[],
      'completedAt': profileData['completedAt'] as Map<String, dynamic>? ?? {},
      'studyDays': profileData['studyDays'] as List<dynamic>? ?? <String>[],
      'dailyStudyStats':
          profileData['dailyStudyStats'] as Map<String, dynamic>? ?? {},
      'studyEventLog':
          profileData['studyEventLog'] as List<dynamic>? ?? <dynamic>[],
      'targetName': profileData['targetName'] as String? ?? '',
      'targetDate': profileData['targetDate'] as String?,
      'horizontalSwipe': profileData['horizontalSwipe'] as bool? ?? false,
      'reverseSwipe': profileData['reverseSwipe'] as bool? ?? false,
      'readingAboveTerm': profileData['readingAboveTerm'] as bool? ?? false,
      'showExamples': profileData['showExamples'] as bool? ?? true,
      'flipCard': profileData['flipCard'] as bool? ?? false,
      'autoPlayPronunciation':
          profileData['autoPlayPronunciation'] as bool? ?? true,
      'japaneseFont': profileData['japaneseFont'] as String? ?? 'system',
      'cardFontSizes': profileData['cardFontSizes'] as Map<String, dynamic>? ??
          <String, dynamic>{},
      'cardMeaningStyle':
          profileData['cardMeaningStyle'] as Map<String, dynamic>? ??
              <String, dynamic>{},
      'chatGptConversationUrl':
          profileData['chatGptConversationUrl'] as String? ?? '',
      'openDictionaryInAppSetting': _validDictionaryOpenSetting(
          profileData['openDictionaryInAppSetting']),
      'activeStudy': profileData['activeStudy'] as Map<String, dynamic>?,
      'activeStudies':
          profileData['activeStudies'] as Map<String, dynamic>? ?? {},
      'activeStudyTombstones':
          profileData['activeStudyTombstones'] as Map<String, dynamic>? ?? {},
      'resetMarkers':
          profileData['resetMarkers'] as Map<String, dynamic>? ?? {},
    };
  }

  Future<CloudBackupOverview> loadOverview() async {
    final profile = await _profileRef.get();
    if (!profile.exists) {
      throw StateError('No cloud backup found.');
    }
    final profileData = profile.data()!;
    final booksSnapshot = await _booksRef.orderBy('order').get();
    final books = booksSnapshot.docs.map((document) {
      final data = document.data();
      return CloudBookOverview(
        id: document.id,
        name: data['name'] as String? ?? '',
        wordCount: (data['wordCount'] as num?)?.toInt() ?? 0,
        isFavorite: data['isFavorite'] as bool? ?? false,
      );
    }).toList();
    final booksById = {for (final book in books) book.id: book};
    final activeStudyItems = <Map<String, dynamic>>[];
    final activeStudies =
        profileData['activeStudies'] as Map<String, dynamic>? ?? const {};
    for (final value in activeStudies.values) {
      if (value is Map<String, dynamic>) activeStudyItems.add(value);
    }
    final legacyActive = profileData['activeStudy'];
    if (activeStudyItems.isEmpty && legacyActive is Map<String, dynamic>) {
      activeStudyItems.add(legacyActive);
    }
    return CloudBackupOverview(
      updatedAt: (profileData['updatedAt'] as Timestamp?)?.toDate(),
      books: books,
      activeStudies: activeStudyItems
          .map((data) => _activeStudyOverview(
                data,
                booksById,
                profileData['sessionSize'] as int? ?? 10,
              ))
          .whereType<CloudActiveStudyOverview>()
          .toList(),
      completedSessionCount:
          (profileData['completed'] as List<dynamic>? ?? []).length,
      studyDayCount: (profileData['studyDays'] as List<dynamic>? ?? []).length,
      sessionSize: profileData['sessionSize'] as int? ?? 10,
      targetName: profileData['targetName'] as String? ?? '',
      japaneseFont: profileData['japaneseFont'] as String? ?? 'system',
    );
  }

  CloudActiveStudyOverview? _activeStudyOverview(
    Map<String, dynamic> data,
    Map<String, CloudBookOverview> booksById,
    int sessionSize,
  ) {
    final total = (data['total'] as num?)?.toInt() ?? 0;
    if (total <= 0) return null;
    final memorized = (data['memorized'] as num?)?.toInt() ?? 0;
    final queueIds = data['queueIds'] as List<dynamic>? ?? const [];
    final selections = (data['sessionSelections'] as Map<String, dynamic>?)
            ?.map((key, value) => MapEntry(
                  key,
                  (value as List<dynamic>? ?? const [])
                      .map((item) => (item as num).toInt())
                      .toList(),
                )) ??
        const <String, List<int>>{};
    final bookId = data['bookId'] as String?;
    final sessionIndexes =
        (data['sessionIndexes'] as List<dynamic>? ?? const [])
            .map((item) => (item as num).toInt())
            .toList();
    final title = _activeStudyTitle(
      selections.isNotEmpty
          ? selections
          : bookId == null
              ? const <String, List<int>>{}
              : {bookId: sessionIndexes},
      booksById,
      sessionSize,
    );
    return CloudActiveStudyOverview(
      title: title,
      memorized: memorized,
      total: total,
      remaining: queueIds.length,
      updatedAt: DateTime.tryParse(data['updatedAt'] as String? ?? ''),
    );
  }

  String _activeStudyTitle(
    Map<String, List<int>> selections,
    Map<String, CloudBookOverview> booksById,
    int sessionSize,
  ) {
    if (selections.length == 1 && selections.values.first.length == 1) {
      final bookId = selections.keys.first;
      final book = booksById[bookId];
      final index = selections.values.first.first;
      final start = index * sessionSize + 1;
      final end = book == null
          ? (index + 1) * sessionSize
          : start + sessionSize - 1 > book.wordCount
              ? book.wordCount
              : start + sessionSize - 1;
      return '${book?.name ?? '단어장'} · 단어 $start~$end';
    }
    final count = selections.values
        .fold<int>(0, (total, indexes) => total + indexes.length);
    return count <= 1 ? '진행 중인 학습' : '여러 세션 학습 · $count개 세션';
  }

  Map<String, dynamic> _wordData(Map<String, dynamic> data) => {
        'id': data['id'],
        'term': data['term'] as String? ?? '',
        'meaning': data['meaning'] as String? ?? '',
        'reading': data['reading'] as String? ?? '',
        'example': data['example'] as String? ?? '',
        'exampleMeaning': data['exampleMeaning'] as String? ?? '',
        'explanation': data['explanation'] as String? ?? '',
        'state': data['state'] as String? ?? StudyState.fresh.name,
        'correctCount': (data['correctCount'] as num?)?.toInt() ?? 0,
        'wrongCount': (data['wrongCount'] as num?)?.toInt() ?? 0,
        'lastStudiedAt': data['lastStudiedAt'] as String?,
        'lastWrongAt': data['lastWrongAt'] as String?,
        'isFavorite': data['isFavorite'] as bool? ?? false,
        'favoriteUpdatedAt': data['favoriteUpdatedAt'] as String?,
      };

  Map<String, dynamic>? _validDictionaryOpenSetting(dynamic raw) {
    if (raw is! Map) return null;
    final setting = Map<String, dynamic>.from(raw);
    final value = setting['value'];
    final updatedAt = setting['updatedAt'];
    if (value is! bool || updatedAt is! String) return null;
    final parsed = DateTime.tryParse(updatedAt)?.toUtc();
    if (parsed == null) return null;
    return {'value': value, 'updatedAt': parsed.toIso8601String()};
  }
}
