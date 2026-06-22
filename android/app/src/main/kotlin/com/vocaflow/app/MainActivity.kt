package com.vocaflow.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.speech.tts.TextToSpeech
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "com.vocaflow.app/study_speech"
    private val externalChannelName = "com.vocaflow.app/external_links"
    private var textToSpeech: TextToSpeech? = null
    private var speechReady = false
    private var pendingSpeech: Pair<String, String>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textToSpeech = TextToSpeech(this) { status ->
            speechReady = status == TextToSpeech.SUCCESS
            if (speechReady) {
                pendingSpeech?.let { (text, language) -> speak(text, language) }
                pendingSpeech = null
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "speak") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val text = call.argument<String>("text").orEmpty()
                val language = call.argument<String>("language") ?: "en-US"
                if (text.isBlank()) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (speechReady) speak(text, language)
                else pendingSpeech = text to language
                result.success(null)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, externalChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "openUrl") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val uri = Uri.parse(call.argument<String>("url").orEmpty())
                if (uri.scheme != "https") {
                    result.success(false)
                    return@setMethodCallHandler
                }
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                    result.success(true)
                } catch (_: ActivityNotFoundException) {
                    result.success(false)
                }
            }
    }

    private fun speak(text: String, language: String) {
        val engine = textToSpeech ?: return
        val locale = Locale.forLanguageTag(language)
        val availability = engine.setLanguage(locale)
        if (availability == TextToSpeech.LANG_MISSING_DATA ||
            availability == TextToSpeech.LANG_NOT_SUPPORTED
        ) {
            engine.language = Locale.getDefault()
        }
        engine.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "vocaflow-study-word")
    }

    override fun onDestroy() {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }
}
