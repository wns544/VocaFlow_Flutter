#include <jni.h>
#include <android/log.h>

#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "voicevox_core.h"

namespace {

constexpr VoicevoxStyleId kStyleId = 2;  // 四国めたん（ノーマル）
std::mutex g_mutex;
const VoicevoxOnnxruntime* g_onnxruntime = nullptr;
OpenJtalkRc* g_open_jtalk = nullptr;
VoicevoxSynthesizer* g_synthesizer = nullptr;
VoicevoxVoiceModelFile* g_voice_model = nullptr;
bool g_ready = false;

void logError(const std::string& message) {
  __android_log_print(ANDROID_LOG_ERROR, "VocaFlowVoicevox", "%s", message.c_str());
}

std::string resultMessage(VoicevoxResultCode result) {
  const char* message = voicevox_error_result_to_message(result);
  return message == nullptr ? "VOICEVOX error" : message;
}

bool checkResult(VoicevoxResultCode result, const char* action) {
  if (result == VOICEVOX_RESULT_OK) return true;
  logError(std::string(action) + ": " + resultMessage(result));
  return false;
}

bool ensureInitialized(const char* runtime_path,
                       const char* dictionary_path,
                       const char* model_path) {
  if (g_ready) return true;
  VoicevoxLoadOnnxruntimeOptions runtime_options =
      voicevox_make_default_load_onnxruntime_options();
  runtime_options.filename = runtime_path;
  if (!checkResult(voicevox_onnxruntime_load_once(runtime_options, &g_onnxruntime),
                   "ONNX Runtime initialization")) {
    return false;
  }
  if (!checkResult(voicevox_open_jtalk_rc_new(dictionary_path, &g_open_jtalk),
                   "Open JTalk dictionary initialization")) {
    return false;
  }
  VoicevoxInitializeOptions initialize_options =
      voicevox_make_default_initialize_options();
  if (!checkResult(voicevox_synthesizer_new(g_onnxruntime, g_open_jtalk,
                                            initialize_options, &g_synthesizer),
                   "VOICEVOX synthesizer initialization")) {
    return false;
  }
  if (!checkResult(voicevox_voice_model_file_open(model_path, &g_voice_model),
                   "VOICEVOX voice model opening")) {
    return false;
  }
  if (!checkResult(voicevox_synthesizer_load_voice_model(
                       g_synthesizer, g_voice_model,
                       voicevox_make_default_load_voice_model_options()),
                   "VOICEVOX voice model loading")) {
    return false;
  }
  g_ready = true;
  return true;
}

std::string toUtf8(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return {};
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
}

jstring toJString(JNIEnv* env, const std::string& value) {
  return env->NewStringUTF(value.c_str());
}

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_vocaflow_app_VoicevoxBridge_nativeInitialize(
    JNIEnv* env,
    jobject /* this */,
    jstring runtime_path,
    jstring dictionary_path,
    jstring model_path) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const auto runtime = toUtf8(env, runtime_path);
  const auto dictionary = toUtf8(env, dictionary_path);
  const auto model = toUtf8(env, model_path);
  return ensureInitialized(runtime.c_str(), dictionary.c_str(), model.c_str())
      ? JNI_TRUE
      : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_vocaflow_app_VoicevoxBridge_nativeCreateAccentPhrases(
    JNIEnv* env,
    jobject /* this */,
    jstring reading) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_ready) return nullptr;
  const auto input = toUtf8(env, reading);
  if (input.empty()) return nullptr;
  char* phrases = nullptr;
  if (!checkResult(voicevox_synthesizer_create_accent_phrases(
                       g_synthesizer, input.c_str(), kStyleId, &phrases),
                   "Accent phrase creation")) {
    return nullptr;
  }
  const std::string result = phrases == nullptr ? "" : phrases;
  voicevox_json_free(phrases);
  return result.empty() ? nullptr : toJString(env, result);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_vocaflow_app_VoicevoxBridge_nativeSynthesizeAccentPhrases(
    JNIEnv* env,
    jobject /* this */,
    jstring accent_phrases_json,
    jstring output_path) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_ready) return JNI_FALSE;
  const auto phrases = toUtf8(env, accent_phrases_json);
  const auto output = toUtf8(env, output_path);
  if (phrases.empty() || output.empty()) return JNI_FALSE;

  char* refreshed_phrases = nullptr;
  if (!checkResult(voicevox_synthesizer_replace_mora_data(
                       g_synthesizer, phrases.c_str(), kStyleId,
                       &refreshed_phrases),
                   "Mora data refresh")) {
    return JNI_FALSE;
  }
  char* query = nullptr;
  const auto query_result = voicevox_audio_query_create_from_accent_phrases(
      refreshed_phrases, &query);
  voicevox_json_free(refreshed_phrases);
  if (!checkResult(query_result, "Audio query creation")) {
    return JNI_FALSE;
  }
  uintptr_t wav_length = 0;
  uint8_t* wav = nullptr;
  const auto synthesis_result = voicevox_synthesizer_synthesis(
      g_synthesizer, query, kStyleId, voicevox_make_default_synthesis_options(),
      &wav_length, &wav);
  voicevox_json_free(query);
  if (!checkResult(synthesis_result, "WAV synthesis") || wav == nullptr ||
      wav_length == 0) {
    if (wav != nullptr) voicevox_wav_free(wav);
    return JNI_FALSE;
  }

  const std::string temporary = output + ".tmp";
  FILE* file = std::fopen(temporary.c_str(), "wb");
  if (file == nullptr) {
    logError("Cannot open temporary WAV output");
    voicevox_wav_free(wav);
    return JNI_FALSE;
  }
  const auto written = std::fwrite(wav, 1, wav_length, file);
  std::fclose(file);
  voicevox_wav_free(wav);
  if (written != wav_length || std::rename(temporary.c_str(), output.c_str()) != 0) {
    std::remove(temporary.c_str());
    logError("Cannot save synthesized WAV output");
    return JNI_FALSE;
  }
  return JNI_TRUE;
}
