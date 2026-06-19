import 'dart:typed_data';

import 'package:excel/excel.dart';

import 'models.dart';

Uint8List createWordBookXlsx(WordBook book) {
  final workbook = Excel.createExcel();
  final sheet = workbook['Sheet1'];

  sheet.appendRow([
    TextCellValue('term'),
    TextCellValue('meaning'),
    TextCellValue('reading'),
    TextCellValue('example'),
    TextCellValue('exampleMeaning'),
  ]);

  for (final word in book.words) {
    sheet.appendRow([
      TextCellValue(word.term),
      TextCellValue(word.meaning),
      TextCellValue(word.reading),
      TextCellValue(word.example),
      TextCellValue(word.exampleMeaning),
    ]);
  }

  final bytes = workbook.encode();
  if (bytes == null) {
    throw StateError('Excel 파일을 생성하지 못했습니다.');
  }
  return Uint8List.fromList(bytes);
}
