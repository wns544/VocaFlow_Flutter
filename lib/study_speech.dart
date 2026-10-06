import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

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
final _webStudySpeech = FlutterTts();

// VOICEVOX runs as a native Android library.  A native fault terminates the
// whole process before Dart can recover, so keep the experimental synthesizer
// disabled until it has been verified against affected Samsung devices.  The
// caller deliberately falls back to the device's normal Japanese TTS.
const _onDevicePitchSynthesisEnabled = false;

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
    if (kIsWeb) {
      await _webStudySpeech.setLanguage(request.language.tag);
      await _webStudySpeech.setSpeechRate(0.45);
      await _webStudySpeech.speak(request.text);
      return;
    }
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

/// Plays an installed pronunciation-pack WAV. Returns false when the native
/// player rejects the path so callers can fall back to the device TTS.
Future<bool> playInstalledStudySpeechFile(String path) async {
  if (path.trim().isEmpty || kIsWeb) return false;
  try {
    return await studySpeechChannel
            .invokeMethod<bool>('playFile', {'path': path}) ??
        false;
  } on MissingPluginException {
    return false;
  } on Exception {
    return false;
  }
}

/// Creates (or reuses) an on-device Japanese WAV whose accent position was
/// resolved locally. A null result deliberately falls back to the device TTS.
Future<String?> synthesizeOnDeviceJapanesePitch({
  required String reading,
  required int accentPosition,
  required int moraCount,
}) async {
  if (!_onDevicePitchSynthesisEnabled || kIsWeb || reading.trim().isEmpty) {
    return null;
  }
  try {
    return await studySpeechChannel.invokeMethod<String>('synthesizePitch', {
      'reading': reading,
      'accentPosition': accentPosition,
      'moraCount': moraCount,
    });
  } on MissingPluginException {
    return null;
  } on Exception {
    return null;
  }
}

/// Plays a verified local recording when present, otherwise creates the same
/// pitch pattern on-device. Callers retain the normal device-TTS fallback.
Future<bool> playJapanesePitchAccent({
  required String reading,
  required int accentPosition,
  required int moraCount,
  String? prerecordedPath,
}) async {
  if (prerecordedPath != null &&
      await playInstalledStudySpeechFile(prerecordedPath)) {
    return true;
  }
  final generated = await synthesizeOnDeviceJapanesePitch(
    reading: reading,
    accentPosition: accentPosition,
    moraCount: moraCount,
  );
  return generated != null && await playInstalledStudySpeechFile(generated);
}

Future<void> stopStudySpeech() async {
  if (kIsWeb) return;
  try {
    await studySpeechChannel.invokeMethod<void>('stop');
  } on MissingPluginException {
    // No native audio host is available.
  } on Exception {
    // Stopping audio must not interrupt studying.
  }
}
