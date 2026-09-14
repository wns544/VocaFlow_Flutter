import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/sync_diagnostic_log.dart';

void main() {
  test('diagnostic records retain device, sequence, event and payload',
      () async {
    final directory = await Directory.systemTemp.createTemp('vocaflow-diag-');
    addTearDown(() => directory.delete(recursive: true));
    final log = SyncDiagnosticLog(directoryProvider: () async => directory);

    await log.record(
      deviceId: 'phone-a',
      sequence: 42,
      event: 'card_decision',
      data: {'wordId': 77, 'decision': 'memorized'},
      timestamp: DateTime.utc(2026, 9, 13),
    );

    final lines = await log.readRecent();
    final entry = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(entry['deviceId'], 'phone-a');
    expect(entry['sequence'], 42);
    expect(entry['event'], 'card_decision');
    expect(entry['data'], containsPair('wordId', 77));
  });

  test('diagnostic journal can be cleared after export', () async {
    final directory = await Directory.systemTemp.createTemp('vocaflow-diag-');
    addTearDown(() => directory.delete(recursive: true));
    final log = SyncDiagnosticLog(directoryProvider: () async => directory);
    await log.record(deviceId: 'phone-a', sequence: 1, event: 'started');
    expect(await log.exportText(), isNotEmpty);
    await log.clear();
    expect(await log.readAll(), isEmpty);
  });
}
