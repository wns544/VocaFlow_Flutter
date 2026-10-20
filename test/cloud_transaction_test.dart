// SDK-shaped test doubles exercise the actual CloudBackup transaction body.
// ignore_for_file: subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/card_sync.dart';
import 'package:vocaflow/cloud_backup.dart';

class _User implements User {
  @override
  String get uid => 'owner';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth implements FirebaseAuth {
  @override
  User get currentUser => _User();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Database implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  final transactions = <_Transaction>[];
  void Function()? beforeTransaction;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);
  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler,
      {Duration timeout = const Duration(seconds: 30),
      int maxAttempts = 5}) async {
    beforeTransaction?.call();
    beforeTransaction = null;
    final tx = _Transaction(this);
    transactions.add(tx);
    final result = await handler(tx);
    for (final entry in tx.writes.entries) {
      documents[entry.key] = {...?documents[entry.key], ...entry.value};
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Collection implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.database, this.path);
  final _Database database;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _Document(database, '${this.path}/$path');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Document implements DocumentReference<Map<String, dynamic>> {
  _Document(this.database, this.path);
  final _Database database;
  @override
  final String path;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(database, '${this.path}/$path');
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get(
          [GetOptions? options]) async =>
      _Snapshot(database.documents[path]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Snapshot implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.value);
  final Map<String, dynamic>? value;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Transaction implements Transaction {
  _Transaction(this.database);
  final _Database database;
  final writes = <String, Map<String, dynamic>>{};
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
          DocumentReference<T> ref) async =>
      _Snapshot(database.documents[ref.path]) as DocumentSnapshot<T>;
  @override
  Transaction update(DocumentReference ref, Map<Object, Object?> data) {
    writes[ref.path] =
        data.map((key, value) => MapEntry(key.toString(), value));
    return this;
  }

  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    writes[ref.path] = Map<String, dynamic>.from(data as Map);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('structure create rename add delete and explicit restore are idempotent',
      () async {
    final db = _Database();
    final cloud =
        CloudBackup(auth: _Auth(), firestore: db, storage: _Storage());
    var sequence = 0;
    CardChange op(String kind, Map<String, dynamic> fields, {int wordId = 0}) =>
        CardChange(
            id: 'op-${++sequence}',
            kind: kind,
            bookId: 'book',
            wordId: wordId,
            fields: fields,
            before: {},
            localVersion: sequence,
            createdAt: DateTime.utc(2026));
    Future<void> send(CardChange change) =>
        cloud.uploadCardChange(change, deviceId: 'phone');
    const path = 'users/owner/cardBooks/book';
    await send(op('bookCreate', {'name': 'new', 'wordOrder': <int>[]}));
    final create = op(
        'cardCreate', {'term': 'A', 'reading': 'a', 'meaning': '뜻'},
        wordId: 42);
    await send(create);
    await send(create);
    expect(db.documents[path]!['nextChange'], 2);
    expect(db.documents[path]!['wordOrder'], [42]);
    await send(op('bookPatch', {'name': 'renamed'}));
    await send(op(
        'cardCreate', {'term': 'B', 'reading': 'b', 'meaning': '다른 뜻'},
        wordId: 43));
    // An older device's order cannot discard a concurrently appended card.
    await send(op('bookPatch', {
      'wordOrder': [42]
    }));
    expect(db.documents[path]!['wordOrder'], [42, 43]);
    expect(db.documents['$path/changes/000000000005']!['fields']['wordOrder'],
        [42, 43]);
    expect(db.documents[path]!['name'], 'renamed');
    await send(op('cardDelete', {}, wordId: 42));
    expect(db.documents['$path/cards/42']!['deleted'], isTrue);
    expect(db.documents[path]!['wordOrder'], [43]);
    await expectLater(
        send(op(
            'cardCreate', {'term': 'stale', 'reading': 'a', 'meaning': 'stale'},
            wordId: 42)),
        throwsStateError);
    await expectLater(send(op('cardPatch', {'meaning': 'stale'}, wordId: 42)),
        throwsStateError);
    await send(op(
        'cardRestore', {'term': 'A', 'reading': 'a', 'meaning': 'restored'},
        wordId: 42));
    expect(db.documents['$path/cards/42']!['deleted'], isFalse);
    await send(op('bookDelete', {}));
    await expectLater(
        send(op('bookPatch', {'name': 'stale'})), throwsStateError);
    await expectLater(
        send(op('cardCreate', {'term': 'C', 'reading': 'c', 'meaning': 'stale'},
            wordId: 44)),
        throwsStateError);
    await send(op('bookRestore', {'name': 'restored'}));
    expect(db.documents[path]!['deleted'], isFalse);
    expect(db.documents[path]!['name'], 'restored');
  });
  test('settings re-read the latest server version inside the transaction',
      () async {
    final db = _Database();
    const path = 'users/owner/settings/main';
    Map<String, dynamic> entry(int time, int value) =>
        {'value': value, 'updatedAtMicros': time, 'deviceId': 'phone'};
    db.documents[path] = {
      'fields': {'termFontSize': entry(10, 30)}
    };
    // Another device commits after the initial existence/migration read.
    db.beforeTransaction = () => db.documents[path] = {
          'fields': {'termFontSize': entry(200, 42)}
        };
    final cloud =
        CloudBackup(auth: _Auth(), firestore: db, storage: _Storage());
    final result = await cloud.syncSettings({'termFontSize': entry(100, 35)});
    expect(result.fields['termFontSize']['value'], 42);
    expect(db.documents[path]!['fields']['termFontSize']['value'], 42);
    expect(db.transactions.single.writes, isEmpty);
  });
  test(
      'independent card fields merge; late same-field edit records actual server before-value',
      () async {
    final db = _Database();
    const path = 'users/owner/cardBooks/book';
    db.documents[path] = {'nextChange': 0, 'migrationSourceRevision': 34};
    db.documents['$path/cards/42'] = {
      'id': 42,
      'term': '語',
      'reading': 'old-reading',
      'meaning': 'original'
    };
    final a = CloudBackup(auth: _Auth(), firestore: db, storage: _Storage());
    final b = CloudBackup(auth: _Auth(), firestore: db, storage: _Storage());
    CardChange edit(String id, String field, String value) => CardChange(
        id: id,
        bookId: 'book',
        wordId: 42,
        fields: {field: value},
        before: {field: 'stale cached value'},
        localVersion: 1,
        createdAt: DateTime.utc(2026));
    await a.uploadCardChange(edit('a', 'meaning', 'custom'), deviceId: 'phone');
    await b.uploadCardChange(edit('b', 'reading', 'new-reading'),
        deviceId: 'web');
    expect(db.documents['$path/cards/42']!['meaning'], 'custom');
    expect(db.documents['$path/cards/42']!['reading'], 'new-reading');
    final late = edit('c', 'meaning', 'late-offline-edit');
    await b.uploadCardChange(late, deviceId: 'offline-phone');
    expect(db.documents['$path/changes/000000000003']!['before'],
        {'meaning': 'custom'});
    expect(db.documents['$path/cards/42']!['meaning'], 'late-offline-edit');
    await b.uploadCardChange(late, deviceId: 'offline-phone');
    expect(db.documents[path]!['nextChange'], 3);
    expect(db.documents[path]!['migrationSourceRevision'], 34);
    expect(db.documents['$path/cards/42']!['id'], 42);
    expect(db.documents['$path/cards/42']!.containsKey('state'), isFalse);
  });
  test('card text, immutable receipt and cross-device signal commit together',
      () async {
    final db = _Database();
    const book = 'users/owner/cardBooks/book';
    db.documents[book] = {'nextChange': 0};
    db.documents['$book/cards/42'] = {'term': 'つくづく', 'meaning': '절실히'};
    final cloud =
        CloudBackup(auth: _Auth(), firestore: db, storage: _Storage());
    final op = CardChange(
        id: 'op',
        bookId: 'book',
        wordId: 42,
        fields: {'meaning': '뼈저리게'},
        before: {'meaning': '절실히'},
        localVersion: 1,
        createdAt: DateTime.utc(2026));
    await cloud.uploadCardChange(op, deviceId: 'phone');
    final paths = db.transactions.single.writes.keys;
    expect(
        paths,
        containsAll([
          '$book/cards/42',
          '$book/operations/op',
          '$book/changes/000000000001',
          'users/owner/syncSignals/cardBookChanges'
        ]));
    expect(db.documents['$book/cards/42']!['meaning'], '뼈저리게');
    expect(db.documents[book]!['lastOperationId'], 'op');
    expect(db.documents['$book/operations/op']!['changeId'], '000000000001');
    expect(db.documents['$book/operations/op']!['kind'], 'cardPatch');
    await cloud.uploadCardChange(op, deviceId: 'phone');
    expect(db.documents[book]!['nextChange'], 1);
    expect(db.transactions.last.writes.keys,
        ['users/owner/syncSignals/cardBookChanges']);
  });
}
