import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'cloud_backup.dart';
import 'cloud_change_tracker.dart';
import 'store.dart';

enum InitialSyncChoice { cloudReplace, merge }

/// Synchronizes only the dedicated learningState collection. It deliberately
/// never uploads vocabBooks/words, so existing Firebase card documents remain
/// read-only from this app version.
class AutoBackupCoordinator with WidgetsBindingObserver {
  static AutoBackupCoordinator? activeInstance;

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

  Timer? _timer;
  int? _scheduledGeneration;
  bool _scheduledIsRetry = false;
  int? _failedGeneration;
  bool _retryBudgetExhausted = false;
  StreamSubscription<User?>? _authSubscription;
  bool _syncing = false;
  bool _downloading = false;
  bool _flushingForBackground = false;
  DateTime? _lastSuccessAt;
  int _failureCount = 0;
  Future<void>? _webInitialSync;

  bool get isUploading => _syncing && !_downloading;
  bool get isDownloading => _downloading;
  User? get user => FirebaseAuth.instance.currentUser;
  bool get enabled => user != null && store.cloudChanges.isEnabled(user!.uid);
  bool get initialized =>
      user != null && store.cloudChanges.isInitialized(user!.uid);
  int get pendingCount => store.cloudChanges.learningStateDirty ? 1 : 0;
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
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((_) {
      _cancelScheduledUpload();
      _startWebInitialSyncIfNeeded();
      if (enabled && initialized) {
        unawaited(mergeFromCloud(uploadMerged: false, reason: '앱 복귀'));
        unawaited(_seedLearningState());
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
    _cancelScheduledUpload();
    _authSubscription?.cancel();
  }

  Future<bool> hasCloudBackup() => cloud.hasLearningState();

  Future<void> initialize(InitialSyncChoice? choice) async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    final hasCloud = await cloud.hasLearningState();
    if (hasCloud && choice == null) return;
    if (hasCloud) {
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
    await store.cloudChanges.markLearningState();
    await _uploadPending(reason: '이 기기 데이터 내보내기');
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
    if (!enabled || !initialized || _syncing) return;
    _syncing = true;
    try {
      await _pullLearningState(reason: reason, ownsGate: true);
      if (uploadMerged && store.cloudChanges.learningStateDirty) {
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
        !enabled ||
        !store.cloudChanges.learningStateDirty) return;
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
    if (enabled && store.cloudChanges.learningStateDirty && !_syncing) {
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
        !enabled ||
        !store.cloudChanges.learningStateDirty) return;
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
    if (_syncing || !enabled || !store.cloudChanges.learningStateDirty) return;
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
      // Pull first. Each phone later writes only its own document, never a
      // shared profile or another phone's snapshot.
      await _pullLearningState(reason: '$reason · 선행 병합', ownsGate: true);
      await _sendLearningState(reason: reason);
      _failureCount = 0;
      _failedGeneration = null;
      _retryBudgetExhausted = false;
    } catch (error, stackTrace) {
      failed = true;
      await _recordFailure(error, reason, stackTrace: stackTrace);
    } finally {
      _syncing = false;
      final generationNow = store.cloudChanges.snapshot.learningStateGeneration;
      if (!failed && enabled && store.cloudChanges.learningStateDirty) {
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
  }) async {
    if (!ownsGate && _syncing) return;
    if (!ownsGate) _syncing = true;
    _downloading = true;
    try {
      await store.cloudChanges.recordLog('$reason · learningState 내려받기 시작');
      await store.cloudChanges.recordDiagnostic('sync_download_started', data: {
        'reason': reason,
      });
      final snapshots = await cloud.downloadLearningStates();
      await store.applyLearningStateSnapshots(snapshots);
      final current = user;
      if (current != null) {
        await store.cloudChanges.recordDownload(current.uid, _now());
      }
      await store.cloudChanges.recordLog('$reason · learningState 병합 완료');
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
    if (_failureCount <= delays.length &&
        enabled &&
        store.cloudChanges.learningStateDirty) {
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
