import 'package:flutter/services.dart';

enum StudySpeechLanguage {
  japanese('ja-JP'),
  korean('ko-KR'),
  english('en-US');

  const StudySpeechLanguage(this.tag);

  final String tag;
}

class StudySpeechRequest {
  const StudySpeechRequest({
    required this.text,
    required this.language,
    this.term,
    this.reading,
  });

  final String text;
  final StudySpeechLanguage language;
  final String? term;
  final String? reading;

  Map<String, Object?> toMethodChannelArgs() => {
        'text': text,
        'language': language.tag,
      };
}

const studySpeechChannel = MethodChannel('com.vocaflow.app/study_speech');

StudySpeechLanguage detectStudySpeechLanguage(String text) {
  if (RegExp(r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]')
      .hasMatch(text)) {
    return StudySpeechLanguage.japanese;
  }
  if (RegExp(r'[\uAC00-\uD7A3]').hasMatch(text)) {
    return StudySpeechLanguage.korean;
  }
  return StudySpeechLanguage.english;
}

String studySpeechLanguage(String text) => detectStudySpeechLanguage(text).tag;

StudySpeechRequest studySpeechRequestForWord({
  required String term,
  required String reading,
}) {
  final spokenText = reading.trim().isEmpty ? term.trim() : reading.trim();
  return StudySpeechRequest(
    text: spokenText,
    language: detectStudySpeechLanguage(spokenText),
    term: term,
    reading: reading,
  );
}

Future<void> speakStudyWord(String text) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  await speakStudySpeechRequest(StudySpeechRequest(
    text: trimmed,
    language: detectStudySpeechLanguage(trimmed),
  ));
}

Future<void> speakStudySpeechRequest(StudySpeechRequest request) async {
  if (request.text.trim().isEmpty) return;
  try {
    await studySpeechChannel.invokeMethod<void>(
      'speak',
      request.toMethodChannelArgs(),
    );
  } on MissingPluginException {
    // Voice playback is only available on supported device builds.
  } on Exception {
    // Studying should continue even when a device has no matching TTS voice.
  }
}
