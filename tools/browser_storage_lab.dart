// Real IndexedDB / Web Locks tests, isolated from application data and Firebase.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'package:vocaflow/web_durable_storage.dart';
import 'package:vocaflow/web_writer_guard_web.dart';

@JS('labFault')
external void labFault(JSString mode);
@JS('labUncaught')
external JSNumber labUncaught();

const storage = WebDurableStorage(databaseName: 'vocaflow.isolated-lab.v1');
final guard = WebWriterGuard(name: 'vocaflow.isolated-lab.writer');
final result = html.document.querySelector('#result')!;
Map<String, dynamic> snapshot = {};
final label = Uri.base.queryParameters['tab'] ?? 'A';

void show(Object value) {
  result.text = jsonEncode(value);
  if (value is Map && value['result'] != null) {
    html.document.body!.dataset['result'] = '${value['result']}';
  }
}

Future<Map<String, dynamic>> disk() async =>
    jsonDecode(await storage.read('journal') ?? '{}') as Map<String, dynamic>;

void button(String label, Future<void> Function() action) {
  final control = html.ButtonElement()..text = label;
  html.document.querySelector('#controls')!.append(control);
  control.onClick.listen((_) async {
    try {
      await action().timeout(const Duration(seconds: 10));
    } catch (error) {
      show({'result': 'ERROR', 'detail': '$error'});
    }
  });
  if (label == 'Run transaction tests' &&
      Uri.base.queryParameters['auto'] == 'true') {
    scheduleMicrotask(control.click);
  }
}

Future<void> main() async {
  snapshot = await disk();
  button('Write stale snapshot', () async {
    // Reproduces the application's previous whole-journal write algorithm.
    snapshot[label] = 'pending-$label';
    await storage.write('journal', jsonEncode(snapshot));
    show({'tab': label, 'unprotectedDisk': await disk()});
  });
  button('Read disk', () async => show({'disk': await disk()}));
  button('Acquire writer', () async {
    await guard.acquire();
    // Application acquires BEFORE its initial cache/journal read.
    snapshot = await disk();
    show({'writer': 'ACQUIRED', 'tab': label, 'freshSnapshot': snapshot});
  });
  button('Guarded save', () async {
    await guard.acquire();
    snapshot = await disk();
    snapshot['guarded-$label'] = 'pending-$label';
    await storage.write('journal', jsonEncode(snapshot));
    show({'guardedDisk': await disk()});
  });
  button('Run transaction tests', () async {
    final checks = <String>[];
    await storage.write('fault-test', 'original');
    if (await storage.read('fault-test') != 'original') {
      throw StateError('read');
    }
    checks.add('write/read committed');
    for (final mode in ['quota', 'abort']) {
      Object? failure;
      labFault(mode.toJS);
      try {
        await storage
            .write('fault-test', 'must-not-commit')
            .timeout(const Duration(seconds: 3));
      } catch (error) {
        failure = error;
      } finally {
        labFault('none'.toJS);
      }
      if (failure == null || failure is TimeoutException) {
        throw StateError('$mode did not fail promptly: $failure');
      }
      if (await storage.read('fault-test') != 'original') {
        throw StateError('$mode destroyed prior durable value');
      }
      checks.add('$mode rejected / prior value preserved');
    }
    await storage.write('fault-test', 'retry');
    if (await storage.read('fault-test') != 'retry') throw StateError('retry');
    checks.add('retry committed');
    await storage.remove('fault-test');
    if (await storage.read('fault-test') != null) throw StateError('remove');
    checks.add('remove committed');
    // Let any unhandled request rejection reach the browser event loop.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final uncaught = labUncaught().toDartInt;
    if (uncaught != 0) throw StateError('$uncaught unhandled browser errors');
    checks.add('zero unhandled errors');
    show({'result': 'PASS', 'checks': checks, 'firebaseWrites': 0});
  });
  show({'tab': label, 'loadedSnapshot': snapshot, 'firebaseWrites': 0});
}
