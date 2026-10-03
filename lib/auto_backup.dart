import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'cloud_backup.dart';
import 'book_archive_store.dart';
import 'book_restore_archive.dart';
import 'cloud_change_tracker.dart';
import 'store.dart';
import 'word_relations.dart';

enum InitialSyncChoice { cloudReplace, merge }

/// Learning progress follows the user's backup preference. Account-owned
/// vocabulary books are different: while signed in, their add/edit/delete
/// queue always syncs between that account's devices. Neither channel writes
/// legacy vocabBooks/words documents.
class AutoBackupCoordinator with WidgetsBindingObserver {
  static AutoBackupCoordinator? activeInstance;
  static const recentRevisionLimitPerBook = 10;
  static const maxArchiveBytes = CloudBackup.maxBookArchiveBytes;

  AutoBackupCoordinator({
    required this.store,
    this.onChanged,
    CloudBackup? cloud,
    Connectivity? connectivity,
    DateTime Function()? now,
    this.idleDelay = const Duration(seconds: 15),
    this.minimumInterval = const Duration(seconds: 15),
  })  : cloud = cloud ?? CloudBackup(),
        connectivity = connectivity ?? Connectivity(),
        _now = now ?? DateTime.now;

  final VocaStore store;
  final CloudBackup cloud;
  final Connectivity connectivity;
  final VoidCallback? onChanged;
  final DateTime Function() _now;
  final Duration idleDelay;
  final Duration minimumInterval;
  final BookArchiveStore _archiveStore = BookArchiveStore();

  Timer? _timer;
  int? _scheduledGeneration;
  bool _scheduledIsRetry = false;
  int? _failedGeneration;
  bool _retryBudgetExhausted = false;
  StreamSubscription<User?>? _authSubscription;
  bool _syncing = false;
  bool _downloading = false;
  bool learningStateVerified = false;
  bool _flushingForBackground = false;
  DateTime? _lastSuccessAt;
  int _failureCount = 0;
  Future<void>? _webInitialSync;

  bool get isUploading => _syncing && !_downloading;
  bool get isDownloading => _downloading;
  User? get user => FirebaseAuth.instance.currentUser;
  bool get enabled => user != null && store.cloudChanges.isEnabled(user!.uid);
  bool get accountBookSyncEnabled => user != null;
  bool get initialized =>
      user != null && store.cloudChanges.isInitialized(user!.uid);
  int get pendingCount =>
      (store.cloudChanges.learningStateDirty ? 1 : 0) +
      (store.cloudChanges.managedBookContentDirty ? 1 : 0) +
      (store.cloudChanges.archiveContentDirty ? 1 : 0);
  DateTime? get lastSuccess =>
      user == null ? null : store.cloudChanges.lastSuccess(user!.uid);
  List<String> get logs => store.cloudChanges.logs;
  DateTime? get lastDownload =>
      user == null ? null : store.cloudChanges.lastDownload(user!.uid);
  String? get lastError =>
      user == null ? null : store.cloudChanges.lastError(user!.uid);
  AutoBackupNetworkPolicy get networkPolicy => user == null
      ? AutoBackupNetworkPolicy.all
      : store.cloudChanges.networkPolicy(user!.uid);

  void start() {
    activeInstance = this;
    WidgetsBinding.instance.addObserver(this);
    store.cloudChanges.onChanged = _handleTrackedChange;
    store.onSessionCompleted = requestImmediateBackup;
    store.onBeforeBookMutation = _archiveBeforeBookMutation;
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((current) {
      learningStateVerified = false;
      _cancelScheduledUpload();
      _startWebInitialSyncIfNeeded();
      if (current != null) {
        unawaited(() async {
          await store.activateAccount(current.uid);
          await store.cloudChanges.activateAccount(current.uid);
          await mergeFromCloud(uploadMerged: false, reason: '계정 연결');
          if (enabled && initialized) await _seedLearningState();
        }());
      }
      onChanged?.call();
    });
    _startWebInitialSyncIfNeeded();
    if (enabled && initialized) unawaited(_seedLearningState());
  }

