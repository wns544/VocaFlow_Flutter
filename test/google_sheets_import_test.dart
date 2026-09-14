import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vocaflow/google_sheets_import.dart';

void main() {
  test('Google Sheets link becomes CSV export URL', () {
    final source = GoogleSheetsSource.fromInput(
        'https://docs.google.com/spreadsheets/d/sheet_123-ABC/edit#gid=77');

    expect(source.downloadUri.host, 'docs.google.com');
    expect(source.downloadUri.path, '/spreadsheets/d/sheet_123-ABC/export');
    expect(source.downloadUri.queryParameters, {'format': 'csv', 'gid': '77'});
  });

  test('Google Sheets gid query becomes CSV export gid', () {
    final source = GoogleSheetsSource.fromInput(
        'https://docs.google.com/spreadsheets/d/sheet_123/edit?gid=77#gid=77');

    expect(source.downloadUri.queryParameters, {'format': 'csv', 'gid': '77'});
  });

  test('direct CSV URLs are accepted', () {
    final source =
        GoogleSheetsSource.fromInput('https://example.com/words.csv');

    expect(source.downloadUri.toString(), 'https://example.com/words.csv');
  });

  test('published Google Sheets CSV URL stays a direct download URL', () {
    final source = GoogleSheetsSource.fromInput(
        'https://docs.google.com/spreadsheets/d/e/published_id/pub?output=csv');

    expect(source.downloadUri.path, '/spreadsheets/d/e/published_id/pub');
    expect(source.downloadUri.queryParameters['output'], 'csv');
  });

  test('download parses a shared sheet CSV into the existing import result',
      () async {
    final importer = GoogleSheetsImporter(
      get: (_) async => http.Response.bytes(
        utf8.encode(
            'term,meaning,reading,relatedWords\n貢献,공헌,こうけん,寄与\n寄与,기여,きよ,'),
        200,
      ),
    );

    final download = await importer.download('https://example.com/words.csv');

    expect(download.importResult.words, hasLength(2));
    expect(download.importResult.relations.single.targetTerm, '寄与');
    expect(download.skippedRows, 0);
  });

  test('non-CSV non-Google links are rejected', () {
    expect(
      () => GoogleSheetsSource.fromInput('https://example.com/words.html'),
      throwsA(isA<GoogleSheetsImportException>()),
    );
  });
}
