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

import android.os.SystemClock
import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import android.util.Log
import android.view.KeyEvent
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
    private val backLogTag = "VOCABACK"
    private val channelName = "com.vocaflow.app/study_speech"
    private val externalChannelName = "com.vocaflow.app/external_links"
    private val snapshotChannelName = "com.vocaflow.app/resume_snapshot"
    private val navigationDiagnosticChannelName = "com.vocaflow.app/navigation_diagnostics"
    private val snapshotFile by lazy { File(cacheDir, "resume_snapshot.jpg") }
    private val snapshotTempFile by lazy { File(cacheDir, "resume_snapshot.tmp") }
    private val snapshotPreferences by lazy {
        getSharedPreferences("resume_snapshot", MODE_PRIVATE)
    }
    private var textToSpeech: TextToSpeech? = null
    private var studyAudio: MediaPlayer? = null
    private var speechReady = false
    private var pendingSpeech: Pair<String, String>? = null
    private var snapshotOverlay: ImageView? = null
    private var snapshotCaptureInProgress = false
    private var navigationDiagnosticChannel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val snapshotTimeout = Runnable {
        removeSnapshotOverlay(deleteFile = true)
    }
    // Samsung One Hand Operation+ can emit a duplicated ACTION_UP and a
    // second KEY_BACK shortly after a single gesture. Consume only that
    // short burst before Flutter starts popping the next route.
    private var lastAcceptedSystemBackDownAt = 0L
    private var lastAcceptedSystemBackUpAt = 0L
    private var suppressCurrentSystemBack = false
    private var hasAcceptedSystemBackDown = false
    private val forwardedBackEvents = RedispatchedKeyEvents()

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
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val language = call.argument<String>("language") ?: "en-US"
                        if (text.isBlank()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        stopStudyAudio()
                        if (speechReady) speak(text, language)
                        else pendingSpeech = text to language
                        result.success(null)
                    }
                    "playFile" -> {
                        result.success(playStudyAudio(call.argument<String>("path").orEmpty()))
                    }
                    "synthesizePitch" -> {
                        val reading = call.argument<String>("reading").orEmpty()
                        val accentPosition = call.argument<Int>("accentPosition") ?: -1
                        val moraCount = call.argument<Int>("moraCount") ?: 0
                        Thread {
                            val path = VoicevoxBridge.synthesize(
                                this,
                                reading,
                                accentPosition,
                                moraCount,
                            )
                            mainHandler.post { result.success(path) }
                        }.start()
                    }
                    "stop" -> {
                        stopStudyAudio()
                        textToSpeech?.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
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
        navigationDiagnosticChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, navigationDiagnosticChannelName)
        navigationDiagnosticChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "appInfo" -> {
                    val packageInfo = packageManager.getPackageInfo(packageName, 0)
                    result.success(mapOf(
                        "versionName" to (packageInfo.versionName ?: "unknown"),
                        "versionCode" to packageInfo.longVersionCode.toString(),
                        "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
                        "platform" to "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})",
                    ))
                }
                else -> result.notImplemented()
            }
        }
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
        // Flutter KeyboardManager sends unhandled events back through this
        // Activity. Debouncing that SAME event again consumes its DOWN/UP
        // before Android can invoke onBackPressed (notably with WebView focus).
        if (event.keyCode == KeyEvent.KEYCODE_BACK &&
            forwardedBackEvents.isRedispatch(event)) {
            Log.d(backLogTag, "android key system back redispatch passthrough action=${event.action}")
            return super.dispatchKeyEvent(event)
        }
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            recordNavigationInput("key", mapOf(
                "action" to event.action,
                "repeatCount" to event.repeatCount,
                "downTime" to event.downTime,
                "eventTime" to event.eventTime,
                "deviceId" to event.deviceId,
                "source" to event.source,
                "flags" to event.flags,
                "scanCode" to event.scanCode,
                "metaState" to event.metaState,
                "isLongPress" to event.isLongPress,
                "isCanceled" to event.isCanceled,
            ))
        }
        Log.d(backLogTag, "android key event action=${event.action} keyCode=${event.keyCode} repeat=${event.repeatCount} alt=${event.isAltPressed}")
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            val now = SystemClock.elapsedRealtime()
            if (event.action == KeyEvent.ACTION_DOWN) {
                val deltaMs = now - lastAcceptedSystemBackDownAt
                if (lastAcceptedSystemBackDownAt > 0 && deltaMs < SYSTEM_BACK_DEBOUNCE_MS) {
                    suppressCurrentSystemBack = true
                    hasAcceptedSystemBackDown = false
                    Log.d(backLogTag, "android key system back suppressed on down deltaMs=$deltaMs")
                    return true
                }
                suppressCurrentSystemBack = false
                lastAcceptedSystemBackDownAt = now
                hasAcceptedSystemBackDown = true
                Log.d(backLogTag, "android key system back accepted on down")
            } else if (event.action == KeyEvent.ACTION_UP) {
                val deltaMs = now - lastAcceptedSystemBackUpAt
                val hasMatchingDown = hasAcceptedSystemBackDown &&
                    now - lastAcceptedSystemBackDownAt <= SYSTEM_BACK_UP_MAX_AFTER_DOWN_MS
                if (suppressCurrentSystemBack ||
                    !hasMatchingDown ||
                    (lastAcceptedSystemBackUpAt > 0 && deltaMs < SYSTEM_BACK_DUPLICATE_UP_MS)
                ) {
                    suppressCurrentSystemBack = false
                    hasAcceptedSystemBackDown = false
                    Log.d(backLogTag, "android key system back suppressed on up deltaMs=$deltaMs matchingDown=$hasMatchingDown")
                    return true
                }
                hasAcceptedSystemBackDown = false
                lastAcceptedSystemBackUpAt = now
            }
        }
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            forwardedBackEvents.remember(event)
        }
        return super.dispatchKeyEvent(event)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        // Observation only: FlutterActivity keeps ownership of back behavior.
        recordNavigationInput("activity_on_back_pressed", mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "taskId" to taskId,
        ))
        Log.d(backLogTag, "activity onBackPressed passthrough")
        super.onBackPressed()
    }

    private fun recordNavigationInput(kind: String, values: Map<String, Any>) {
        val data = HashMap<String, Any>(values)
        data["kind"] = kind
        data["elapsedRealtime"] = SystemClock.elapsedRealtime()
        navigationDiagnosticChannel?.invokeMethod("event", data)
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

    private fun playStudyAudio(path: String): Boolean {
        val root = File(filesDir, "pronunciation").canonicalFile
        val candidate = try { File(path).canonicalFile } catch (_: Exception) { return false }
        if (!candidate.isFile || !candidate.path.startsWith(root.path + File.separator) ||
            candidate.extension.lowercase() != "wav") return false
        stopStudyAudio()
        textToSpeech?.stop()
        return try {
            studyAudio = MediaPlayer.create(this, Uri.fromFile(candidate)).apply {
                setOnCompletionListener { stopStudyAudio() }
                start()
            }
            studyAudio != null
        } catch (_: Exception) {
            stopStudyAudio()
            false
        }
    }

    private fun stopStudyAudio() {
        studyAudio?.let { player ->
            player.setOnCompletionListener(null)
            player.stop()
            player.release()
        }
        studyAudio = null
    }

    override fun onDestroy() {
        snapshotOverlay = null
        stopStudyAudio()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }

    companion object {
        private const val SYSTEM_BACK_DEBOUNCE_MS = 700L
        private const val SYSTEM_BACK_DUPLICATE_UP_MS = 80L
        private const val SYSTEM_BACK_UP_MAX_AFTER_DOWN_MS = 250L
        private const val SNAPSHOT_MAX_WIDTH = 1600
        private const val SNAPSHOT_MAX_AGE_MS = 24 * 60 * 60 * 1000L
        private const val SNAPSHOT_TIMEOUT_MS = 3000L
    }
}