  /// A browser starts without app storage, so requiring an extra confirmation
  /// there leaves a successfully logged-in user looking like they have no
  /// progress. The web can safely pull the dedicated learning-state snapshots
  /// first; it never replaces word-card content.
  Future<void> initializeWebFromCloud() {
    if (!kIsWeb || initialized) return Future<void>.value();
    return _webInitialSync ??= () async {
      try {
        await initialize(InitialSyncChoice.cloudReplace);
      } catch (_) {
        // A retry is allowed on the next auth change or app start.
        _webInitialSync = null;
      }
    }();
  }

  void _startWebInitialSyncIfNeeded() {
    if (kIsWeb && user != null && !initialized) {
      unawaited(initializeWebFromCloud());
    }
  }

  void dispose() {
    if (activeInstance == this) activeInstance = null;
    WidgetsBinding.instance.removeObserver(this);
    if (store.cloudChanges.onChanged == _handleTrackedChange) {
      store.cloudChanges.onChanged = null;
    }
    store.onSessionCompleted = null;
    if (store.onBeforeBookMutation == _archiveBeforeBookMutation) {
      store.onBeforeBookMutation = null;
    }
    _cancelScheduledUpload();
    _authSubscription?.cancel();
  }

  Future<bool> hasCloudBackup() => cloud.hasLearningState();

  Future<List<BookRestorePoint>> localRestorePoints() async {
    final current = user;
    if (current == null) return const [];
    return _archiveStore.list(current.uid);
  }

  /// Reads account history from the server and keeps a local copy so a later
  /// restore can still be selected while the device is offline.
  Future<List<BookRestorePoint>> restorePoints({bool refresh = true}) async {
    final current = user;
    if (current == null) return const [];
    final local = <String, BookRestorePoint>{
      for (final point in await _archiveStore.list(current.uid)) point.id: point,
    };
    if (refresh) {
      final remote = await cloud.listBookArchives();
      for (final item in remote) {
        if (local.containsKey(item.id)) continue;
        final point = await cloud.downloadBookArchive(item.id);
        if (point != null) {
          local[point.id] = point;
          await _archiveStore.save(current.uid, point);
        }
      }
    }
    final result = local.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<int> restoreArchiveBytes() async {
    final current = user;
    if (current == null) return 0;
    try {
      return await cloud.bookArchiveBytes();
    } catch (_) {
      return _archiveStore.totalBytes(current.uid);
    }
  }

  Future<void> permanentlyDeleteRestorePoint(BookRestorePoint point) async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    // Server succeeds first: a flaky network must not make the sole account
    // copy disappear while leaving a stale local cache that looks deleted.
    await cloud.deleteBookArchive(point.id);
    await _archiveStore.remove(current.uid, point.id);
  }

