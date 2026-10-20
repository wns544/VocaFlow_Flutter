import 'dart:convert';
import 'dart:io';
import 'package:vocaflow/reference_correction.dart';

/// Input: {baseline: [...], current: [...], proposed: [...]}.
/// Output is a JSON report on stdout only; there are no Firebase dependencies.
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
        'Usage: dart tools/plan_reference_corrections.dart input.json');
    exitCode = 64;
    return;
  }
  try {
    final input = jsonDecode(File(args.single).readAsStringSync()) as Map;
    List<Map<String, dynamic>> rows(String key) => (input[key] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(
        planReferenceCorrections(
            baseline: rows('baseline'),
            current: rows('current'),
            proposed: rows('proposed'))));
  } catch (error) {
    stderr.writeln('No changes made: $error');
    exitCode = 1;
  }
}
