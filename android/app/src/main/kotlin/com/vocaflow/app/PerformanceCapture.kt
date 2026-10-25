package com.vocaflow.app

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Enabled only by profile manifest metadata. No preferences access/writes. */
class PerformanceCapture(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val root get() = File(checkNotNull(context.getExternalFilesDir(null)), "performance-diagnostics")
    private var capture: File? = null
    private var sampling = false
    @Volatile private var nativeActive = false
    private val autoStop = Runnable { stopNative() }
    private val thermalCheck = object : Runnable {
        override fun run() {
            if (!nativeActive) return
            val temperature = (sample()["temperatureTenths"] as Int)
            if (temperature >= 395) stopNative("temperature-limit")
            else handler.postDelayed(this, 1000L)
        }
    }

    fun sample(): Map<String, Any> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return mapOf("elapsedMs" to SystemClock.elapsedRealtime(),
            "cpuMs" to Process.getElapsedCpuTime(),
            "temperatureTenths" to (battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1),
            "plugged" to (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1),
            "nativeHeapBytes" to Debug.getNativeHeapAllocatedSize(),
            "javaHeapBytes" to (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()),
            "nativeCaptureActive" to nativeActive,
            "pid" to Process.myPid())
    }

    @Synchronized fun prepareRecovery() {
        val target = File(root, "recovery-before-v80")
        if (File(target, "complete.json").isFile) return
        check(root.mkdirs() || root.isDirectory)
        val prefs = File(context.applicationInfo.dataDir, "shared_prefs/FlutterSharedPreferences.xml")
        check(prefs.isFile) { "Existing local preferences are required for this measurement update" }
        check(root.usableSpace > prefs.length() * 3 + 128L * 1024 * 1024) { "Insufficient backup space" }
        check(target.mkdirs() || target.isDirectory)
        val manifest = JSONArray()
        fun copy(source: File, destination: File) {
            check(destination.parentFile!!.mkdirs() || destination.parentFile!!.isDirectory)
            val temp = File(destination.path + ".tmp")
            source.copyTo(temp, overwrite = true)
            check(source.length() == temp.length())
            fun digest(file: File): String {
                val hash = MessageDigest.getInstance("SHA-256")
                file.inputStream().use { stream ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) { val count = stream.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
                }
                return hash.digest().joinToString("") { "%02x".format(it) }
            }
            val hash = digest(source)
            check(hash == digest(temp)) { "Backup checksum mismatch" }
            check(temp.renameTo(destination)) { "Backup publication failed" }
            manifest.put(JSONObject().put("file", destination.relativeTo(target).path)
                .put("bytes", destination.length()).put("sha256", hash))
        }
        copy(prefs, File(target, prefs.name))
        val backup = File(prefs.path + ".bak")
        if (backup.isFile) copy(backup, File(target, backup.name))
        // Auth preferences are deliberately excluded. Derived audio/cache and
        // the old diagnostics journal are not needed to recover study data.
        for (name in listOf("book_archives", "large_local_store")) {
            val source = File(context.filesDir, name)
            if (source.isDirectory) source.walkTopDown().filter { it.isFile }.forEach {
                copy(it, File(target, "$name/${it.relativeTo(source).path}"))
            }
        }
        File(target, "complete.json").writeText(JSONObject()
            .put("createdAtMs", System.currentTimeMillis()).put("files", manifest).toString())
    }

    @Synchronized fun start(javaSampling: Boolean) {
        check(capture == null) { "Capture already active; export previous capture first" }
        check(root.mkdirs() || root.isDirectory)
        val dir = File(root, "capture-${System.currentTimeMillis()}")
        check(dir.mkdirs())
        File(dir, "start.json").writeText(JSONObject(sample()).put("javaSampling", javaSampling).toString())
        if (javaSampling) {
            Debug.startMethodTracingSampling(File(dir, "android-methods.trace").path,
                6 * 1024 * 1024, 2000)
            sampling = true
        }
        capture = dir
        nativeActive = true
        handler.postDelayed(autoStop, 30_000L)
        handler.postDelayed(thermalCheck, 1000L)
    }

    @Synchronized private fun stopNative(reason: String = "stopped") {
        handler.removeCallbacks(autoStop)
        handler.removeCallbacks(thermalCheck)
        if (!nativeActive) return
        nativeActive = false
        if (sampling) {
            try { Debug.stopMethodTracing() } finally { sampling = false }
        }
        capture?.let { File(it, "native-stop.json").writeText(JSONObject(sample()).put("reason", reason).toString()) }
    }

    @Synchronized fun stop(events: String, dropped: Int): String {
        val dir = checkNotNull(capture) { "No capture active" }
        try {
            stopNative()
            check(events.toByteArray(Charsets.UTF_8).size <= 2 * 1024 * 1024 + 64 * 1024)
            File(dir, "dart-events.ndjson").writeText(events)
            File(dir, "complete.json").writeText(JSONObject().put("dropped", dropped).toString())
            return dir.name
        } finally { capture = null }
    }

    fun close() { stopNative() }
}
