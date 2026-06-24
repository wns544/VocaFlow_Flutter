import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'cloud_change_tracker.dart';
import 'models.dart';
import 'store.dart';

class CloudBookOverview {
  const CloudBookOverview({
    required this.name,
    required this.wordCount,
    required this.isFavorite,
  });

  final String name;
  final int wordCount;
  final bool isFavorite;
}

class CloudBackupOverview {
  const CloudBackupOverview({
    required this.updatedAt,
    required this.books,
    required this.completedSessionCount,
    required this.studyDayCount,
    required this.sessionSize,
    required this.targetName,
    required this.japaneseFont,
  });

  final DateTime? updatedAt;
  final List<CloudBookOverview> books;
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
  })  : auth = auth ?? FirebaseAuth.instance,
        firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth auth;
  final FirebaseFirestore firestore;

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

  Future<bool> hasBackup() async => (await _profileRef.get()).exists;

  Future<void> uploadIncremental(
      VocaStore store, CloudChangeSnapshot changes) async {
    if (changes.isEmpty) return;
    final backup = store.toBackupJson();
    if (changes.profileDirty) {
      await _profileRef.set(_profileData(store, backup));
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

  Future<void> upload(VocaStore store) async {
    final backup = store.toBackupJson();
    final remoteBooks = await _booksRef.get();
    await _profileRef.set(_profileData(store, backup));

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

  Future<Map<String, dynamic>> downloadBackupJson() async {
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
      'books': books,
      'quickBook': profileData['quickBook'] as String? ?? 'default',
      'sessionSize': profileData['sessionSize'] as int? ?? 10,
      'completed': profileData['completed'] as List<dynamic>? ?? <String>[],
      'studyDays': profileData['studyDays'] as List<dynamic>? ?? <String>[],
      'targetName': profileData['targetName'] as String? ?? '',
      'targetDate': profileData['targetDate'] as String?,
      'horizontalSwipe': profileData['horizontalSwipe'] as bool? ?? false,
      'reverseSwipe': profileData['reverseSwipe'] as bool? ?? false,
      'readingAboveTerm': profileData['readingAboveTerm'] as bool? ?? false,
      'showExamples': profileData['showExamples'] as bool? ?? true,
      'flipCard': profileData['flipCard'] as bool? ?? false,
      'japaneseFont': profileData['japaneseFont'] as String? ?? 'system',
      'cardFontSizes': profileData['cardFontSizes'] as Map<String, dynamic>? ??
          <String, dynamic>{},
      'cardMeaningStyle':
          profileData['cardMeaningStyle'] as Map<String, dynamic>? ??
              <String, dynamic>{},
      'activeStudy':
          profileData['activeStudy'] as Map<String, dynamic>? ?? null,
    };
  }

  Future<CloudBackupOverview> loadOverview() async {
    final profile = await _profileRef.get();
    if (!profile.exists) {
      throw StateError('No cloud backup found.');
    }
    final profileData = profile.data()!;
    final booksSnapshot = await _booksRef.orderBy('order').get();
    return CloudBackupOverview(
      updatedAt: (profileData['updatedAt'] as Timestamp?)?.toDate(),
      books: booksSnapshot.docs.map((document) {
        final data = document.data();
        return CloudBookOverview(
          name: data['name'] as String? ?? '',
          wordCount: (data['wordCount'] as num?)?.toInt() ?? 0,
          isFavorite: data['isFavorite'] as bool? ?? false,
        );
      }).toList(),
      completedSessionCount:
          (profileData['completed'] as List<dynamic>? ?? []).length,
      studyDayCount: (profileData['studyDays'] as List<dynamic>? ?? []).length,
      sessionSize: profileData['sessionSize'] as int? ?? 10,
      targetName: profileData['targetName'] as String? ?? '',
      japaneseFont: profileData['japaneseFont'] as String? ?? 'system',
    );
  }

  Map<String, dynamic> _wordData(Map<String, dynamic> data) => {
        'id': data['id'],
        'term': data['term'] as String? ?? '',
        'meaning': data['meaning'] as String? ?? '',
        'reading': data['reading'] as String? ?? '',
        'example': data['example'] as String? ?? '',
        'exampleMeaning': data['exampleMeaning'] as String? ?? '',
        'state': data['state'] as String? ?? StudyState.fresh.name,
      };

  Map<String, dynamic> _profileData(
          VocaStore store, Map<String, dynamic> backup) =>
      {
        'version': backup['version'],
        'quickBook': backup['quickBook'],
        'sessionSize': backup['sessionSize'],
        'completed': backup['completed'],
        'studyDays': backup['studyDays'],
        'targetName': backup['targetName'],
        'targetDate': backup['targetDate'],
        'horizontalSwipe': backup['horizontalSwipe'],
        'reverseSwipe': backup['reverseSwipe'],
        'readingAboveTerm': backup['readingAboveTerm'],
        'showExamples': backup['showExamples'],
        'flipCard': backup['flipCard'],
        'japaneseFont': backup['japaneseFont'],
        'cardFontSizes': backup['cardFontSizes'],
        'cardMeaningStyle': backup['cardMeaningStyle'],
        'activeStudy': backup['activeStudy'],
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