  /// Restoring is also a mutation: first preserve the current state as a new
  /// recovery point, then apply the chosen point using its original IDs.
  Future<void> restoreBookFromPoint(BookRestorePoint point) async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    await _archiveBeforeBookMutation(point.bookId, 'restore');
    await store.restoreBookFromPayload(point.payload);
    final relations = point.payload['relations'];
    if (relations is List) {
      await wordRelations.restoreArchived(
        relations.whereType<Map>().map((row) => Map<String, dynamic>.from(row)),
      );
    }
    requestImmediateBackup(ignoreMinimumInterval: true);
  }

  /// Saves locally first so an offline edit is recoverable immediately, then
  /// queues its account upload. _uploadPending always drains this queue before
  /// it sends a managedBooks edit/delete tombstone.
  Future<void> _archiveBeforeBookMutation(String bookId, String reason) async {
    final current = user;
    if (current == null || bookId == 'default') return;
    // A restore may bring back a book that is currently only in the account
    // trash. There is no local state to snapshot in that case.
    if (!store.books.any((book) => book.id == bookId)) return;
    await wordRelations.load();
    final point = BookRestorePoint.create(
      bookId: bookId,
      kind: 'before_$reason',
      deviceId: await store.cloudChanges.deviceId(),
      payload: store.createBookRestorePayload(
        bookId,
        relations: wordRelations.snapshotForBook(bookId),
      ),
      now: _now(),
    );
    await _archiveStore.save(current.uid, point);
    await store.cloudChanges.markArchive(point.id);
    await store.cloudChanges.recordDiagnostic('book_restore_point_created', data: {
      'bookId': bookId,
      'archiveId': point.id,
      'kind': point.kind,
      'bytes': point.utf8Bytes.length,
    });
  }

  Future<void> initialize(InitialSyncChoice? choice) async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    final hasCloud = await cloud.hasLearningState();
    if (hasCloud && choice == null) return;
    if (hasCloud) {
      await _pullManagedBooks(reason: '초기 단어장 본문 가져오기');
      await store
          .applyLearningStateSnapshots(await cloud.downloadLearningStates());
    }
    await store.cloudChanges.setInitialized(current.uid, true);
    await store.cloudChanges.setEnabled(current.uid, true);
    await store.cloudChanges.markLearningState();
    await _uploadPending(reason: '초기 학습 상태 저장');
    onChanged?.call();
  }

  Future<void> setEnabled(bool value) async {
    final current = user;
    if (current == null) return;
    await store.cloudChanges.setEnabled(current.uid, value);
    if (!value) {
      _cancelScheduledUpload();
    } else {
      await _seedLearningState();
    }
    onChanged?.call();
  }

  Future<void> setNetworkPolicy(AutoBackupNetworkPolicy value) async {
    final current = user;
    if (current == null) return;
    await store.cloudChanges.setNetworkPolicy(current.uid, value);
    if (enabled && store.cloudChanges.learningStateDirty)
      requestImmediateBackup();
    onChanged?.call();
  }

  Future<void> manualFullUpload() async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    if (_syncing) {
      throw StateError('다른 동기화가 진행 중입니다. 잠시 후 다시 시도해 주세요.');
    }
    await store.cloudChanges.markAll({
      for (final book in store.books.where((book) => book.id != 'default'))
        book.id: book.words.map((word) => word.id),
    });
    await store.cloudChanges.markLearningState();
    await _uploadPending(reason: '이 기기 데이터 내보내기');
    if (store.cloudChanges.learningStateDirty ||
        store.cloudChanges.managedBookContentDirty ||
        store.cloudChanges.archiveContentDirty) {
      throw StateError('클라우드 업로드가 완료되지 않았습니다. 네트워크를 확인한 뒤 다시 시도해 주세요.');
    }
  }

  Future<void> manualRestore() async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    await _pullLearningState(reason: '클라우드 데이터 가져오기');
  }

  Future<void> mergeFromCloud({
    bool uploadMerged = true,
    String reason = '클라우드 확인',
  }) async {
    if (!accountBookSyncEnabled || _syncing) return;
    learningStateVerified = false;
    _syncing = true;
    try {
      final current = user;
      if (current != null) await store.cloudChanges.activateAccount(current.uid);
      // Always read first. A dirty local book is deliberately left untouched
      // until its base revision is checked by the transactional upload.
      await _pullManagedBooks(reason: reason);
      await _sendPendingArchives(reason: '$reason · 복원본 보관');
      if (store.cloudChanges.managedBookContentDirty) {
        await _sendManagedBookContent(reason: '$reason · 로컬 단어장 반영');
      }
      if (enabled && initialized) {
        await _pullLearningState(
            reason: reason, ownsGate: true, pullManagedBooks: false);
      }
      if (enabled && initialized && uploadMerged && store.cloudChanges.learningStateDirty) {
        await _sendLearningState(reason: '$reason · 병합 반영');
      }
    } catch (error) {
      await _recordFailure(error, reason);
    } finally {
      _syncing = false;
      onChanged?.call();
    }
  }

  void requestImmediateBackup({bool ignoreMinimumInterval = false}) =>
      _schedule(Duration.zero, ignoreMinimumInterval: ignoreMinimumInterval);

  Future<void> flushPendingBackup() async {
    if (_flushingForBackground ||
        _syncing ||
        !accountBookSyncEnabled ||
        (!store.cloudChanges.learningStateDirty &&
            !store.cloudChanges.managedBookContentDirty &&
            !store.cloudChanges.archiveContentDirty)) return;
    _flushingForBackground = true;
    _cancelScheduledUpload();
    try {
      await _uploadPending(reason: '앱 백그라운드');
    } finally {
      _flushingForBackground = false;
    }
  }

  Future<void> _seedLearningState() async {
    if (!enabled || !initialized || store.cloudChanges.learningStateDirty)
      return;
    // One compact document per app launch makes legacy local progress visible
    // without writing a single existing word document.
    await store.cloudChanges.markLearningState();
    requestImmediateBackup();
  }

  void _handleTrackedChange() {
    onChanged?.call();
    if (accountBookSyncEnabled &&
        ((enabled && store.cloudChanges.learningStateDirty) ||
            store.cloudChanges.managedBookContentDirty ||
            store.cloudChanges.archiveContentDirty) &&
        !_syncing) {
      _schedule(idleDelay, reason: '학습 변경 후 대기');
    }
  }

  void _schedule(
    Duration requestedDelay, {
    bool ignoreMinimumInterval = false,
    String reason = '자동 업로드',
    bool isRetry = false,
  }) {
    if ((!isRetry && _syncing) ||
        !accountBookSyncEnabled ||
        ((!enabled || !initialized || !store.cloudChanges.learningStateDirty) &&
            !store.cloudChanges.managedBookContentDirty &&
            !store.cloudChanges.archiveContentDirty)) return;
    final generation = store.cloudChanges.snapshot.learningStateGeneration;
    if (_timer != null &&
        _scheduledGeneration == generation &&
        _scheduledIsRetry &&
        !isRetry) {
      // Do not let an unrelated UI rebuild or bookkeeping callback replace the
      // explicit backoff timer with the normal 15-second idle timer.
      unawaited(store.cloudChanges.recordDiagnostic(
        'sync_schedule_preserved',
        data: {
          'reason': reason,
          'generation': generation,
          'scheduledAsRetry': true,
        },
      ));
      return;
    }
    if (!isRetry && _failedGeneration != generation) {
      _failureCount = 0;
      _failedGeneration = null;
      _retryBudgetExhausted = false;
    }
    var delay = requestedDelay;
    if (!isRetry && !ignoreMinimumInterval && _lastSuccessAt != null) {
      final untilAllowed =
          _lastSuccessAt!.add(minimumInterval).difference(_now());
      if (untilAllowed > delay) delay = untilAllowed;
    }
    if (delay.isNegative) delay = Duration.zero;
    _cancelScheduledUpload();
    _scheduledGeneration = generation;
    _scheduledIsRetry = isRetry;
    unawaited(store.cloudChanges.recordLog(
      '$reason 예약 · ${delay.inSeconds}초 후 · learningState 세대 $generation${isRetry ? ' · 재시도' : ''}',
    ));
    unawaited(store.cloudChanges.recordDiagnostic('sync_scheduled', data: {
      'reason': reason,
      'delaySeconds': delay.inSeconds,
      'generation': generation,
      'isRetry': isRetry,
      'failureCount': _failureCount,
      'pendingLearningState': store.cloudChanges.learningStateDirty,
    }));
    _timer = Timer(delay, () {
      _timer = null;
      _scheduledGeneration = null;
      _scheduledIsRetry = false;
      unawaited(_uploadPending(reason: reason));
    });
  }

  Future<void> _uploadPending({String reason = '자동 업로드'}) async {
    if (_syncing ||
        !enabled ||
        (!store.cloudChanges.learningStateDirty &&
            !store.cloudChanges.managedBookContentDirty)) return;
    // This lock is intentionally set before checkConnectivity awaits.
    _syncing = true;
    final generationAtStart =
        store.cloudChanges.snapshot.learningStateGeneration;
    var failed = false;
    try {
      await store.cloudChanges.recordDiagnostic('sync_started', data: {
        'reason': reason,
        'generation': generationAtStart,
        'pendingLearningState': store.cloudChanges.learningStateDirty,
      });
      final networkAllowed = await _networkAllowed();
      await store.cloudChanges.recordDiagnostic('network_checked', data: {
        'reason': reason,
        'allowed': networkAllowed,
        'policy': networkPolicy.name,
      });
      if (!networkAllowed) {
        throw StateError('선택한 네트워크에 연결되어 있지 않습니다.');
      }
      // First observe server revisions. A later transaction refuses to replace
      // a book changed by another phone since this local edit began.
      await _pullManagedBooks(reason: '$reason · 선행 단어장 확인');
      await _sendPendingArchives(reason: '$reason · 복원본 보관');
      if (store.cloudChanges.managedBookContentDirty) {
        await _sendManagedBookContent(reason: reason);
      }
      if (enabled && initialized) {
        await _pullLearningState(
            reason: '$reason · 선행 병합', ownsGate: true, pullManagedBooks: false);
      }
      if (enabled && initialized && store.cloudChanges.learningStateDirty) {
        await _sendLearningState(reason: reason);
      }
      _failureCount = 0;
      _failedGeneration = null;
      _retryBudgetExhausted = false;
    } catch (error, stackTrace) {
      failed = true;
      await _recordFailure(error, reason, stackTrace: stackTrace);
    } finally {
      _syncing = false;
      final generationNow = store.cloudChanges.snapshot.learningStateGeneration;
      if (!failed &&
          enabled &&
          (store.cloudChanges.learningStateDirty ||
              store.cloudChanges.managedBookContentDirty ||
              store.cloudChanges.archiveContentDirty)) {
        _schedule(idleDelay, reason: '전송 중 새 학습 변경');
      } else if (failed && generationNow != generationAtStart) {
        // The failure retry remains authoritative. A subsequent user change,
        // after this request finishes, will schedule its own quiet-period run.
        await store.cloudChanges
            .recordDiagnostic('sync_retry_preserved', data: {
          'reason': reason,
          'startGeneration': generationAtStart,
          'currentGeneration': generationNow,
        });
      }
      onChanged?.call();
    }
  }

  Future<void> _pullLearningState({
    required String reason,
    bool ownsGate = false,
    bool pullManagedBooks = true,
  }) async {
    if (!ownsGate && _syncing) return;
    learningStateVerified = false;
    if (!ownsGate) _syncing = true;
    _downloading = true;
    try {
      await store.cloudChanges.recordLog('$reason · learningState 내려받기 시작');
      await store.cloudChanges.recordDiagnostic('sync_download_started', data: {
        'reason': reason,
      });
      if (pullManagedBooks) await _pullManagedBooks(reason: reason);
      final snapshots = await cloud.downloadLearningStates();
      await store.applyLearningStateSnapshots(snapshots);
      final current = user;
      if (current != null) {
        await store.cloudChanges.recordDownload(current.uid, _now());
      }
      await store.cloudChanges.recordLog('$reason · learningState 병합 완료');
      learningStateVerified = true;
      await store.cloudChanges
          .recordDiagnostic('sync_download_succeeded', data: {
        'reason': reason,
        'remoteSnapshotCount': snapshots.length,
      });
    } finally {
      _downloading = false;
      if (!ownsGate) _syncing = false;
    }
  }

  Future<void> _sendManagedBookContent({required String reason}) async {
    if (!store.cloudChanges.managedBookContentDirty) return;
    final current = user;
    if (current == null) return;
    final snapshot = store.cloudChanges.snapshot;
    final bookIds = <String>{
      ...snapshot.bookIds,
      ...snapshot.wordIdsByBook.keys,
      ...snapshot.deletedWordIdsByBook.keys,
      ...snapshot.deletedBookIds,
    }..remove('default');
    await store.cloudChanges.recordLog(
      '$reason · 단어장 본문 전송 시작 · ${bookIds.length}개 단어장',
    );
    await store.cloudChanges
        .recordDiagnostic('managed_books_upload_started', data: {
      'reason': reason,
      'bookIds': bookIds.toList(),
      'generation': snapshot.generation,
    });
    await cloud.uploadManagedBooks(store, snapshot);
    await store.cloudChanges.recordRemoteBookRevisions({
      for (final id in bookIds) (id): (snapshot.bookBaseRevisions[id] ?? 0) + 1,
    });
    await store.cloudChanges.acknowledgeManagedBookContent(snapshot);
    await store.cloudChanges.recordSuccess(current.uid, _now());
    _lastSuccessAt = _now();
    await store.cloudChanges.recordLog('$reason · 단어장 본문 전송 완료');
    await store.cloudChanges
        .recordDiagnostic('managed_books_upload_succeeded', data: {
      'reason': reason,
      'bookIds': bookIds.toList(),
    });
  }

  Future<void> _sendPendingArchives({required String reason}) async {
    final current = user;
    if (current == null || !store.cloudChanges.archiveContentDirty) return;
    final ids = store.cloudChanges.snapshot.archiveIds;
    final uploaded = <String>[];
    for (final id in ids) {
      final point = await _archiveStore.load(current.uid, id);
      if (point == null) {
        throw StateError('복원본 $id을(를) 기기에서 찾을 수 없습니다. 삭제 동기화를 중단했습니다.');
      }
      await cloud.uploadBookArchive(point);
      uploaded.add(id);
      await store.cloudChanges.recordDiagnostic('book_restore_point_uploaded', data: {
        'archiveId': id,
        'bookId': point.bookId,
        'kind': point.kind,
        'bytes': point.utf8Bytes.length,
      });
    }
    await store.cloudChanges.acknowledgeArchives(uploaded);
    for (final point in await _archiveStore.list(current.uid)) {
      if (uploaded.contains(point.id)) {
        await _pruneOldRevisionPoints(point.bookId);
      }
    }
    await store.cloudChanges.recordSuccess(current.uid, _now());
    _lastSuccessAt = _now();
  }

  Future<void> _pruneOldRevisionPoints(String bookId) async {
    final current = user;
    if (current == null) return;
    final all = await cloud.listBookArchives();
    final revisions = all
        .where((item) => item.bookId == bookId && item.kind != 'before_delete')
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final obsolete in revisions.skip(recentRevisionLimitPerBook)) {
      await cloud.deleteBookArchive(obsolete.id);
      await _archiveStore.remove(current.uid, obsolete.id);
    }
  }

  Future<void> _pullManagedBooks({required String reason}) async {
    final remote = await cloud.downloadManagedBooks();
    final revisions = <String, int>{
      for (final document in remote)
        if (document['id'] != null)
          document['id'].toString(): (document['revision'] as num?)?.toInt() ?? 0,
    };
    await store.cloudChanges.recordRemoteBookRevisions(revisions);
    final localSnapshot = store.cloudChanges.snapshot;
    final dirty = <String>{
      ...localSnapshot.bookIds,
      ...localSnapshot.wordIdsByBook.keys,
      ...localSnapshot.deletedWordIdsByBook.keys,
      ...localSnapshot.deletedBookIds,
    };
    final changed = await store.mergeManagedBooks(
      remote,
      locallyDirtyBookIds: dirty,
    );
    await store.cloudChanges
        .recordDiagnostic('managed_books_download_succeeded', data: {
      'reason': reason,
      'remoteBookCount': remote.length,
      'mergedBookCount': changed,
    });
  }

  Map<String, Object?> _learningStateMetrics() {
    final payload = store.toLearningStateJson();
    final wordStates = payload['wordStates'];
    var wordCount = 0;
    var bookCount = 0;
    if (wordStates is Map) {
      bookCount = wordStates.length;
      for (final words in wordStates.values) {
        if (words is Map) wordCount += words.length;
      }
    }
    try {
      final bytes = utf8.encode(jsonEncode(payload)).length;
      return {
        'jsonEncodable': true,
        'utf8Bytes': bytes,
        'bookCount': bookCount,
        'wordStateCount': wordCount,
        'completedCount': (payload['completed'] as List?)?.length ?? 0,
        'activeStudyCount': (payload['activeStudies'] as Map?)?.length ?? 0,
        'studyEventCount': (payload['studyEventLog'] as List?)?.length ?? 0,
        'dailyStatCount': (payload['dailyStudyStats'] as Map?)?.length ?? 0,
      };
    } catch (error) {
      return {
        'jsonEncodable': false,
        'encodingError': error.toString(),
        'bookCount': bookCount,
        'wordStateCount': wordCount,
      };
    }
  }

  Future<void> _sendLearningState({required String reason}) async {
    final current = user;
    if (current == null || !store.cloudChanges.learningStateDirty) return;
    final snapshot = store.cloudChanges.snapshot;
    final metrics = _learningStateMetrics();
    await store.cloudChanges.recordLog(
      '$reason · learningState 전송 시작 · 순번 ${snapshot.learningStateGeneration} · ${metrics['utf8Bytes'] ?? '?'} bytes',
    );
    await store.cloudChanges
        .recordDiagnostic('sync_upload_payload_prepared', data: {
      'reason': reason,
      'learningStateGeneration': snapshot.learningStateGeneration,
      'pendingCount': snapshot.pendingCount,
      ...metrics,
    });
    if (metrics['jsonEncodable'] != true) {
      throw StateError('learningState JSON 직렬화에 실패했습니다.');
    }
    await store.cloudChanges.recordDiagnostic('sync_upload_started', data: {
      'reason': reason,
      'learningStateGeneration': snapshot.learningStateGeneration,
      'pendingCount': snapshot.pendingCount,
      ...metrics,
    });
    await cloud.uploadLearningState(store, snapshot);
    await store.cloudChanges.acknowledgeLearningState(snapshot);
    await store.cloudChanges.recordSuccess(current.uid, _now());
    _lastSuccessAt = _now();
    await store.cloudChanges.recordLog('$reason · learningState 전송 완료');
    await store.cloudChanges.recordDiagnostic('sync_upload_succeeded', data: {
      'reason': reason,
      'learningStateGeneration': snapshot.learningStateGeneration,
      ...metrics,
    });
  }

  Future<void> _recordFailure(
    Object error,
    String reason, {
    StackTrace? stackTrace,
  }) async {
    final current = user;
    final generation = store.cloudChanges.snapshot.learningStateGeneration;
    if (_failedGeneration != generation) {
      _failedGeneration = generation;
      _failureCount = 0;
      _retryBudgetExhausted = false;
    }
    if (current != null)
      await store.cloudChanges.recordError(current.uid, error);
    final stackPreview = stackTrace
        ?.toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(8)
        .join('\n');
    await store.cloudChanges.recordLog(
      '$reason · learningState 오류 · 세대 $generation · ${error.runtimeType} · $error',
    );
    await store.cloudChanges.recordDiagnostic('sync_failed', data: {
      'reason': reason,
      'generation': generation,
      'error': error.toString(),
      'errorType': error.runtimeType.toString(),
      'stackPreview': stackPreview,
      'failureCountBefore': _failureCount,
    });
    const delays = [
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 30),
    ];
    _failureCount++;
    final retryable = store.cloudChanges.learningStateDirty ||
        store.cloudChanges.archiveContentDirty ||
        (store.cloudChanges.managedBookContentDirty &&
            error is! ManagedBookConflictException);
    if (_failureCount <= delays.length && accountBookSyncEnabled && retryable) {
      _schedule(
        delays[_failureCount - 1],
        reason: '자동 재시도 $_failureCount/${delays.length}',
        isRetry: true,
      );
      return;
    }
    _retryBudgetExhausted = true;
    await store.cloudChanges.recordLog(
      '$reason · 자동 재시도 한도 도달 · 새 학습 변경 또는 수동 전송 대기',
    );
    await store.cloudChanges.recordDiagnostic('sync_retry_paused', data: {
      'reason': reason,
      'generation': generation,
      'failureCount': _failureCount,
      'retryBudgetExhausted': _retryBudgetExhausted,
    });
  }

  void _cancelScheduledUpload() {
    _timer?.cancel();
    _timer = null;
    _scheduledGeneration = null;
    _scheduledIsRetry = false;
  }

  Future<bool> _networkAllowed() async {
    final results = await connectivity.checkConnectivity();
    if (networkPolicy == AutoBackupNetworkPolicy.all) {
      // VPN and Android's per-app routing can transiently report `none` even
      // while Firebase is reachable. Let the actual request decide in this
      // permissive mode; failures are still logged and retried.
      return true;
    }
    return results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(store.cloudChanges.recordDiagnostic('app_lifecycle', data: {
      'state': state.name,
      'pendingLearningState': store.cloudChanges.learningStateDirty,
    }));
    if (state == AppLifecycleState.resumed) {
      unawaited(mergeFromCloud(uploadMerged: false, reason: '앱 복귀'));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(
          store.cloudChanges.recordLog('앱 백그라운드 · learningState 즉시 전송 시도'));
      unawaited(flushPendingBackup());
    }
  }
}
