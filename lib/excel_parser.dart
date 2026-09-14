import 'package:excel/excel.dart';

import 'csv_parser.dart';
import 'models.dart';

List<Word> parseWordsXlsx(List<int> bytes) {
  return parseWordImportXlsx(bytes).words;
}

WordImportResult parseWordImportXlsx(List<int> bytes) {
  final workbook = Excel.decodeBytes(bytes);
  for (final sheetName in workbook.tables.keys) {
    final sheet = workbook.tables[sheetName];
    if (sheet == null || sheet.rows.isEmpty) continue;

    final rows = sheet.rows
        .map((row) => row
            .map((cell) => cell?.value?.toString() ?? '')
            .toList(growable: false))
        .toList(growable: false);
    final result = parseWordImportRows(rows);
    if (result.words.isNotEmpty) return result;
  }
  return const WordImportResult(words: []);
}
