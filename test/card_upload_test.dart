import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/auto_backup.dart';
import 'package:vocaflow/card_sync.dart';
import 'package:vocaflow/cloud_backup.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/store.dart';

class _User implements User {
  @override
  String get uid => 'test-user';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth implements FirebaseAuth {
  @override
  User? get currentUser => _User();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Firestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Network implements Connectivity {
  List<ConnectivityResult> results = [ConnectivityResult.wifi];
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => results;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cloud extends CloudBackup {
  _Cloud() : super(auth: _Auth(), firestore: _Firestore(), storage: _Storage());
  final sent = <CardChange>[];
  Future<void> Function(CardChange)? send;
  @override
  Future<void> uploadCardChange(CardChange change,
      {required String deviceId}) async {
    sent.add(change);
    await send?.call(change);
  }

  @override
  Future<Map<String, dynamic>?> downloadCard(String bookId, int wordId) async =>
      null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<(VocaStore, WordBook, _Cloud, _Network, AutoBackupCoordinator)>
      setup() async {
    final store = await VocaStore.load();
    await store.activateAccount('test-user');
    final book = await store.addBook(
        '테스트', [Word(id: 42, term: 'つくづく', reading: 'つくづく', meaning: '절실히')]);
    final cloud = _Cloud();
    final network = _Network();
    final coordinator = AutoBackupCoordinator(
        store: store, cloud: cloud, connectivity: network);
    addTearDown(coordinator.dispose);
    return (store, book, cloud, network, coordinator);
  }

  test('manual edit requests its card immediately and waits for server receipt',
      () async {
    final (store, book, cloud, _, coordinator) = await setup();
    final gate = Completer<void>();
    cloud.send = (_) => gate.future;
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: '뼈저리게'),
        bookId: book.id))!;
    var finished = false;
    final receipt = coordinator.saveEditedCard(op).then((value) {
      finished = true;
      return value;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(cloud.sent.single.id, op.id);
    expect(finished, isFalse);
    gate.complete();
    expect(await receipt, CardSaveOutcome.saved);
    expect(store.cardChanges.pending, isEmpty);
  });
  test('permission failure preserves operation and cannot report success',
      () async {
    final (store, book, cloud, _, coordinator) = await setup();
    cloud.send = (_) async => throw FirebaseException(
        plugin: 'cloud_firestore', code: 'permission-denied');
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: '뼈저리게'),
        bookId: book.id))!;
    expect(await coordinator.saveEditedCard(op), CardSaveOutcome.failed);
    expect(store.cardChanges.pending.single.id, op.id);
    expect(store.cardChanges.lastError, contains('permission-denied'));
    expect(store.resolveCard(book.id, 42)!.meaning, '뼈저리게');
  });
  test('a second edit in flight has its own receipt and is sent next',
      () async {
    final (store, book, cloud, _, coordinator) = await setup();
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    cloud.send =
        (op) => cloud.sent.length == 1 ? firstGate.future : secondGate.future;
    final first = (await store.updateWord(
        book.words.first.copyWith(meaning: '첫 수정'),
        bookId: book.id))!;
    final receipt1 = coordinator.saveEditedCard(first);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final second = (await store.updateWord(
        book.words.first.copyWith(meaning: '마지막 수정'),
        bookId: book.id))!;
    var secondDone = false;
    final receipt2 = coordinator.saveEditedCard(second).then((value) {
      secondDone = true;
      return value;
    });
    firstGate.complete();
    expect(await receipt1, CardSaveOutcome.saved);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(secondDone, isFalse);
    expect(store.resolveCard(book.id, 42)!.meaning, '마지막 수정');
    secondGate.complete();
    expect(await receipt2, CardSaveOutcome.saved);
    expect(cloud.sent.map((op) => op.id), [first.id, second.id]);
  });
}
