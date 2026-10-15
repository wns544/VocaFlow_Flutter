import 'package:flutter_test/flutter_test.dart';
import 'package:vocaflow/kanji_lookup.dart';

void main() {
  test('custom prompts substitute once and GPT links reject shared snapshots',
      () {
    expect(
        buildChatGptWordPrompt(
            term: '{{뜻}}',
            reading: 'よみ',
            meaning: '뜻값',
            template: '{{단어}} / {{발음}} / {{뜻}}'),
        '{{뜻}} / よみ / 뜻값');
    expect(
        buildChatGptKanjiPrompt(
            character: '新',
            term: '新聞',
            reading: 'しんぶん',
            meaning: '신문',
            template: '{{한자}}: {{단어}}'),
        '新: 新聞');
    expect(normalizeChatGptConversationUrl('https://chatgpt.com/g/g-study?x=1'),
        'https://chatgpt.com/g/g-study');
    expect(normalizeChatGptConversationUrl('https://chatgpt.com/share/test'),
        isNull);
    expect(
        buildChatGptExamplePrompt(term: '食べる', reading: 'たべる', meaning: '먹다'),
        allOf(contains('예문 10개'), contains('**食べる**'), contains('먹다')));
    expect(
        buildChatGptMeaningOriginPrompt(
            term: '心地よい', reading: 'ここちよい', meaning: '기분 좋다'),
        allOf(
          contains('왜 이런 뜻'),
          contains('고유어·의태어·숙어'),
          contains('억지 한자 풀이'),
          contains('불확실'),
        ));
  });
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
    expect(tongHanjaSearchUri('正').toString(),
        'http://tonghanja.com/?s=%E6%AD%A3');
    expect(isHanjaCharacter('正'), isTrue);
    expect(isHanjaCharacter('⻌'), isTrue);
    expect(isHanjaCharacter('正月'), isFalse);
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
    expect(
      normalizeChatGptConversationUrl(
        'https://chatgpt.com/g/g-p-6a845008a9488191b115ae328a2792d3-ilboneogongbu/c/6a84500e-0cd4-83e8-b51d-ba27086dc1ae?temporary=true#bottom',
      ),
      'https://chatgpt.com/g/g-p-6a845008a9488191b115ae328a2792d3-ilboneogongbu/c/6a84500e-0cd4-83e8-b51d-ba27086dc1ae',
    );
    expect(
      normalizeChatGptConversationUrl('https://chatgpt.com/g/custom-gpt/c/'),
      isNull,
    );
    expect(normalizeChatGptConversationUrl('https://example.com/c/id'), isNull);
    expect(normalizeChatGptConversationUrl('https://chatgpt.com/'), isNull);
    final chatGptUri = chatGptPromptUri(
      uri: Uri.parse('https://chatgpt.com/c/conversation-id'),
      prompt: '질문 테스트',
    );
    expect(chatGptUri.toString(),
        'https://chatgpt.com/c/conversation-id?q=%EC%A7%88%EB%AC%B8+%ED%85%8C%EC%8A%A4%ED%8A%B8');
    expect(
      chatGptPromptUri(
        uri: Uri.parse(
            'https://chatgpt.com/g/g-p-custom/c/conversation-id?model=gpt-5'),
        prompt: '正',
      ).toString(),
      'https://chatgpt.com/g/g-p-custom/c/conversation-id?model=gpt-5&q=%E6%AD%A3',
    );

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

  test('ChatGPT prompt opens one complete prompt URL', () async {
    final opened = <Uri>[];

    final ok = await openChatGptWithPrompt(
      uri: Uri.parse('https://chatgpt.com/g/g-p-custom/c/conversation-id'),
      prompt: '질문 테스트',
      openUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    expect(ok, isTrue);
    expect(opened, hasLength(1));
    expect(opened.single.toString(),
        'https://chatgpt.com/g/g-p-custom/c/conversation-id?q=%EC%A7%88%EB%AC%B8+%ED%85%8C%EC%8A%A4%ED%8A%B8');
  });

  test('ChatGPT prompt reports failure when the prompt link fails', () async {
    var calls = 0;
    final failed = await openChatGptWithPrompt(
      uri: Uri.parse('https://chatgpt.com/c/conversation-id'),
      prompt: '질문',
      openUrl: (_) async {
        calls++;
        return false;
      },
    );

    expect(failed, isFalse);
    expect(calls, 1);
  });
}
