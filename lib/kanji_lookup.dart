import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class KoreanHanjaEntry {
  const KoreanHanjaEntry({required this.character, required this.hunEum});

  final String character;
  final String hunEum;
}

class JapaneseKanjiEntry {
  const JapaneseKanjiEntry({
    required this.character,
    required this.meanings,
    required this.onReadings,
    required this.kunReadings,
  });

  final String character;
  final List<String> meanings;
  final List<String> onReadings;
  final List<String> kunReadings;

  factory JapaneseKanjiEntry.fromJson(
    String character,
    Map<String, dynamic> json,
  ) =>
      JapaneseKanjiEntry(
        character: json['kanji'] as String? ?? character,
        meanings: _stringList(json['meanings']),
        onReadings: _stringList(json['on_readings']),
        kunReadings: _stringList(json['kun_readings']),
      );
}

class KanjiLookupResult {
  const KanjiLookupResult({required this.korean, required this.japanese});

  final KoreanHanjaEntry? korean;
  final JapaneseKanjiEntry? japanese;
}

typedef JapaneseKanjiJsonFetcher = Future<Map<String, dynamic>> Function(
  Uri uri,
);

class KanjiLookupService {
  KanjiLookupService({
    Future<String> Function()? koreanDataLoader,
    JapaneseKanjiJsonFetcher? japaneseFetcher,
  })  : _koreanDataLoader = koreanDataLoader ??
            (() => rootBundle.loadString('assets/data/hanja_ko.json')),
        _japaneseFetcher = japaneseFetcher ?? _fetchJapaneseJson;

  final Future<String> Function() _koreanDataLoader;
  final JapaneseKanjiJsonFetcher _japaneseFetcher;
  Future<Map<String, String>>? _koreanTable;
  final _japaneseCache = <String, JapaneseKanjiEntry>{};

  Future<KoreanHanjaEntry?> lookupKorean(String character) async {
    final table = await (_koreanTable ??= _loadKoreanTable());
    final hunEum = table[character];
    return hunEum == null
        ? null
        : KoreanHanjaEntry(character: character, hunEum: hunEum);
  }

  Future<JapaneseKanjiEntry?> lookupJapanese(String character) async {
    final cached = _japaneseCache[character];
    if (cached != null) return cached;
    final uri = Uri.parse(
      'https://kanjiapi.dev/v1/kanji/${Uri.encodeComponent(character)}',
    );
    final json = await _japaneseFetcher(uri);
    if (json['kanji'] is! String) {
      throw const FormatException('KanjiAPI response has no kanji field.');
    }
    final result = JapaneseKanjiEntry.fromJson(character, json);
    _japaneseCache[character] = result;
    return result;
  }

  Future<KanjiLookupResult> lookup(String character) async {
    final results = await Future.wait<dynamic>([
      lookupKorean(character),
      lookupJapanese(character),
    ]);
    return KanjiLookupResult(
      korean: results[0] as KoreanHanjaEntry?,
      japanese: results[1] as JapaneseKanjiEntry?,
    );
  }

  Future<Map<String, String>> _loadKoreanTable() async {
    final source = await _koreanDataLoader();
    return source.length > 100000
        ? compute(_decodeKoreanTable, source)
        : _decodeKoreanTable(source);
  }
}

const externalLinkChannel = MethodChannel('com.vocaflow.app/external_links');

Future<bool> openExternalUrl(Uri uri) async {
  if (uri.scheme != 'https') return false;
  try {
    return await externalLinkChannel.invokeMethod<bool>(
          'openUrl',
          {'url': uri.toString()},
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

Future<bool> openChatGptWithPrompt({
  required Uri uri,
  required String prompt,
}) async {
  if (uri.scheme != 'https' || prompt.trim().isEmpty) return false;
  try {
    return await externalLinkChannel.invokeMethod<bool>(
          'openChatGptWithPrompt',
          {
            'url': uri.toString(),
            'prompt': prompt,
          },
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

Uri naverHanjaSearchUri(String character) => Uri.parse(
      'https://hanja.dict.naver.com/#/search?query=${Uri.encodeComponent(character)}',
    );

String? normalizeChatGptConversationUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'chatgpt.com' ||
      uri.pathSegments.length != 2 ||
      uri.pathSegments.first != 'c' ||
      uri.pathSegments.last.isEmpty) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: 'chatgpt.com',
    pathSegments: ['c', uri.pathSegments.last],
  ).toString();
}

String buildChatGptKanjiPrompt({
  required String character,
  required String term,
  required String reading,
  required String meaning,
}) =>
    '''한자 $character를 한국어로 자세히 설명해 줘.

현재 학습 단어: $term
발음: $reading
뜻: $meaning

이 한자의 한국식 훈음, 일본어 음독·훈독, 이 단어에서의 의미, 다른 대표 단어, 기억하기 쉬운 암기법을 알려 줘.''';

Map<String, String> _decodeKoreanTable(String source) {
  final decoded = jsonDecode(source) as Map<String, dynamic>;
  return decoded.map((key, value) => MapEntry(key, value.toString()));
}

List<String> _stringList(dynamic value) =>
    (value as List<dynamic>? ?? const []).whereType<String>().toList();

final HttpClient _sharedHttpClient = HttpClient();

Future<Map<String, dynamic>> _fetchJapaneseJson(Uri uri) async {
  final request =
      await _sharedHttpClient.getUrl(uri).timeout(const Duration(seconds: 8));
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close().timeout(const Duration(seconds: 8));
  if (response.statusCode != HttpStatus.ok) {
    throw HttpException('KanjiAPI returned ${response.statusCode}', uri: uri);
  }
  final body = await response.transform(utf8.decoder).join();
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('KanjiAPI returned invalid JSON.');
  }
  return decoded;
}
