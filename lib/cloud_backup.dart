import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'cloud_change_tracker.dart';
import 'models.dart';
import 'store.dart';

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

  CollectionReference<Map<String, dynamic>> get _booksRef =>
      firestore.collection('users').doc(_user.uid).collection('vocabBooks');

  /// Separate from vocabBooks/words. Learning progress never rewrites card
  /// documents, including their content and legacy study fields.
  CollectionReference<Map<String, dynamic>> get _learningStatesRef =>
      firestore.collection('users').doc(_user.uid).collection('learningState');

  /// Imported/user-authored card content. This deliberately never writes the
  /// legacy vocabBooks/*/words documents.
  CollectionReference<Map<String, dynamic>> get _managedBooksRef =>
      firestore.collection('users').doc(_user.uid).collection('managedBooks');

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
        final byId = {for (final book in store.books) book.id: book};
        var batch = firestore.batch();
        var count = 0;
        Future<void> commit() async {
          if (count == 0) return;
          await batch.commit();
          batch = firestore.batch();
          count = 0;
        }

        for (final id in touched) {
          final book = byId[id];
          final ref = _managedBooksRef.doc(id);
          if (book == null) {
            batch.set(
                ref,
                {
                  'schema': 1,
                  'id': id,
                  'deleted': true,
                  'clientUpdatedAt': DateTime.now().toUtc().toIso8601String(),
                  'updatedAt': FieldValue.serverTimestamp(),
                },
                SetOptions(merge: true));
          } else {
            batch.set(
                ref,
                {
                  'schema': 1,
                  'id': id,
                  'deleted': false,
                  'content': store.toManagedBookJson(book),
                  'clientUpdatedAt': DateTime.now().toUtc().toIso8601String(),
                  'updatedAt': FieldValue.serverTimestamp(),
                },
                SetOptions(merge: true));
          }
          count++;
          if (count >= 400) await commit();
        }
        await commit();
      });

  Future<List<Map<String, dynamic>>> downloadManagedBooks() =>
      _runCloudOperation(() async {
        final snapshot =
            await _managedBooksRef.where('deleted', isEqualTo: false).get();
        return snapshot.docs
            .map((doc) => Map<String, dynamic>.from(doc.data()))
            .toList(growable: false);
      });

  /// User-authored card relations live beside learningState, never inside
  /// vocabBooks/*/words. Existing card documents stay read-only.
  CollectionReference<Map<String, dynamic>> get _relationsRef =>
      firestore.collection('users').doc(_user.uid).collection('relations');

  Future<bool> hasLearningState() => _runCloudOperation(
      () async => !(await _learningStatesRef.limit(1).get()).docs.isEmpty,
      timeout: _learningStateOperationTimeout);

  Future<void> uploadLearningState(
    VocaStore store,
    CloudChangeSnapshot changes,
  ) =>
      _runCloudOperation(() async {
        final deviceId = await store.cloudChanges.deviceId();
        await _learningStatesRef.doc(deviceId).set({
          'schema': 1,
          'deviceId': deviceId,
          'sequence': changes.learningStateGeneration,
          'clientUpdatedAt': DateTime.now().toUtc().toIso8601String(),
          'updatedAt': FieldValue.serverTimestamp(),
          'payload': store.toLearningStateJson(),
        }, SetOptions(merge: true));
      }, timeout: _learningStateOperationTimeout);

  Future<List<Map<String, dynamic>>> downloadLearningStates() =>
      _runCloudOperation(() async {
        final snapshot = await _learningStatesRef.get();
        return snapshot.docs
            .map((doc) => doc.data()['payload'])
            .whereType<Map>()
            .map((payload) => Map<String, dynamic>.from(payload))
            .toList();
      }, timeout: _learningStateOperationTimeout);

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

  Future<void> uploadIncremental(
    VocaStore store,
    CloudChangeSnapshot changes, {
    bool forceProfile = false,
  }) =>
      _runCloudOperation(
        () => _uploadIncremental(store, changes, forceProfile: forceProfile),
      );

  Future<void> _uploadIncremental(
    VocaStore store,
    CloudChangeSnapshot changes, {
    required bool forceProfile,
  }) async {
    if (changes.isEmpty && !forceProfile) return;
    final backup = store.toBackupJson();
    if (changes.profileDirty || forceProfile) {
      await _profileRef.set(
        _profileData(store, backup),
        SetOptions(merge: true),
      );
    }
    if (changes.dictionaryOpenSettingDirty) {
      await _syncDictionaryOpenSetting(store);
    }

    var operationCount = 0;
    var batch = firestore.batch();
    Future<void> commitIfNeeded({bool force = false}) async {
      if (operationCount == 0 || (!force && operationCount < 450)) return;
      await batch.commit();
      batch = firestore.batch();
      operationCount = 0;
    }

    final booksById = {for (final book in store.books) book.id: book};
    for (final bookId in changes.bookIds) {
      final book = booksById[bookId];
      if (book == null) continue;
      batch.set(_booksRef.doc(book.id), _bookData(store, book));
      operationCount++;
      await commitIfNeeded();
    }

    for (final entry in changes.wordIdsByBook.entries) {
      final book = booksById[entry.key];
      if (book == null) continue;
      final wordsById = {for (final word in book.words) word.id: word};
      for (final wordId in entry.value) {
        final word = wordsById[wordId];
        if (word == null) continue;
        batch.set(
          _booksRef.doc(book.id).collection('words').doc(word.id.toString()),
          {
            ...word.toJson(),
            'order': book.words.indexOf(word),
            'updatedAt': FieldValue.serverTimestamp(),
          },
        );
        operationCount++;
        await commitIfNeeded();
      }
    }

    for (final entry in changes.deletedWordIdsByBook.entries) {
      for (final wordId in entry.value) {
        batch.delete(
            _booksRef.doc(entry.key).collection('words').doc('$wordId'));
        operationCount++;
        await commitIfNeeded();
      }
    }
    for (final bookId in changes.deletedBookIds) {
      batch.delete(_booksRef.doc(bookId));
      operationCount++;
      await commitIfNeeded();
    }
    await commitIfNeeded(force: true);
  }

  Future<void> upload(VocaStore store) =>
      _runCloudOperation(() => _upload(store));

  Future<void> _upload(VocaStore store) async {
    final backup = store.toBackupJson();
    final remoteBooks = await _booksRef.get();
    await _profileRef.set(
      _profileData(store, backup),
      SetOptions(merge: true),
    );
    await _syncDictionaryOpenSetting(store);

    var operationCount = 0;
    var batch = firestore.batch();
    Future<void> commitIfNeeded({bool force = false}) async {
      if (operationCount == 0 || (!force && operationCount < 450)) return;
      await batch.commit();
      batch = firestore.batch();
      operationCount = 0;
    }

    for (var bookIndex = 0; bookIndex < store.books.length; bookIndex++) {
      final book = store.books[bookIndex];
      final bookRef = _booksRef.doc(book.id);
      final remoteWords = await bookRef.collection('words').get();
      final localWordIds = book.words.map((word) => word.id.toString()).toSet();
      batch.set(bookRef, {
        'id': book.id,
        'name': book.name,
        'isFavorite': book.isFavorite,
        'order': bookIndex,
        'sessionOverrides': book.sessionOverrides.map(
          (key, value) => MapEntry(key.toString(), value.toJson()),
        ),
        'wordCount': book.words.length,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      operationCount++;

      for (var wordIndex = 0; wordIndex < book.words.length; wordIndex++) {
        final word = book.words[wordIndex];
        batch.set(bookRef.collection('words').doc(word.id.toString()), {
          ...word.toJson(),
          'order': wordIndex,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        operationCount++;
        await commitIfNeeded();
      }
      for (final remoteWord in remoteWords.docs) {
        if (localWordIds.contains(remoteWord.id)) continue;
        batch.delete(remoteWord.reference);
        operationCount++;
        await commitIfNeeded();
      }
      await commitIfNeeded();
    }

    final localBookIds = store.books.map((book) => book.id).toSet();
    for (final remoteBook in remoteBooks.docs) {
      if (localBookIds.contains(remoteBook.id)) continue;
      final remoteWords = await remoteBook.reference.collection('words').get();
      for (final remoteWord in remoteWords.docs) {
        batch.delete(remoteWord.reference);
        operationCount++;
        await commitIfNeeded();
      }
      batch.delete(remoteBook.reference);
      operationCount++;
      await commitIfNeeded();
    }
    await commitIfNeeded(force: true);
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

  Future<void> _syncDictionaryOpenSetting(VocaStore store) async {
    final local = store.openDictionaryInAppSettingJson;
    if (local == null) return;
    final localUpdatedAt = _dictionaryOpenSettingUpdatedAt(local);
    if (localUpdatedAt == null) return;

    Map<String, dynamic>? newerRemote;
    await firestore.runTransaction<void>((transaction) async {
      final snapshot = await transaction.get(_profileRef);
      final remote = _validDictionaryOpenSetting(
        snapshot.data()?['openDictionaryInAppSetting'],
      );
      final remoteUpdatedAt =
          remote == null ? null : _dictionaryOpenSettingUpdatedAt(remote);
      if (remote != null &&
          remoteUpdatedAt != null &&
          remoteUpdatedAt.isAfter(localUpdatedAt)) {
        newerRemote = remote;
        return;
      }
      if (remoteUpdatedAt != null && remoteUpdatedAt == localUpdatedAt) return;
      transaction.set(
        _profileRef,
        {'openDictionaryInAppSetting': local},
        SetOptions(merge: true),
      );
    });
    if (newerRemote != null) {
      await store.applyOpenDictionaryInAppSettingFromCloud(newerRemote!);
    }
  }

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

  DateTime? _dictionaryOpenSettingUpdatedAt(Map<String, dynamic> setting) {
    final raw = setting['updatedAt'];
    return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
  }

  Map<String, dynamic> _profileData(
          VocaStore store, Map<String, dynamic> backup) =>
      {
        'version': backup['version'],
        'rangeCourseSchema': backup['rangeCourseSchema'],
        'rangeCoursePasses': backup['rangeCoursePasses'],
        'quickBook': backup['quickBook'],
        'sessionSize': backup['sessionSize'],
        'completed': backup['completed'],
        'completedAt': backup['completedAt'],
        'studyDays': backup['studyDays'],
        'dailyStudyStats': backup['dailyStudyStats'],
        'studyEventLog': backup['studyEventLog'],
        'targetName': backup['targetName'],
        'targetDate': backup['targetDate'],
        'horizontalSwipe': backup['horizontalSwipe'],
        'reverseSwipe': backup['reverseSwipe'],
        'readingAboveTerm': backup['readingAboveTerm'],
        'showExamples': backup['showExamples'],
        'flipCard': backup['flipCard'],
        'autoPlayPronunciation': backup['autoPlayPronunciation'],
        'japaneseFont': backup['japaneseFont'],
        'cardFontSizes': backup['cardFontSizes'],
        'cardMeaningStyle': backup['cardMeaningStyle'],
        'chatGptConversationUrl': backup['chatGptConversationUrl'],
        'activeStudy': backup['activeStudy'],
        'activeStudies': backup['activeStudies'],
        'activeStudyTombstones': backup['activeStudyTombstones'],
        'resetMarkers': backup['resetMarkers'],
        'bookOrder': store.books.map((book) => book.id).toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

  Map<String, dynamic> _bookData(VocaStore store, WordBook book) => {
        'id': book.id,
        'name': book.name,
        'isFavorite': book.isFavorite,
        'order': store.books.indexOf(book),
        'sessionOverrides': book.sessionOverrides.map(
          (key, value) => MapEntry(key.toString(), value.toJson()),
        ),
        'wordCount': book.words.length,
        'updatedAt': FieldValue.serverTimestamp(),
      };
}
