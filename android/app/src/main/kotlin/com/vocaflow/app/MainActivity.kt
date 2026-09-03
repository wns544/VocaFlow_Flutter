package com.vocaflow.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "com.vocaflow.app/study_speech"
    private val externalChannelName = "com.vocaflow.app/external_links"
    private val snapshotChannelName = "com.vocaflow.app/resume_snapshot"
    private val navigationButtonChannelName = "com.vocaflow.app/navigation_buttons"
    private val snapshotFile by lazy { File(cacheDir, "resume_snapshot.jpg") }
    private val snapshotTempFile by lazy { File(cacheDir, "resume_snapshot.tmp") }
    private val snapshotPreferences by lazy {
        getSharedPreferences("resume_snapshot", MODE_PRIVATE)
    }
    private var textToSpeech: TextToSpeech? = null
    private var speechReady = false
    private var pendingSpeech: Pair<String, String>? = null
    private var snapshotOverlay: ImageView? = null
    private var snapshotCaptureInProgress = false
    private var navigationButtonChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val snapshotTimeout = Runnable {
        removeSnapshotOverlay(deleteFile = true)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showResumeSnapshot()
    }

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
                when (call.method) {
                    "openUrl" -> {
                        val uri = Uri.parse(call.argument<String>("url").orEmpty())
                        val isTongHanjaHttp = uri.scheme == "http" &&
                            (uri.host == "tonghanja.com" || uri.host == "www.tonghanja.com")
                        if (uri.scheme != "https" && !isTongHanjaHttp) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(openUrl(uri))
                    }
                    else -> result.notImplemented()
                }
            }
        navigationButtonChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, navigationButtonChannelName)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, snapshotChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capture" -> captureResumeSnapshot(
                        call.argument<String>("target").orEmpty(),
                        result,
                    )
                    "restorationReady" -> {
                        removeSnapshotOverlay(deleteFile = false)
                        result.success(null)
                    }
                    "delete" -> {
                        removeSnapshotOverlay(deleteFile = true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_UP) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_BACK,
                KeyEvent.KEYCODE_NAVIGATE_PREVIOUS,
                KeyEvent.KEYCODE_BUTTON_4 -> {
                    sendNavigationButton("back")
                    return true
                }
                KeyEvent.KEYCODE_FORWARD,
                KeyEvent.KEYCODE_NAVIGATE_NEXT,
                KeyEvent.KEYCODE_BUTTON_5 -> {
                    sendNavigationButton("forward")
                    return true
                }
                KeyEvent.KEYCODE_DPAD_LEFT -> {
                    if (event.isAltPressed) {
                        sendNavigationButton("back")
                        return true
                    }
                }
                KeyEvent.KEYCODE_DPAD_RIGHT -> {
                    if (event.isAltPressed) {
                        sendNavigationButton("forward")
                        return true
                    }
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_BUTTON_PRESS) {
            if ((event.buttonState and MotionEvent.BUTTON_BACK) != 0) {
                sendNavigationButton("back")
                return true
            }
            if ((event.buttonState and MotionEvent.BUTTON_FORWARD) != 0) {
                sendNavigationButton("forward")
                return true
            }
        }
        return super.dispatchGenericMotionEvent(event)
    }

    private fun sendNavigationButton(direction: String) {
        navigationButtonChannel?.invokeMethod(direction, null)
    }
    private fun showResumeSnapshot() {
        val savedAt = snapshotPreferences.getLong("savedAt", 0L)
        val orientation = snapshotPreferences.getInt("orientation", -1)
        val age = System.currentTimeMillis() - savedAt
        if (!snapshotFile.isFile ||
            age !in 0..SNAPSHOT_MAX_AGE_MS ||
            orientation != resources.configuration.orientation
        ) {
            deleteSnapshotFiles()
            return
        }
        val bitmap = BitmapFactory.decodeFile(snapshotFile.absolutePath)
        if (bitmap == null) {
            deleteSnapshotFiles()
            return
        }
        snapshotOverlay = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_XY
            setImageBitmap(bitmap)
            contentDescription = null
        }
        addContentView(
            snapshotOverlay,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        mainHandler.postDelayed(snapshotTimeout, SNAPSHOT_TIMEOUT_MS)
    }

    private fun captureResumeSnapshot(target: String, result: MethodChannel.Result?) {
        if (target.isBlank() ||
            snapshotCaptureInProgress ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.O
        ) {
            result?.success(false)
            return
        }
        val surfaceView = findSurfaceView(window.decorView)
        if (surfaceView == null) {
            result?.success(false)
            return
        }
        val width = surfaceView.width
        val height = surfaceView.height
        if (width <= 0 || height <= 0) {
            result?.success(false)
            return
        }
        snapshotCaptureInProgress = true
        val source = try {
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        } catch (_: Exception) {
            snapshotCaptureInProgress = false
            result?.success(false)
            return
        }
        try {
            PixelCopy.request(surfaceView, source, { copyResult ->
            if (copyResult != PixelCopy.SUCCESS) {
                snapshotCaptureInProgress = false
                source.recycle()
                result?.success(false)
                return@request
            }
            Thread {
                var output: Bitmap? = null
                try {
                    val outputWidth = minOf(width, SNAPSHOT_MAX_WIDTH)
                    val outputHeight = (height * (outputWidth.toFloat() / width))
                        .toInt()
                        .coerceAtLeast(1)
                    output = if (outputWidth == width) source else Bitmap.createScaledBitmap(
                        source,
                        outputWidth,
                        outputHeight,
                        true,
                    )
                    FileOutputStream(snapshotTempFile).use { stream ->
                        output.compress(Bitmap.CompressFormat.JPEG, 92, stream)
                    }
                    if (snapshotFile.exists()) snapshotFile.delete()
                    if (!snapshotTempFile.renameTo(snapshotFile)) {
                        snapshotTempFile.copyTo(snapshotFile, overwrite = true)
                        snapshotTempFile.delete()
                    }
                    snapshotPreferences.edit()
                        .putLong("savedAt", System.currentTimeMillis())
                        .putInt("orientation", resources.configuration.orientation)
                        .putString("target", target)
                        .apply()
                    mainHandler.post {
                        snapshotCaptureInProgress = false
                        result?.success(true)
                    }
                } catch (_: Exception) {
                    deleteSnapshotFiles()
                    mainHandler.post {
                        snapshotCaptureInProgress = false
                        result?.success(false)
                    }
                } finally {
                    if (output !== source) output?.recycle()
                    source.recycle()
                }
            }.start()
            }, mainHandler)
        } catch (_: IllegalArgumentException) {
            snapshotCaptureInProgress = false
            source.recycle()
            result?.success(false)
        }
    }

    private fun findSurfaceView(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view !is ViewGroup) return null
        for (index in 0 until view.childCount) {
            findSurfaceView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun removeSnapshotOverlay(deleteFile: Boolean) {
        mainHandler.removeCallbacks(snapshotTimeout)
        snapshotOverlay?.let { overlay ->
            (overlay.parent as? ViewGroup)?.removeView(overlay)
            overlay.setImageDrawable(null)
        }
        snapshotOverlay = null
        if (deleteFile) deleteSnapshotFiles()
    }

    private fun deleteSnapshotFiles() {
        snapshotFile.delete()
        snapshotTempFile.delete()
        snapshotPreferences.edit().clear().apply()
    }

    private fun openUrl(uri: Uri): Boolean = try {
        startActivity(Intent(Intent.ACTION_VIEW, uri))
        true
    } catch (_: ActivityNotFoundException) {
        false
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
        snapshotOverlay = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }

    companion object {
        private const val SNAPSHOT_MAX_WIDTH = 1600
        private const val SNAPSHOT_MAX_AGE_MS = 24 * 60 * 60 * 1000L
        private const val SNAPSHOT_TIMEOUT_MS = 3000L
    }
}


