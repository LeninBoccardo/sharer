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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

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

        /** Slice 5.x.3.2 — savedInstanceState key for the initial-
         *  share-consumed flag, so a Realme black-frame activity
         *  restart doesn't re-fire the same cold-start intent. */
        private const val STATE_INITIAL_CONSUMED = "sharer.initialShareConsumed"
    }

    /** True once the Dart side has called getInitialShare. Subsequent
     *  calls return null so a hot-restart doesn't re-fire the launch
     *  share.
     *
     *  Slice 5.x.3.2: persisted across activity restart via
     *  onSaveInstanceState. Realme/ColorOS kills + restarts the activity
     *  during the black-frame quirk documented in
     *  reference_realme_ui_quirks.md; without persistence the same
     *  cold-start intent re-fires and Dart sees the share twice. */
    private var initialShareConsumed = false
    private var initialShare: List<Map<String, Any?>>? = null
    private var eventSink: EventChannel.EventSink? = null

    /**
     * Slice 5.x.3.1: events that arrived via onNewIntent before the Dart
     * side attached its EventChannel listener. Drained on the next
     * onListen. The hot path (Dart already listening) bypasses this
     * entirely — eventSink is non-null and we deliver directly.
     *
     * Capped at 32 to bound memory if a runaway sender posts shares to
     * a Dart-side that never re-subscribes; in practice the queue
     * should hold 0–1 items only during the brief startup window.
     */
    private val pendingEvents = ArrayDeque<List<Map<String, Any?>>>()

    /**
     * Slice 5.x.3.3: dedicated background thread for share extraction
     * (content URI → cacheDir copy). Both onCreate and onNewIntent
     * dispatch here instead of running on the UI thread. A multi-GB
     * ACTION_SEND_MULTIPLE used to ANR before Flutter ever saw the
     * event; now the UI thread returns immediately and the result is
     * posted back via runOnUiThread when the copy completes.
     *
     * Single-threaded so two shares queued in quick succession process
     * in arrival order without a new thread per share.
     */
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "sharer-share-io").apply { isDaemon = true }
    }

    /**
     * State for the cold-start extraction (slice 5.x.3.3): the UI
     * thread needs to know whether extraction is still running so
     * `getInitialShare` can either deliver immediately or defer the
     * MethodChannel.Result until the bg copy finishes.
     */
    private var initialExtractDone = false
    private var pendingInitialResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Slice 5.x.3.2: restore the consumed flag first. If the
        // activity is being recreated after a Realme black-frame
        // restart, intent is the same retained intent the system holds,
        // so without this we'd hand the same share to Dart twice.
        initialShareConsumed =
            savedInstanceState?.getBoolean(STATE_INITIAL_CONSUMED, false) ?: false
        if (initialShareConsumed) {
            initialExtractDone = true
            return
        }
        // Slice 5.x.3.3: kick the heavy content-URI copy off the UI
        // thread. We may still be running while Dart calls
        // getInitialShare — handled in the MethodChannel callback below.
        val intentSnapshot = intent
        ioExecutor.submit {
            val items = try {
                extractShare(intentSnapshot)
            } catch (_: Exception) {
                null
            }
            runOnUiThread {
                initialShare = items
                initialExtractDone = true
                val pending = pendingInitialResult
                if (pending != null) {
                    pendingInitialResult = null
                    initialShareConsumed = true
                    pending.success(items)
                }
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_INITIAL_CONSUMED, initialShareConsumed)
    }

    override fun onDestroy() {
        super.onDestroy()
        ioExecutor.shutdown()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Slice 5.x.3.3: extract on the IO executor; deliver back on
        // the UI thread to keep the eventSink/buffer access single-
        // threaded.
        val intentSnapshot = intent
        ioExecutor.submit {
            val items = try {
                extractShare(intentSnapshot) ?: return@submit
            } catch (_: Exception) {
                return@submit
            }
            runOnUiThread {
                val sink = eventSink
                if (sink != null) {
                    sink.success(items)
                } else {
                    // Buffer: Dart hasn't attached yet or has detached.
                    if (pendingEvents.size >= 32) pendingEvents.removeFirst()
                    pendingEvents.addLast(items)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getInitialShare") {
                    when {
                        initialShareConsumed -> result.success(null)
                        // Slice 5.x.3.3: if the bg extraction is still
                        // in flight, hold the result and deliver it
                        // when the IO executor's runOnUiThread fires.
                        // Don't mark consumed yet — only after we hand
                        // real data back. Otherwise an activity restart
                        // mid-extraction would lose the share.
                        !initialExtractDone -> {
                            // Defensive: Dart only calls getInitialShare
                            // once, but if a second call somehow arrived
                            // resolve the previous one first.
                            pendingInitialResult?.success(null)
                            pendingInitialResult = result
                        }
                        else -> {
                            initialShareConsumed = true
                            result.success(initialShare)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    // Slice 5.x.3.1: drain anything that arrived via
                    // onNewIntent before Dart was listening. FIFO so
                    // the user sees shares in arrival order.
                    if (events != null) {
                        while (pendingEvents.isNotEmpty()) {
                            events.success(pendingEvents.removeFirst())
                        }
                    }
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOADS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "publishToDownloads" -> {
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
                    }
                    // Slice 5.x.3.5 (#17): MediaStore.MediaColumns.DATA
                    // is frequently null on Android 11+, so
                    // publishToDownloads can return a `content://` URI
                    // instead of an absolute path. OpenFilex can't
                    // open URIs; this method bridges via
                    // Intent.ACTION_VIEW + ContentResolver MIME guess
                    // so the "Open" notification action keeps working.
                    "openByUri" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString == null) {
                            result.error("BAD_ARGS", "uri required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = Uri.parse(uriString)
                            val mimeType = contentResolver.getType(uri)
                                ?: "application/octet-stream"
                            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, mimeType)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(viewIntent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Slice 5.x.3.5 (#16): sweep orphan IS_PENDING=1 MediaStore
        // entries that we own. JVM kill between insert(IS_PENDING=1)
        // and update(IS_PENDING=0) leaves an entry that's invisible
        // to the user and never reclaimed (Android auto-expires after
        // 7 days, but until then a fresh insert with the same
        // displayName collides and gets renamed to "foo (1).txt").
        // Only on fresh creation — savedInstanceState being non-null
        // means an activity restart, where this work is wasted.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ioExecutor.submit { sweepOrphanPendingDownloads() }
        }
    }

    private fun sweepOrphanPendingDownloads() {
        try {
            val resolver = contentResolver
            val selection =
                "${MediaStore.Downloads.IS_PENDING}=? AND " +
                    "${MediaStore.Downloads.OWNER_PACKAGE_NAME}=?"
            val selectionArgs = arrayOf("1", packageName)
            resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                selection,
                selectionArgs,
                null,
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(MediaStore.Downloads._ID)
                if (idCol < 0) return@use
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val orphan = MediaStore.Downloads.EXTERNAL_CONTENT_URI
                        .buildUpon().appendPath(id.toString()).build()
                    try {
                        resolver.delete(orphan, null, null)
                    } catch (_: Exception) {
                        // Best-effort cleanup; never fail boot for this.
                    }
                }
            }
        } catch (_: Exception) {
            // Same — never fail boot for an opportunistic sweep.
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
