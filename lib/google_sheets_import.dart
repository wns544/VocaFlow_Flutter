import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'csv_parser.dart';

class GoogleSheetsImportException implements Exception {
  const GoogleSheetsImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A validated remote CSV source. Google Sheets share URLs are converted to
/// their CSV export endpoint; ordinary HTTPS CSV links are kept unchanged.
class GoogleSheetsSource {
  const GoogleSheetsSource({
    required this.downloadUri,
    required this.suggestedBookName,
  });

  final Uri downloadUri;
  final String suggestedBookName;

  factory GoogleSheetsSource.fromInput(String rawInput) {
    final input = rawInput.trim();
    final uri = Uri.tryParse(input);
    if (uri == null ||
        (uri.scheme.toLowerCase() != 'https' &&
            uri.scheme.toLowerCase() != 'http') ||
        uri.host.isEmpty) {
      throw const GoogleSheetsImportException(
          'Google 스프레드시트 또는 CSV 링크를 확인해 주세요.');
    }

    final spreadsheetId = _spreadsheetIdFrom(uri);
    if (spreadsheetId != null) {
      final gid = _gidFrom(uri);
      final parameters = <String, String>{'format': 'csv'};
      if (gid != null && gid.isNotEmpty) parameters['gid'] = gid;
      return GoogleSheetsSource(
        downloadUri: Uri.https(
          'docs.google.com',
          '/spreadsheets/d/$spreadsheetId/export',
          parameters,
        ),
        suggestedBookName: 'Google 스프레드시트',
      );
    }

    final path = uri.path.toLowerCase();
    final isCsv = path.endsWith('.csv') ||
        uri.queryParameters['format']?.toLowerCase() == 'csv' ||
        uri.queryParameters['output']?.toLowerCase() == 'csv';
    if (!isCsv) {
      throw const GoogleSheetsImportException(
          'Google 스프레드시트 공유 링크 또는 CSV 내보내기 링크만 사용할 수 있습니다.');
    }
    return GoogleSheetsSource(
      downloadUri: uri,
      suggestedBookName: '가져온 스프레드시트',
    );
  }

  static String? _spreadsheetIdFrom(Uri uri) {
    if (uri.host.toLowerCase() != 'docs.google.com') return null;
    // Published CSV URLs use /spreadsheets/d/e/<id>/pub and must stay
    // direct CSV links rather than becoming a normal Sheets export URL.
    if (uri.path.startsWith('/spreadsheets/d/e/')) return null;
    final match =
        RegExp(r'^/spreadsheets/d/([A-Za-z0-9_-]+)').firstMatch(uri.path);
    return match?.group(1);
  }

  static String? _gidFrom(Uri uri) {
    final queryGid = uri.queryParameters['gid'];
    if (queryGid != null && queryGid.isNotEmpty) return queryGid;
    final fragment = Uri.splitQueryString(uri.fragment);
    final fragmentGid = fragment['gid'];
    return fragmentGid == null || fragmentGid.isEmpty ? null : fragmentGid;
  }
}

typedef GoogleSheetsHttpGet = Future<http.Response> Function(Uri uri);

class GoogleSheetsImportDownload {
  const GoogleSheetsImportDownload({
    required this.source,
    required this.importResult,
    required this.skippedRows,
  });

  final GoogleSheetsSource source;
  final WordImportResult importResult;
  final int skippedRows;
}

/// Downloads a shared sheet without Google sign-in. It deliberately imports a
/// snapshot; the source sheet is never kept as a live dependency.
class GoogleSheetsImporter {
  GoogleSheetsImporter({GoogleSheetsHttpGet? get}) : _get = get ?? _defaultGet;

  final GoogleSheetsHttpGet _get;

  Future<GoogleSheetsImportDownload> download(String rawInput) async {
    final source = GoogleSheetsSource.fromInput(rawInput);
    http.Response response;
    try {
      response = await _get(source.downloadUri);
    } on TimeoutException {
      throw const GoogleSheetsImportException(
          '시트를 읽는 시간이 초과됐습니다. 네트워크를 확인한 뒤 다시 시도해 주세요.');
    } catch (_) {
      throw const GoogleSheetsImportException(
          '시트를 불러오지 못했습니다. 링크와 네트워크를 확인해 주세요.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const GoogleSheetsImportException(
          '시트를 읽지 못했습니다. 링크 공유를 “링크가 있는 모든 사용자”의 뷰어 이상으로 설정해 주세요.');
    }

    final content = utf8.decode(response.bodyBytes, allowMalformed: true);
    final lowered = content.trimLeft().toLowerCase();
    if (lowered.startsWith('<!doctype html') || lowered.startsWith('<html')) {
      throw const GoogleSheetsImportException(
          '시트 대신 로그인 또는 권한 페이지가 열렸습니다. 시트 공유 권한을 확인해 주세요.');
    }
    final rows = content.split(RegExp(r'\r?\n'));
    final result = parseWordImportCsv(content);
    if (result.words.isEmpty) {
      throw const GoogleSheetsImportException(
          '읽을 수 있는 단어가 없습니다. 단어·뜻·발음 열을 확인해 주세요.');
    }
    final headerAndDataRows = rows.where((row) => row.trim().isNotEmpty).length;
    return GoogleSheetsImportDownload(
      source: source,
      importResult: result,
      skippedRows:
          (headerAndDataRows - 1 - result.words.length).clamp(0, 1 << 31),
    );
  }

  static Future<http.Response> _defaultGet(Uri uri) =>
      http.get(uri, headers: const {
        'Accept': 'text/csv,text/plain;q=0.9,*/*;q=0.8'
      }).timeout(const Duration(seconds: 15));
}
