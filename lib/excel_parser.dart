import 'package:excel/excel.dart';

import 'csv_parser.dart';
import 'models.dart';

List<Word> parseWordsXlsx(List<int> bytes) {
  final workbook = Excel.decodeBytes(bytes);
  for (final sheetName in workbook.tables.keys) {
    final sheet = workbook.tables[sheetName];
    if (sheet == null || sheet.rows.isEmpty) continue;

    final rows = sheet.rows
        .map((row) => row
            .map((cell) => cell?.value?.toString() ?? '')
            .toList(growable: false))
        .toList(growable: false);
    final words = parseWordRows(rows);
    if (words.isNotEmpty) return words;
  }
  return [];
}
