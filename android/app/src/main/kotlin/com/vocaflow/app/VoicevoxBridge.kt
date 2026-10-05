package com.vocaflow.app

import android.content.Context
import android.util.Log
import org.json.JSONArray
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/**
 * Keeps the bundled Japanese voice fully on the device.  Vocabulary cards are
 * never changed: the cache is derived only from the reading and accent value.
 */
object VoicevoxBridge {
    private const val logTag = "VocaFlowVoicevox"
    private const val assetRoot = "voicevox"
    private const val dictionaryDir = "open_jtalk_dic_utf_8-1.11"
    private const val modelFile = "shikoku-metan.vvm"
    private const val cacheVersion = "voicevox-0.17.0-metan-normal-1"
    private val initializationLock = Any()

    init {
        System.loadLibrary("voicevox_onnxruntime")
        System.loadLibrary("voicevox_core")
        System.loadLibrary("vocaflow_voicevox")
    }

    fun synthesize(
        context: Context,
        reading: String,
        accentPosition: Int,
        moraCount: Int,
    ): String? = synchronized(initializationLock) {
        if (reading.isBlank() || accentPosition !in 0..moraCount || moraCount <= 0) {
            return null
        }
        return try {
            val root = File(context.filesDir, assetRoot)
            copyAssetTree(context, assetRoot, root)
            val dictionary = File(root, dictionaryDir)
            val model = File(root, modelFile)
            if (!dictionary.isDirectory || !model.isFile) return null
            val runtime = File(context.applicationInfo.nativeLibraryDir, "libvoicevox_onnxruntime.so")
            if (!runtime.isFile || !nativeInitialize(
                    runtime.absolutePath,
                    dictionary.absolutePath,
                    model.absolutePath,
                )
            ) {
                return null
            }

            val phrases = nativeCreateAccentPhrases(reading) ?: return null
            val parsed = JSONArray(phrases)
            if (parsed.length() != 1) return null
            val phrase = parsed.getJSONObject(0)
            if (phrase.optJSONArray("moras")?.length() != moraCount) return null
            phrase.put("accent", accentPosition)

            val destinationDir = File(context.filesDir, "pronunciation/on-device")
            if (!destinationDir.exists() && !destinationDir.mkdirs()) return null
            val destination = File(
                destinationDir,
                "${sha256("$cacheVersion|$reading|$accentPosition")}.wav",
            )
            if (!destination.isFile || destination.length() < 44L) {
                if (!nativeSynthesizeAccentPhrases(parsed.toString(), destination.absolutePath)) {
                    destination.delete()
                    return null
                }
            }
            destination.absolutePath
        } catch (error: Exception) {
            Log.w(logTag, "On-device Japanese voice unavailable", error)
            null
        }
    }

    private fun copyAssetTree(context: Context, source: String, destination: File) {
        val children = context.assets.list(source) ?: emptyArray()
        if (children.isEmpty()) {
            if (destination.isFile && destination.length() > 0L) return
            destination.parentFile?.mkdirs()
            context.assets.open(source).use { input ->
                FileOutputStream(destination).use { output -> input.copyTo(output) }
            }
            return
        }
        if (!destination.exists() && !destination.mkdirs()) {
            throw IllegalStateException("Cannot create bundled voice directory")
        }
        for (child in children) {
            copyAssetTree(context, "$source/$child", File(destination, child))
        }
    }

    private fun sha256(value: String): String = MessageDigest
        .getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(byte) }

    private external fun nativeInitialize(
        runtimePath: String,
        dictionaryPath: String,
        modelPath: String,
    ): Boolean

    private external fun nativeCreateAccentPhrases(reading: String): String?

    private external fun nativeSynthesizeAccentPhrases(
        accentPhrasesJson: String,
        outputPath: String,
    ): Boolean
}
