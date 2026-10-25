import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

class BoundedPerformanceEvents {
  BoundedPerformanceEvents({this.limit = 2 * 1024 * 1024});
  final int limit;
  final List<Map<String, Object?>> entries = [];
  int bytes = 0;
  int dropped = 0;
  void add(Map<String, Object?> entry) {
    final length = utf8.encode(jsonEncode(entry)).length;
    if (bytes + length > limit) {
      dropped++;
      return;
    }
    bytes += length;
    entries.add(entry);
  }

  void clear() {
    entries.clear();
    bytes = 0;
    dropped = 0;
  }
}

/// Opt-in, bounded instrumentation. Never uses preferences or the sync log.
/// Release and web builds cannot start a capture, even with the build flag.
class PerformanceProbe extends ChangeNotifier {
  static final instance = PerformanceProbe();
  static const supported =
      !kIsWeb && kProfileMode && bool.fromEnvironment('VOCA_PERFORMANCE_PROBE');
  static const channel = MethodChannel('com.vocaflow.app/performance');
  static const maxBytes = 2 * 1024 * 1024;
  final _buffer = BoundedPerformanceEvents();
  final Map<String, int> pending = {};
  Map<String, Object?> Function()? stateProvider;
  int _epoch = 0;
  int get dropped => _buffer.dropped;
  bool recording = false;
  bool busy = false;
  String status = '측정 꺼짐';
  Timer? _deadline;
  Timer? _sampleTimer;
  bool _sampling = false;
  Future<void>? _stopping;
  bool _extensionRegistered = false;

  static Future<T> measure<T>(String name, Future<T> Function() action,
      {Map<String, Object?> data = const {}}) {
    if (!supported || !instance.recording) return action();
    return _measureActive(name, action, data);
  }

  static Future<T> _measureActive<T>(String name, Future<T> Function() action,
      Map<String, Object?> data) async {
    final probe = instance;
    final epoch = probe._epoch;
    final watch = Stopwatch()..start();
    final task = developer.TimelineTask()..start(name, arguments: data);
    var failed = false;
    try {
      return await action();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      task.finish();
      if (epoch == probe._epoch) {
        probe.event(name, {
          ...data,
          'elapsedUs': watch.elapsedMicroseconds,
          'failed': failed
        });
      }
    }
  }

  static String keyKind(String key) {
    if (key == 'books') return 'books';
    if (key.startsWith('accountState.')) return 'account';
    if (key.startsWith('sync.v2.replica')) return 'replica';
    if (key.startsWith('sync.v2.checkpoint.')) return 'checkpoint';
    return 'other';
  }

  void event(String name, [Map<String, Object?> data = const {}]) {
    if (!recording) return;
    final entry = <String, Object?>{
      'event': name,
      'timeUs': developer.Timeline.now,
      'data': data
    };
    _buffer.add(entry);
  }

  void queue(String name, int delta) {
    if (!supported) return;
    pending[name] = (pending[name] ?? 0) + delta;
    event('queue', {'name': name, 'pending': pending[name]});
  }

  Future<void> prepareRecovery() async {
    if (!supported) return;
    await channel.invokeMethod<void>('prepareRecovery');
    if (!_extensionRegistered) {
      developer.registerExtension('ext.vocaflow.performance',
          (method, params) async {
        switch (params['command']) {
          case 'startBaseline':
            await start(javaSampling: false);
          case 'startJava':
            await start(javaSampling: true);
          case 'stop':
            await stop();
          case 'status':
            break;
          default:
            return developer.ServiceExtensionResponse.error(
                developer.ServiceExtensionResponse.invalidParams,
                'Unknown measurement command');
        }
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'recording': recording,
          'busy': busy,
          'status': status,
          'pending': pending,
          'application': stateProvider?.call(),
        }));
      });
      _extensionRegistered = true;
    }
  }

  Future<void> start({required bool javaSampling}) async {
    if (!supported || busy || recording) return;
    busy = true;
    notifyListeners();
    try {
      await channel.invokeMethod<void>('start', {'javaSampling': javaSampling});
      _buffer.clear();
      _epoch++;
      recording = true;
      SchedulerBinding.instance.addTimingsCallback(_frames);
      status = javaSampling ? '30초 함수 추적 중' : '30초 비교 측정 중';
      event('capture_start', {
        'javaSampling': javaSampling,
        'pendingAtStart': Map.of(pending),
        'wallTimeUtc': DateTime.now().toUtc().toIso8601String()
      });
      _sampleTimer =
          Timer.periodic(const Duration(seconds: 1), (_) => _sample());
      _deadline = Timer(const Duration(seconds: 30), () => unawaited(stop()));
      unawaited(_sample());
    } catch (error) {
      status = '측정 시작 실패: $error';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _sample() async {
    if (!recording || _sampling) return;
    _sampling = true;
    try {
      final raw = await channel.invokeMapMethod<String, Object?>('sample');
      event('process_sample', raw ?? const {});
      if (stateProvider != null) event('application_sample', stateProvider!());
      if (((raw?['temperatureTenths'] as num?)?.toInt() ?? 0) >= 395) {
        status = '39.5°C 도달: 측정을 중단합니다';
        unawaited(stop());
      } else if (raw?['nativeCaptureActive'] == false && recording) {
        unawaited(stop());
      }
    } catch (_) {
      event('sample_unavailable');
    } finally {
      _sampling = false;
    }
  }

  void _frames(List<FrameTiming> timings) {
    for (final frame in timings) {
      event('frame', {
        'buildUs': frame.buildDuration.inMicroseconds,
        'rasterUs': frame.rasterDuration.inMicroseconds
      });
    }
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    if (!recording) return Future<void>.value();
    _stopping = _stop().whenComplete(() => _stopping = null);
    return _stopping!;
  }

  Future<void> _stop() async {
    _deadline?.cancel();
    _sampleTimer?.cancel();
    event('capture_stop', {'dropped': dropped, 'pending': Map.of(pending)});
    recording = false;
    SchedulerBinding.instance.removeTimingsCallback(_frames);
    busy = true;
    notifyListeners();
    try {
      // Snapshot bounded data once, after collection, away from prefs/logs.
      final result = await channel.invokeMethod<String>('stop', {
        'events': _buffer.entries.map(jsonEncode).join('\n'),
        'dropped': dropped,
      });
      status = '측정 파일 저장됨: $result';
    } catch (error) {
      status = '측정 종료/내보내기 실패: $error';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
