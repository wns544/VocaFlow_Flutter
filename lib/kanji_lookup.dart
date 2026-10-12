import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

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
  final isTongHanjaHttp = uri.scheme == 'http' &&
      (uri.host == 'tonghanja.com' || uri.host == 'www.tonghanja.com');
  if (uri.scheme != 'https' && !isTongHanjaHttp) return false;
  if (kIsWeb) {
    return launchUrl(uri, webOnlyWindowName: '_blank');
  }
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
  Duration warmupDelay = const Duration(milliseconds: 900),
  Future<bool> Function(Uri uri)? openUrl,
}) async {
  if (uri.scheme != 'https' || prompt.trim().isEmpty) return false;
  final launcher = openUrl ?? openExternalUrl;
  final openedConversation = await launcher(uri);
  if (!openedConversation) return false;
  if (!warmupDelay.isNegative && warmupDelay > Duration.zero) {
    await Future<void>.delayed(warmupDelay);
  }
  return launcher(chatGptPromptUri(uri: uri, prompt: prompt));
}

Uri naverHanjaSearchUri(String character) => Uri.parse(
      'https://hanja.dict.naver.com/#/search?query=${Uri.encodeComponent(character)}',
    );

Uri tongHanjaSearchUri(String character) => Uri.http(
      'tonghanja.com',
      '/',
      {'s': character},
    );

bool isHanjaCharacter(String value) => RegExp(
        r'^[\u2E80-\u2EFF\u2F00-\u2FD5\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]$')
    .hasMatch(value);

Uri nihongoKanjiSearchUri(String character) => Uri.https(
      'nihongokanji.com',
      '/',
      {'s': character},
    );
Uri chatGptPromptUri({
  required Uri uri,
  required String prompt,
}) =>
    uri.replace(queryParameters: {
      ...uri.queryParameters,
      'q': prompt,
    });

String? normalizeChatGptConversationUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.host != 'chatgpt.com') {
    return null;
  }

  final segments = uri.pathSegments;
  final isStandardConversation =
      segments.length == 2 && segments.first == 'c' && segments.last.isNotEmpty;
  final isGptConversation = segments.length == 4 &&
      segments[0] == 'g' &&
      segments[1].isNotEmpty &&
      segments[2] == 'c' &&
      segments[3].isNotEmpty;
  final isGpt = segments.length == 2 &&
      segments[0] == 'g' &&
      segments[1].startsWith('g-') &&
      segments[1].length > 2;
  if (!isStandardConversation && !isGptConversation && !isGpt) return null;

  return Uri(
    scheme: 'https',
    host: 'chatgpt.com',
    pathSegments: segments,
  ).toString();
}

String buildChatGptKanjiPrompt({
  required String character,
  required String term,
  required String reading,
  required String meaning,
  String? template,
}) =>
    template != null && template.trim().isNotEmpty
        ? renderChatGptTemplate(template, character, term, reading, meaning)
        : '''한자 $character를 한국어로 자세히 설명해 줘.

현재 학습 단어: $term
발음: $reading
뜻: $meaning

이 한자의 한국식 훈음, 일본어 음독·훈독, 이 단어에서의 의미, 다른 대표 단어, 기억하기 쉬운 암기법을 알려 줘.''';

String buildChatGptWordPrompt({
  required String term,
  required String reading,
  required String meaning,
  String? template,
}) =>
    template != null && template.trim().isNotEmpty
        ? renderChatGptTemplate(template, '', term, reading, meaning)
        : '''일본어 단어 "$term"을 한국어로 자세히 설명해 줘.

발음: $reading
뜻: $meaning

이 단어를 한자 조합 단위로 쪼개서 각 한자의 역할, 단어 전체 의미가 만들어지는 방식, 비슷한 단어와 헷갈리기 쉬운 점, 기억하기 쉬운 암기법을 알려 줘.

또한 이 단어를 자연스럽게 사용한 일본어 예문 1개와 한국어 뜻을 함께 보여 줘. 예문 안에서 학습 단어는 반드시 **$term**처럼 앞뒤에 별표 두 개씩을 붙여 강조해 줘.''';

String buildChatGptExamplePrompt({
  required String term,
  required String reading,
  required String meaning,
}) =>
    '''일본어 단어 "$term"(발음: $reading, 뜻: $meaning)을 자연스럽게 익힐 수 있는 일본어 예문 10개를 만들어 줘.

난이도는 쉬운 것부터 자연스러운 일상 표현까지 조금씩 올려 줘. 각 예문마다 한국어 뜻을 바로 아래에 적고, 학습 단어 "$term"은 반드시 **$term**처럼 강조해 줘.

뜻이나 쓰임이 여러 개라면 대표적인 쓰임을 고르게 포함하고, 어색하거나 교과서적인 문장은 피해서 실제 일본어에서 자연스러운 표현으로 써 줘.''';

String renderChatGptTemplate(String template, String character, String term,
    String reading, String meaning) {
  final values = {'한자': character, '단어': term, '발음': reading, '뜻': meaning};
  return template.replaceAllMapped(
      RegExp(r'\{\{(한자|단어|발음|뜻)\}\}'), (match) => values[match[1]]!);
}

Map<String, String> _decodeKoreanTable(String source) {
  final decoded = jsonDecode(source) as Map<String, dynamic>;
  return decoded.map((key, value) => MapEntry(key, value.toString()));
}

List<String> _stringList(dynamic value) =>
    (value as List<dynamic>? ?? const []).whereType<String>().toList();

Future<Map<String, dynamic>> _fetchJapaneseJson(Uri uri) async {
  final response = await http.get(uri, headers: const {
    'Accept': 'application/json'
  }).timeout(const Duration(seconds: 8));
  if (response.statusCode != 200) {
    throw StateError('KanjiAPI returned ${response.statusCode}');
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('KanjiAPI returned invalid JSON.');
  }
  return decoded;
}
