import 'dart:async';

import 'cloud_change_tracker.dart';

/// Device-local navigation black box. Events use the existing 64 MB
/// diagnostic journal and never write Firestore card documents.
class NavigationTrace {
  static CloudChangeTracker? _tracker;
  static final _pending = <({String event, Map<String, Object?> data})>[];

  static void bind(CloudChangeTracker tracker) {
    _tracker = tracker;
    for (final entry in List.of(_pending)) {
      unawaited(tracker.recordDiagnostic(entry.event, data: entry.data));
    }
    _pending.clear();
  }

  static void record(String event, [Map<String, Object?> data = const {}]) {
    final tracker = _tracker;
    if (tracker == null) {
      if (_pending.length < 80) _pending.add((event: event, data: data));
      return;
    }
    unawaited(tracker.recordDiagnostic(event, data: data));
  }
}

class NavigationBackGate {
  NavigationBackGate({this.window = const Duration(milliseconds: 420)});

  final Duration window;
  DateTime? _lastAcceptedAt;

  void reset(String reason) {
    NavigationTrace.record('navigation_back_gate_reset', {'reason': reason});
    _lastAcceptedAt = null;
  }

  /// A modal sheet is normally popped directly by Navigator, so its parent
  /// [PopScope] cannot reserve the next back event itself. Record that pop
  /// here so a duplicate Android gesture cannot immediately pop the parent.
  void reserveAfterRoutePop({
    required String route,
    required String routeType,
    String? previousRoute,
  }) {
    _lastAcceptedAt = DateTime.now();
    NavigationTrace.record('navigation_route_pop_reserved', {
      'route': route,
      'routeType': routeType,
      'previousRoute': previousRoute,
      'windowMs': window.inMilliseconds,
    });
  }
  bool accept(String source, {Map<String, Object?> data = const {}}) {
    final now = DateTime.now();
    final previous = _lastAcceptedAt;
    final delta =
        previous == null ? null : now.difference(previous).inMilliseconds;
    final accepted = previous == null || now.difference(previous) >= window;
    NavigationTrace.record(
      accepted ? 'navigation_back_accepted' : 'navigation_back_suppressed',
      {
        'source': source,
        'deltaMs': delta,
        'windowMs': window.inMilliseconds,
        ...data
      },
    );
    if (accepted) _lastAcceptedAt = now;
    return accepted;
  }
}

final navigationBackGate = NavigationBackGate();
