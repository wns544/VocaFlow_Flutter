import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'models.dart';
import 'store.dart';

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

  Future<void> upload(VocaStore store) async {
    final backup = store.toBackupJson();
    await _profileRef.set({
      'version': backup['version'],
      'quickBook': backup['quickBook'],
      'sessionSize': backup['sessionSize'],
      'completed': backup['completed'],
      'studyDays': backup['studyDays'],
      'targetName': backup['targetName'],
      'targetDate': backup['targetDate'],
      'horizontalSwipe': backup['horizontalSwipe'],
      'reverseSwipe': backup['reverseSwipe'],
      'bookOrder': store.books.map((book) => book.id).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

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
    };
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
}
