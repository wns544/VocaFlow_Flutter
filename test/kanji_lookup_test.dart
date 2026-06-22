import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/kanji_lookup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Korean dictionary contains common hun-eum entries', () async {
    final service = KanjiLookupService(
      japaneseFetcher: (_) async => {'kanji': 'unused'},
    );

    expect((await service.lookupKorean('新'))?.hunEum, '새 신');
    expect((await service.lookupKorean('雪'))?.hunEum, '눈 설');
    expect(await service.lookupKorean('🙂'), isNull);
  });

  test('Japanese lookup parses and caches KanjiAPI data', () async {
    var calls = 0;
    final service = KanjiLookupService(
      koreanDataLoader: () async => '{}',
      japaneseFetcher: (uri) async {
        calls++;
        expect(uri.toString(), contains('%E6%96%B0'));
        return {
          'kanji': '新',
          'meanings': ['new'],
          'on_readings': ['シン'],
          'kun_readings': ['あたら.しい'],
        };
      },
    );

    final first = await service.lookupJapanese('新');
    final second = await service.lookupJapanese('新');

    expect(first?.meanings, ['new']);
    expect(first?.onReadings, ['シン']);
    expect(first?.kunReadings, ['あたら.しい']);
    expect(second, same(first));
    expect(calls, 1);
  });

  test('Japanese lookup exposes fetch and malformed response failures',
      () async {
    final offline = KanjiLookupService(
      koreanDataLoader: () async => '{}',
      japaneseFetcher: (_) => throw Exception('offline'),
    );
    final malformed = KanjiLookupService(
      koreanDataLoader: () async => '{}',
      japaneseFetcher: (_) async => {'meanings': <String>[]},
    );

    await expectLater(offline.lookupJapanese('新'), throwsException);
    await expectLater(
      malformed.lookupJapanese('新'),
      throwsA(isA<FormatException>()),
    );
  });

  test('external lookup URLs and ChatGPT prompt keep the study context', () {
    expect(
      naverHanjaSearchUri('新').toString(),
      'https://hanja.dict.naver.com/#/search?query=%E6%96%B0',
    );
    expect(
      normalizeChatGptConversationUrl(
        'https://chatgpt.com/c/conversation-id?temporary=true#bottom',
      ),
      'https://chatgpt.com/c/conversation-id',
    );
    expect(normalizeChatGptConversationUrl('https://example.com/c/id'), isNull);
    expect(normalizeChatGptConversationUrl('https://chatgpt.com/'), isNull);

    final prompt = buildChatGptKanjiPrompt(
      character: '新',
      term: '新聞',
      reading: 'しんぶん',
      meaning: '신문',
    );
    expect(prompt, contains('한자 新'));
    expect(prompt, contains('현재 학습 단어: 新聞'));
    expect(prompt, contains('발음: しんぶん'));
    expect(prompt, contains('뜻: 신문'));
  });
}
