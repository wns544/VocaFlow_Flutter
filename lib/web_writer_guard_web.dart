// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:js_interop';
import 'web_writer_guard_types.dart';

@JS('navigator.locks')
external _LockManager? get _locks;

extension type _LockManager(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
      JSString name, JSObject options, JSFunction callback);
}

/// One writer for the whole origin: learning replicas and pending journals share
/// browser storage even across accounts. Never steal or time-expire this lock.
/// The browser releases it when the owning document is destroyed.
class WebWriterGuard {
  WebWriterGuard({this.name = 'vocaflow.browser-writer.v1'});
  final String name;
  bool _held = false;
  Future<void>? _acquiring;

  Future<void> acquire() async {
    if (_held) return;
    final existing = _acquiring;
    if (existing != null) return existing;
    final attempt = _acquire();
    _acquiring = attempt;
    try {
      await attempt;
    } finally {
      _acquiring = null;
    }
  }

  Future<void> _acquire() async {
    final locks = _locks;
    if (locks == null) {
      throw const WebWriterUnavailable(unsupported: true);
    }
    final decision = Completer<void>();
    final callback = ((JSAny? lock) {
      if (lock == null) {
        decision.completeError(const WebWriterUnavailable());
        return null;
      }
      _held = true;
      decision.complete();
      return JSPromise<JSAny?>(
          ((JSFunction resolve, JSFunction reject) {}).toJS);
    }).toJS;
    try {
      final promise = locks.request(
          name.toJS, {'ifAvailable': true}.jsify() as JSObject, callback);
      // Request remains pending for the document lifetime when we own the lock.
      unawaited(promise.toDart.then<void>((_) {},
          onError: (Object error, StackTrace stack) {
        if (!decision.isCompleted) {
          decision.completeError(
              const WebWriterUnavailable(unsupported: true), stack);
        }
      }));
    } catch (_) {
      if (!decision.isCompleted) {
        decision.completeError(const WebWriterUnavailable(unsupported: true));
      }
    }
    await decision.future.timeout(const Duration(seconds: 5), onTimeout: () {
      throw const WebWriterUnavailable(unsupported: true);
    });
  }
}

final _writer = WebWriterGuard();
Future<void> ensureWebWriter() => _writer.acquire();
