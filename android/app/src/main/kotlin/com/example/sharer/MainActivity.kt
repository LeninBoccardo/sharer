package com.example.sharer

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
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
