import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/excel_parser.dart';

void main() {
  test('xlsx rows are converted to words', () {
    final workbook = Excel.createExcel();
    final sheet = workbook['Sheet1'];
    sheet.appendRow([
      TextCellValue('term'),
      TextCellValue('meaning'),
      TextCellValue('reading'),
      TextCellValue('example'),
      TextCellValue('exampleMeaning'),
    ]);
    sheet.appendRow([
      TextCellValue('apple'),
      TextCellValue('사과'),
      TextCellValue('애플'),
      TextCellValue('I ate an apple.'),
      TextCellValue('나는 사과를 먹었다.'),
    ]);

    final bytes = workbook.encode();
    expect(bytes, isNotNull);
    final words = parseWordsXlsx(bytes!);

    expect(words, hasLength(1));
    expect(words.single.term, 'apple');
    expect(words.single.meaning, '사과');
    expect(words.single.reading, '애플');
    expect(words.single.example, 'I ate an apple.');
  });
}
