import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocaflow/auto_backup.dart';
import 'package:vocaflow/card_sync.dart';
import 'package:vocaflow/cloud_backup.dart';
import 'package:vocaflow/cloud_change_tracker.dart';
import 'package:vocaflow/models.dart';
import 'package:vocaflow/main.dart';
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
  Object? error;
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    if (error != null) throw error!;
    return results;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cloud extends CloudBackup {
  _Cloud() : super(auth: _Auth(), firestore: _Firestore(), storage: _Storage());
  final sent = <CardChange>[];
  Future<void> Function(CardChange)? send;
  Object? readError;
  final Map<String, Map<String, dynamic>> committed = {};
  int learningUploads = 0;
  bool failSettings = false;
  Future<void> Function()? settingsWait;
  final settingsSubmissions = <Map<String, Map<String, dynamic>>>[];
  @override
  Future<List<Map<String, dynamic>>> downloadLearningStates() async => [];
  @override
  Future<void> uploadLearningState(
      VocaStore store, CloudChangeSnapshot changes) async {
    learningUploads++;
    await store.syncV2Snapshot();
  }

  @override
  Future<SettingsSyncResult> syncSettings(
      Map<String, Map<String, dynamic>> local) async {
    settingsSubmissions.add(local);
    await settingsWait?.call();
    if (failSettings) throw StateError('settings-unavailable');
    return SettingsSyncResult(fields: local, submitted: local);
  }

  @override
  Future<bool> isCardSyncCutoverEnabled() async => true;
  @override
  Future<List<Map<String, dynamic>>> downloadCardBookMetadata() async => [];
  @override
  Future<void> uploadCardChange(CardChange change,
      {required String deviceId}) async {
    sent.add(change);
    await send?.call(change);
    committed
        .putIfAbsent(
            '${change.bookId}/${change.wordId}',
            () => {
                  'term': 'つくづく',
                  'reading': 'つくづく',
                  'meaning': '절실히',
                  'example': '',
                  'exampleMeaning': '',
                  'explanation': '',
                })
        .addAll(change.fields);
  }

  @override
  Future<Map<String, dynamic>?> downloadCard(String bookId, int wordId) async {
    if (readError != null) throw readError!;
    return committed['$bookId/$wordId'];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<(VocaStore, WordBook, _Cloud, _Network, AutoBackupCoordinator)> setup(
      {Duration feedbackDelay = const Duration(seconds: 5)}) async {
    final store = await VocaStore.load();
    await store.activateAccount('test-user');
    final book = await store.addBook(
        '테스트', [Word(id: 42, term: 'つくづく', reading: 'つくづく', meaning: '절실히')]);
    // This fixture represents an already published book.
    for (final op in store.cardChanges.pending) {
      await store.cardChanges.acknowledge(op);
    }
    final cloud = _Cloud();
    final network = _Network();
    final coordinator = AutoBackupCoordinator(
        store: store,
        cloud: cloud,
        connectivity: network,
        cardFeedbackDelay: feedbackDelay);
    addTearDown(coordinator.dispose);
    return (store, book, cloud, network, coordinator);
  }

  test(
      'manual settings read clears errors without learning uploads or new success time',
      () async {
    final (store, _, cloud, _, coordinator) = await setup();
    final tracker = store.cloudChanges;
    await tracker.recordSettingsFailure('old-unavailable');
    final uploadedAt = tracker.lastSuccess('test-user');
    await coordinator.manualSettingsRefresh();
    expect(cloud.settingsSubmissions.single, isEmpty);
    expect(cloud.learningUploads, 0);
    expect(tracker.settingsLastError, isNull);
    expect(tracker.channelError('settings'), isNull);
    expect(tracker.lastSuccess('test-user'), uploadedAt);
  });
  test(
      'manual settings check retains pending fields and reports genuine failure',
      () async {
    final (store, _, cloud, _, coordinator) = await setup();
    await store.setUndoHaptics(false);
    final pending = store.cloudChanges.snapshot.settingsKeys;
    await coordinator.manualSettingsRefresh();
    expect(cloud.settingsSubmissions.single, isEmpty);
    expect(store.cloudChanges.snapshot.settingsKeys, pending);
    cloud.failSettings = true;
    await expectLater(coordinator.manualSettingsRefresh(), throwsStateError);
    expect(
        store.cloudChanges.settingsLastError, contains('settings-unavailable'));
    expect(store.cloudChanges.snapshot.settingsKeys, pending);
    expect(cloud.learningUploads, 0);
  });
  test('new settings failure during a successful read is not hidden', () async {
    final (store, _, cloud, _, coordinator) = await setup();
    final gate = Completer<void>();
    final entered = Completer<void>();
    cloud.settingsWait = () {
      entered.complete();
      return gate.future;
    };
    final read = coordinator.manualSettingsRefresh();
    await entered.future;
    await store.cloudChanges.recordSettingsFailure('newer');
    gate.complete();
    await read;
    expect(store.cloudChanges.settingsLastError, 'newer');
    expect(store.cloudChanges.channelError('settings'), 'newer');
  });

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
    expect(store.cardChanges.wasAcknowledged(op.id), isTrue);
  });
  test(
      'failed read-back survives restart and retries without uploading the edit again',
      () async {
    final (store, book, cloud, network, coordinator) = await setup();
    cloud.readError = StateError('readback-offline');
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: '뼈저리게'),
        bookId: book.id))!;
    expect(await coordinator.saveEditedCard(op), CardSaveOutcome.saved);
    // The write is confirmed, but read-back is still an independent duty.
    for (var i = 0; i < 30 && store.cardChanges.lastError == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(store.cardChanges.refreshCards['${book.id}/42'], op.id);
    expect(store.cardChanges.pendingCount, 0);
    coordinator.dispose();
    final restarted = await VocaStore.load();
    await restarted.activateAccount('test-user');
    expect(restarted.cardChanges.hasWork, isTrue);
    cloud.readError = null;
    cloud.committed['${book.id}/42']!['meaning'] = 'later server value';
    final retry = AutoBackupCoordinator(
        store: restarted, cloud: cloud, connectivity: network);
    addTearDown(retry.dispose);
    await retry.flushPendingBackup();
    for (var i = 0; i < 50 && restarted.cardChanges.hasWork; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(cloud.sent.where((change) => change.id == op.id), hasLength(1));
    expect(restarted.cardChanges.hasWork, isFalse);
    expect(restarted.cardChanges.lastError, isNull);
    expect(restarted.resolveCard(book.id, 42)!.meaning, 'later server value');
  });
  test('card and settings failures do not prevent a learning upload', () async {
    final (store, book, cloud, _, coordinator) = await setup();
    cloud.send = (_) async => throw FirebaseException(
        plugin: 'cloud_firestore', code: 'permission-denied');
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: '뼈저리게'),
        bookId: book.id))!;
    expect(await coordinator.saveEditedCard(op), CardSaveOutcome.failed);
    await store.cloudChanges.setEnabled('test-user', true);
    await store.cloudChanges.setInitialized('test-user', true);
    await store.mark(book.words.first, StudyState.memorized, bookId: book.id);
    await store.setHorizontalSwipe(true);
    cloud.failSettings = true;
    await coordinator.flushPendingBackup();
    expect(cloud.learningUploads, 1);
    expect(store.cloudChanges.learningStateDirty, isFalse);
    expect(store.cloudChanges.settingsDirty, isTrue);
    expect(store.cardChanges.contains(op.id), isTrue);
    expect(store.cloudChanges.channelError('settings'),
        contains('settings-unavailable'));
  });
  testWidgets('success toast appears only after the edited card is committed',
      (tester) async {
    final (store, book, cloud, _, coordinator) =
        (await tester.runAsync(() => setup()))!;
    AutoBackupCoordinator.activeInstance = coordinator;
    final gate = Completer<void>();
    cloud.send = (_) => gate.future;
    await tester.pumpWidget(
        MaterialApp(home: CardStudyPage(store: store, words: book.words)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('word-meaning')), '뼈저리게');
    await tester.tap(find.text('저장'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('수정한 뜻을 서버에 저장했어요'), findsNothing);
    expect(store.cardChanges.pending, hasLength(1));
    gate.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('수정한 뜻을 서버에 저장했어요'), findsOneWidget);
    expect(store.cardChanges.pending, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
      'permission denial shows failure toast and retains the local edit',
      (tester) async {
    final (store, book, cloud, _, coordinator) =
        (await tester.runAsync(() => setup()))!;
    AutoBackupCoordinator.activeInstance = coordinator;
    cloud.send = (_) async => throw FirebaseException(
        plugin: 'cloud_firestore', code: 'permission-denied');
    await tester.pumpWidget(
        MaterialApp(home: CardStudyPage(store: store, words: book.words)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('word-meaning')), '뼈저리게');
    await tester.tap(find.text('저장'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('수정한 뜻을 서버에 저장했어요'), findsNothing);
    // Account/status persistence crosses real and fake async zones. Wait for
    // the actual failed request, not a fixed wall-clock delay.
    for (var i = 0; i < 30 && store.cardChanges.lastError == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(cloud.sent, isNotEmpty);
    expect(find.text('폰에는 저장됐지만 서버 전송에 실패했어요'), findsOneWidget);
    expect(store.resolveCard(book.id, 42)!.meaning, '뼈저리게');
    expect(store.cardChanges.pending, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
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
    expect(
        store.cloudChanges.logs.any((log) =>
            log.contains('카드 서버 전송 실패') && log.contains('permission-denied')),
        isTrue);
  });
  test('missing queue entry alone is not a server success receipt', () async {
    final (store, book, cloud, _, coordinator) = await setup();
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: '뼈저리게'),
        bookId: book.id))!;
    await store.cardChanges.clearMigratedLegacyWork();
    expect(await coordinator.saveEditedCard(op), CardSaveOutcome.waiting);
    expect(cloud.sent, isEmpty);
    expect(store.cardChanges.wasAcknowledged(op.id), isFalse);
  });
  test('connectivity check failure is logged and keeps the edit pending',
      () async {
    final (store, book, cloud, network, coordinator) = await setup();
    network.error = StateError('network-probe-failed');
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: '뼈저리게'),
        bookId: book.id))!;
    expect(await coordinator.saveEditedCard(op), CardSaveOutcome.failed);
    expect(cloud.sent, isEmpty);
    expect(store.cardChanges.contains(op.id), isTrue);
    expect(store.cardChanges.lastError, contains('network-probe-failed'));
    expect(
        store.cloudChanges.logs
            .any((log) => log.contains('network-probe-failed')),
        isTrue);
  });
  test('slow server yields waiting then preserves its exact late receipt',
      () async {
    final (store, book, cloud, _, coordinator) =
        await setup(feedbackDelay: const Duration(milliseconds: 5));
    final gate = Completer<void>();
    cloud.send = (_) => gate.future;
    final op = (await store.updateWord(
        book.words.first.copyWith(meaning: '뼈저리게'),
        bookId: book.id))!;
    expect(await coordinator.saveEditedCard(op), CardSaveOutcome.waiting);
    expect(store.cardChanges.wasAcknowledged(op.id), isFalse);
    gate.complete();
    expect(await coordinator.cardSaveReceipt(op.id), CardSaveOutcome.saved);
    expect(await coordinator.saveEditedCard(op), CardSaveOutcome.saved);
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
