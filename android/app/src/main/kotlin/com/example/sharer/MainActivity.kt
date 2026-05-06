package com.example.sharer

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * Slice 5.5 — Android share-sheet integration.
 *
 * Two channels:
 *
 *   - sharer.share/methods : `getInitialShare` returns the share that
 *     triggered a cold-start launch (from `intent` at onCreate time),
 *     consumed once.
 *   - sharer.share/events  : EventChannel that emits subsequent shares
 *     received via `onNewIntent` while the app is running.
 *
 * Each share is a `List<Map<String, Any?>>` where every map has:
 *   path     : absolute file path under cacheDir (we copied content://
 *              URIs there so the Dart side can read with plain dart:io)
 *   name     : original DISPLAY_NAME or the URI's last path segment
 *   size     : bytes on disk
 *   mimeType : best guess from ContentResolver.getType
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "sharer.share/methods"
        private const val EVENT_CHANNEL = "sharer.share/events"

        /** Slice 5.3.1 — Android public Downloads bridge. The Dart side
         *  streams ciphertext into a private staging file (cacheDir),
         *  then calls publishToDownloads to move it into the user-
         *  visible Downloads/Sharer/ folder via MediaStore (API 29+) or
         *  Environment.DIRECTORY_DOWNLOADS (legacy ≤ 28). The method
         *  returns the absolute file path the Dart side should report
         *  as the saved location (for notifications + transfer log). */
        private const val DOWNLOADS_CHANNEL = "sharer.downloads/methods"
    }

    /** True once the Dart side has called getInitialShare. Subsequent
     *  calls return null so a hot-restart doesn't re-fire the launch
     *  share. */
    private var initialShareConsumed = false
    private var initialShare: List<Map<String, Any?>>? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialShare = extractShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val items = extractShare(intent) ?: return
        eventSink?.success(items)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getInitialShare") {
                    if (initialShareConsumed) {
                        result.success(null)
                    } else {
                        initialShareConsumed = true
                        result.success(initialShare)
                    }
                } else {
                    result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOADS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "publishToDownloads") {
                    val tempPath = call.argument<String>("tempPath")
                    val displayName = call.argument<String>("displayName")
                    val mimeType = call.argument<String?>("mimeType")
                        ?: "application/octet-stream"
                    if (tempPath == null || displayName == null) {
                        result.error("BAD_ARGS", "tempPath/displayName required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val publishedPath = publishToDownloads(tempPath, displayName, mimeType)
                        result.success(publishedPath)
                    } catch (e: Exception) {
                        result.error("PUBLISH_FAILED", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * Slice 5.3.1 — copy the staged ciphertext-decrypted file from
     * cacheDir into the user-visible Downloads/Sharer/ folder.
     *
     * On API 29+ uses MediaStore.Downloads which doesn't require
     * WRITE_EXTERNAL_STORAGE. On API ≤ 28 falls back to direct file
     * write under Environment.DIRECTORY_DOWNLOADS, which is auto-
     * granted under the legacy storage permission.
     *
     * Returns the absolute on-disk path so the existing OpenFilex
     * "Open" notification action keeps working unchanged. The temp
     * file is deleted on success.
     */
    private fun publishToDownloads(
        tempPath: String,
        displayName: String,
        mimeType: String,
    ): String {
        val tempFile = File(tempPath)
        if (!tempFile.exists()) {
            throw IllegalStateException("staging file does not exist: $tempPath")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return publishViaMediaStore(tempFile, displayName, mimeType)
        }
        return publishViaLegacyDir(tempFile, displayName)
    }

    private fun publishViaMediaStore(
        tempFile: File,
        displayName: String,
        mimeType: String,
    ): String {
        val resolver = contentResolver
        val initial = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/Sharer/")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri: Uri = resolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            initial,
        ) ?: throw IllegalStateException(
            "MediaStore.Downloads insert returned null"
        )
        try {
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(tempFile).use { it.copyTo(out) }
            } ?: throw IllegalStateException(
                "openOutputStream returned null for $uri"
            )
            val finalize = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            resolver.update(uri, finalize, null, null)
            tempFile.delete()
            // Resolve the absolute on-disk path so `open_filex` (which
            // uses FileProvider with absolute paths) keeps working
            // without us re-engineering the Open action.
            val abs = resolveAbsolutePath(uri) ?: uri.toString()
            return abs
        } catch (e: Exception) {
            // Best-effort cleanup of the half-written MediaStore entry.
            try {
                resolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            throw e
        }
    }

    private fun resolveAbsolutePath(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DATA),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (idx >= 0) cursor.getString(idx) else null
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    @Suppress("DEPRECATION")
    private fun publishViaLegacyDir(
        tempFile: File,
        displayName: String,
    ): String {
        val downloads = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS,
        )
        val sharerDir = File(downloads, "Sharer")
        if (!sharerDir.exists() && !sharerDir.mkdirs()) {
            throw IllegalStateException(
                "could not create ${sharerDir.absolutePath}"
            )
        }
        // Resolve unique target name: foo.txt → foo (1).txt → foo (2).txt …
        var target = File(sharerDir, displayName)
        if (target.exists()) {
            val dot = displayName.lastIndexOf('.')
            val stem = if (dot > 0) displayName.substring(0, dot) else displayName
            val ext = if (dot > 0) displayName.substring(dot) else ""
            var i = 1
            while (target.exists() && i < 10_000) {
                target = File(sharerDir, "$stem ($i)$ext")
                i++
            }
        }
        FileInputStream(tempFile).use { input ->
            FileOutputStream(target).use { out -> input.copyTo(out) }
        }
        tempFile.delete()
        return target.absolutePath
    }

    private fun extractShare(intent: Intent?): List<Map<String, Any?>>? {
        if (intent == null) return null
        val action = intent.action ?: return null
        val uris: List<Uri> = when (action) {
            Intent.ACTION_SEND -> {
                val u: Uri? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                u?.let { listOf(it) } ?: return null
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val list: ArrayList<Uri>? = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                list ?: return null
            }
            else -> return null
        }
        return uris.mapNotNull { copyToCache(it) }
    }

    private fun copyToCache(uri: Uri): Map<String, Any?>? {
        return try {
            val resolver = contentResolver
            val mimeType = resolver.getType(uri)
            val name = queryDisplayName(uri) ?: ("shared_" + System.currentTimeMillis())
            // Sanitise — names from another app can contain anything,
            // and we use them as filename suffixes on disk.
            val safeName = name.replace(Regex("[\\\\/]"), "_")
            val outFile = File(cacheDir, "share_${System.nanoTime()}_$safeName")
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            mapOf(
                "path" to outFile.absolutePath,
                "name" to name,
                "size" to outFile.length(),
                "mimeType" to mimeType,
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else {
                    null
                }
            } ?: uri.lastPathSegment
        } catch (e: Exception) {
            uri.lastPathSegment
        }
    }
}
