import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/backup_merge.dart';
import 'package:vocaflow/cloud_change_tracker.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('incremental snapshot includes only changed documents', () async {
    final tracker = await CloudChangeTracker.load();

    await tracker.markProfile();
    await tracker.markWord('book-a', 2);
    await tracker.markBook('book-b');

    final snapshot = tracker.snapshot;
    expect(snapshot.profileDirty, isTrue);
    expect(snapshot.bookIds, {'book-b'});
    expect(snapshot.wordIdsByBook, {
      'book-a': {2}
    });
    expect(snapshot.wordIdsByBook['book-a'], isNot(contains(1)));
  });

  test('fifty studied words remain one profile plus fifty word writes',
      () async {
    final words = List.generate(
      50,
      (index) => Word(
        id: index + 1,
        term: 'term$index',
        reading: '',
        meaning: 'meaning$index',
      ),
    );
    SharedPreferences.setMockInitialValues({
      'books': jsonEncode([
        WordBook(id: 'book', name: 'Book', words: words).toJson(),
      ]),
    });
    final store = await VocaStore.load();

    for (final word in store.books.single.words) {
      await store.mark(word, StudyState.memorized);
    }
    await store.completeSessions('book', [0]);

    final snapshot = store.cloudChanges.snapshot;
    expect(snapshot.profileDirty, isTrue);
    expect(snapshot.wordIdsByBook['book'], hasLength(50));
    expect(snapshot.bookIds, isEmpty);
    expect(snapshot.pendingCount, 51);
  });

  test('changes survive restart and failed acknowledgement', () async {
    final tracker = await CloudChangeTracker.load();
    await tracker.markWord('book', 1);
    final uploading = tracker.snapshot;
    await tracker.markWord('book', 2);

    await tracker.acknowledge(uploading);
    final restored = await CloudChangeTracker.load();

    expect(restored.snapshot.wordIdsByBook['book'], {1, 2});
  });

  test('successful acknowledgement clears the durable journal', () async {
    final tracker = await CloudChangeTracker.load();
    await tracker.markWord('book', 1);

    await tracker.acknowledge(tracker.snapshot);
    final restored = await CloudChangeTracker.load();

    expect(restored.pendingCount, 0);
  });

  test('merge keeps cloud conflicts and appends local-only words', () {
    final cloud = _backup(
        [
          _book('same', 'Cloud book', [
            _word(1, 'cloud'),
          ])
        ],
        sessionSize: 20,
        completed: ['same:0'],
        days: ['2026-06-20']);
    final local = _backup(
        [
          _book('same', 'Local book', [
            _word(1, 'local'),
            _word(2, 'local only'),
          ])
        ],
        sessionSize: 10,
        completed: ['same:1'],
        days: ['2026-06-21']);

    final merged = mergeBackupJson(cloud: cloud, local: local);
    final book = WordBook.fromJson(
        (merged['books'] as List<dynamic>).single as Map<String, dynamic>);

    expect(book.name, 'Cloud book');
    expect(book.words.map((word) => word.term), ['cloud', 'local only']);
    expect(merged['sessionSize'], 20);
    expect(merged['completed'], containsAll(['same:0', 'same:1']));
    expect(merged['studyDays'], containsAll(['2026-06-20', '2026-06-21']));
  });

  test('merge preserves same-name separate books with device suffixes', () {
    final cloud = _backup([
      _book('cloud', 'JLPT', [_word(1, 'cloud')]),
      _book('taken', 'JLPT (이 기기)', [_word(2, 'taken')]),
    ]);
    final local = _backup([
      _book('local', 'JLPT', [_word(3, 'local')]),
    ]);

    final merged = mergeBackupJson(cloud: cloud, local: local);
    final names = (merged['books'] as List<dynamic>)
        .map((item) => (item as Map<String, dynamic>)['name'])
        .toList();

    expect(names, ['JLPT', 'JLPT (이 기기)', 'JLPT (이 기기) 2']);
  });

  test('automatic backup configuration is stored per account', () async {
    final tracker = await CloudChangeTracker.load();
    await tracker.setInitialized('a', true);
    await tracker.setEnabled('a', true);
    await tracker.setNetworkPolicy('a', AutoBackupNetworkPolicy.wifiOnly);

    final restored = await CloudChangeTracker.load();
    expect(restored.isInitialized('a'), isTrue);
    expect(restored.isEnabled('a'), isTrue);
    expect(restored.networkPolicy('a'), AutoBackupNetworkPolicy.wifiOnly);
    expect(restored.isEnabled('b'), isFalse);
    expect(restored.networkPolicy('b'), AutoBackupNetworkPolicy.all);
  });
}

Map<String, dynamic> _backup(
  List<Map<String, dynamic>> books, {
  int sessionSize = 10,
  List<String> completed = const [],
  List<String> days = const [],
}) =>
    {
      'version': 1,
      'books': books,
      'quickBook': books.first['id'],
      'sessionSize': sessionSize,
      'completed': completed,
      'studyDays': days,
      'targetName': '',
      'targetDate': null,
      'horizontalSwipe': false,
      'reverseSwipe': false,
      'japaneseFont': 'system',
      'cardFontSizes': <String, dynamic>{},
    };

Map<String, dynamic> _book(
        String id, String name, List<Map<String, dynamic>> words) =>
    {
      'id': id,
      'name': name,
      'isFavorite': false,
      'sessionOverrides': <String, dynamic>{},
      'words': words,
    };

Map<String, dynamic> _word(int id, String term) => {
      'id': id,
      'term': term,
      'reading': '',
      'meaning': term,
      'example': '',
      'exampleMeaning': '',
      'state': 'fresh',
    };
