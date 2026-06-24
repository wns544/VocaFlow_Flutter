import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import 'backup_merge.dart';
import 'cloud_backup.dart';
import 'cloud_change_tracker.dart';
import 'store.dart';

enum InitialSyncChoice { cloudReplace, merge }

class AutoBackupCoordinator with WidgetsBindingObserver {
  static AutoBackupCoordinator? activeInstance;

  AutoBackupCoordinator({
    required this.store,
    this.onChanged,
    CloudBackup? cloud,
    Connectivity? connectivity,
    DateTime Function()? now,
    this.idleDelay = const Duration(seconds: 60),
    this.minimumInterval = const Duration(minutes: 5),
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
  StreamSubscription<User?>? _authSubscription;
  bool _uploading = false;
  int _failureCount = 0;

  bool get isUploading => _uploading;
  User? get user => FirebaseAuth.instance.currentUser;
  bool get enabled => user != null && store.cloudChanges.isEnabled(user!.uid);
  bool get initialized =>
      user != null && store.cloudChanges.isInitialized(user!.uid);
  int get pendingCount => store.cloudChanges.pendingCount;
  DateTime? get lastSuccess =>
      user == null ? null : store.cloudChanges.lastSuccess(user!.uid);
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
      _timer?.cancel();
      onChanged?.call();
      if (enabled && pendingCount > 0) requestImmediateBackup();
    });
    if (enabled && pendingCount > 0) requestImmediateBackup();
  }

  void dispose() {
    if (activeInstance == this) activeInstance = null;
    WidgetsBinding.instance.removeObserver(this);
    if (store.cloudChanges.onChanged == _handleTrackedChange) {
      store.cloudChanges.onChanged = null;
    }
    store.onSessionCompleted = null;
    _timer?.cancel();
    _authSubscription?.cancel();
  }

  Future<bool> hasCloudBackup() => cloud.hasBackup();

  Future<void> initialize(InitialSyncChoice? choice) async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    final hasCloud = await cloud.hasBackup();
    if (hasCloud && choice == null) return;

    if (!hasCloud) {
      await cloud.upload(store);
    } else if (choice == InitialSyncChoice.cloudReplace) {
      final backup = await cloud.downloadBackupJson();
      await store.replaceWithBackupJson(backup);
    } else {
      final local = store.toBackupJson();
      final remote = await cloud.downloadBackupJson();
      final merged = mergeBackupJson(cloud: remote, local: local);
      await store.replaceWithBackupJson(merged);
      await cloud.upload(store);
    }
    await store.cloudChanges.clearPending();
    await store.cloudChanges.setInitialized(current.uid, true);
    await store.cloudChanges.setEnabled(current.uid, true);
    await store.cloudChanges.recordSuccess(current.uid, _now());
    onChanged?.call();
  }

  Future<void> setEnabled(bool value) async {
    final current = user;
    if (current == null) return;
    await store.cloudChanges.setEnabled(current.uid, value);
    if (!value) {
      _timer?.cancel();
    } else if (pendingCount > 0) {
      requestImmediateBackup();
    }
    onChanged?.call();
  }

  Future<void> setNetworkPolicy(AutoBackupNetworkPolicy value) async {
    final current = user;
    if (current == null) return;
    await store.cloudChanges.setNetworkPolicy(current.uid, value);
    if (enabled && pendingCount > 0) requestImmediateBackup();
    onChanged?.call();
  }

  Future<void> manualFullUpload() async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    await cloud.upload(store);
    await store.cloudChanges.clearPending();
    await store.cloudChanges.recordSuccess(current.uid, _now());
    _failureCount = 0;
    onChanged?.call();
  }

  Future<void> manualRestore() async {
    final current = user;
    if (current == null) throw StateError('Google login is required.');
    final backup = await cloud.downloadBackupJson();
    await store.replaceWithBackupJson(backup);
    await store.cloudChanges.clearPending();
    await store.cloudChanges.recordSuccess(current.uid, _now());
    _failureCount = 0;
    onChanged?.call();
  }

  void requestImmediateBackup() => _schedule(Duration.zero);

  void _handleTrackedChange() {
    onChanged?.call();
    if (enabled && pendingCount > 0 && !_uploading) _schedule(idleDelay);
  }

  void _schedule(Duration requestedDelay) {
    if (!enabled || pendingCount == 0) return;
    final last = lastSuccess;
    var delay = requestedDelay;
    if (last != null) {
      final untilAllowed = last.add(minimumInterval).difference(_now());
      if (untilAllowed > delay) delay = untilAllowed;
    }
    if (delay.isNegative) delay = Duration.zero;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(_uploadPending()));
  }

  Future<void> _uploadPending() async {
    final current = user;
    if (_uploading || current == null || !enabled || pendingCount == 0) return;
    bool networkAllowed;
    try {
      networkAllowed = await _networkAllowed();
    } catch (error) {
      await _scheduleRetry(error);
      return;
    }
    if (!networkAllowed) {
      await _scheduleRetry(StateError('선택한 네트워크에 연결되어 있지 않습니다.'));
      return;
    }

    final changes = store.cloudChanges.snapshot;
    _uploading = true;
    onChanged?.call();
    try {
      await cloud.uploadIncremental(store, changes);
      await store.cloudChanges.acknowledge(changes);
      await store.cloudChanges.recordSuccess(current.uid, _now());
      _failureCount = 0;
      if (pendingCount > 0) _schedule(idleDelay);
    } catch (error) {
      await _scheduleRetry(error);
    } finally {
      _uploading = false;
      onChanged?.call();
    }
  }

  Future<void> _scheduleRetry(Object error) async {
    final current = user;
    if (current != null) {
      await store.cloudChanges.recordError(current.uid, error);
    }
    const retryDelays = [
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 30),
    ];
    final index = _failureCount.clamp(0, retryDelays.length - 1);
    _failureCount++;
    _timer?.cancel();
    _timer = Timer(retryDelays[index], () => unawaited(_uploadPending()));
  }

  Future<bool> _networkAllowed() async {
    final results = await connectivity.checkConnectivity();
    if (networkPolicy == AutoBackupNetworkPolicy.all) {
      return results.any((result) => result != ConnectivityResult.none);
    }
    return results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (enabled && pendingCount > 0) requestImmediateBackup();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      final recent = lastSuccess;
      if (enabled &&
          pendingCount > 0 &&
          (recent == null || _now().difference(recent) >= idleDelay)) {
        unawaited(_uploadPending());
      }
    }
  }
}
