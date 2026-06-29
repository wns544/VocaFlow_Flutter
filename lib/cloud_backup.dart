import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'cloud_change_tracker.dart';
import 'models.dart';
import 'store.dart';

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
      'japaneseFont': profileData['japaneseFont'] as String? ?? 'system',
      'cardFontSizes': profileData['cardFontSizes'] as Map<String, dynamic>? ??
          <String, dynamic>{},
      'cardMeaningStyle':
          profileData['cardMeaningStyle'] as Map<String, dynamic>? ??
              <String, dynamic>{},
      'chatGptConversationUrl':
          profileData['chatGptConversationUrl'] as String? ?? '',
      'activeStudy': profileData['activeStudy'] as Map<String, dynamic>?,
      'activeStudies':
          profileData['activeStudies'] as Map<String, dynamic>? ?? {},
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
        'state': data['state'] as String? ?? StudyState.fresh.name,
        'correctCount': (data['correctCount'] as num?)?.toInt() ?? 0,
        'wrongCount': (data['wrongCount'] as num?)?.toInt() ?? 0,
        'lastStudiedAt': data['lastStudiedAt'] as String?,
        'lastWrongAt': data['lastWrongAt'] as String?,
      };

  Map<String, dynamic> _profileData(
          VocaStore store, Map<String, dynamic> backup) =>
      {
        'version': backup['version'],
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
        'japaneseFont': backup['japaneseFont'],
        'cardFontSizes': backup['cardFontSizes'],
        'cardMeaningStyle': backup['cardMeaningStyle'],
        'chatGptConversationUrl': backup['chatGptConversationUrl'],
        'activeStudy': backup['activeStudy'],
        'activeStudies': backup['activeStudies'],
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
