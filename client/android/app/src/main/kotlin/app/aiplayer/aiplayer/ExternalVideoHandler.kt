package app.aiplayer.aiplayer

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.Executors

/** Consume only explicitly opened/shared video URIs. content:// is streamed
 * under the temporary grant; it is never guessed into a filesystem path. */
class ExternalVideoHandler(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "app.aiplayer/external_video")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val incoming = File(context.filesDir, "external-incoming")
    private val pending = mutableListOf<Map<String, Any>>()
    private var ready = false
    @Volatile private var closed = false
    @Volatile private var generation = 0
    @Volatile private var reading: InputStream? = null
    @Volatile private var cancellation: CancellationSignal? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPending" -> { ready = true; val values = pending.toList(); pending.clear(); result.success(values) }
                "cancel" -> { cancel(); result.success(null) }
                "releaseIncoming" -> {
                    val path = call.arguments as? String ?: (call.arguments as? Map<*, *>)?.get("path") as? String
                    worker.execute {
                        if (path != null) runCatching {
                            val file = File(path).canonicalFile
                            if (file.parentFile == incoming.canonicalFile && file.name.startsWith("open-")) file.delete()
                        }
                        main.post { if (!closed) result.success(null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
        worker.execute {
            incoming.mkdirs()
            // Remove abandoned copies after a day; active/in-flight imports stay.
            incoming.listFiles()?.filter { it.isFile && it.lastModified() < System.currentTimeMillis() - 86_400_000 }
                ?.forEach { it.delete() }
        }
    }

    @Suppress("DEPRECATION")
    fun accept(intent: Intent?) {
        if (closed || intent == null) return
        val uri: Uri = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
            else -> null
        } ?: return
        cancel()
        val request = generation
        when (uri.scheme?.lowercase()) {
            "http", "https" -> deliver(mapOf("uri" to uri.toString(), "name" to (uri.lastPathSegment ?: "")), request)
            "content", "file" -> worker.execute { copyVideo(uri, intent.type, request) }
            else -> deliver(mapOf("error" to "无法打开此链接：仅支持视频文件或 HTTP/HTTPS 视频直链。"), request)
        }
    }

    private fun copyVideo(uri: Uri, suppliedType: String?, request: Int) {
        var partial: File? = null
        try {
            if (closed || generation != request) return
            incoming.mkdirs()
            val resolver = context.contentResolver
            val mime = suppliedType ?: resolver.getType(uri)
            var name = uri.lastPathSegment ?: ""
            var declaredSize = -1L
            if (uri.scheme == "content") {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) declaredSize = cursor.getLong(sizeIndex)
                    }
                }
            }
            name = name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\x00-\\x1f]"), "").take(180)
            if (name.isBlank()) name = "外部视频." + (MimeTypeMap.getSingleton().getExtensionFromMimeType(mime ?: "") ?: "video")
            val extension = name.substringAfterLast('.', "").lowercase()
            val videoExtensions = setOf("mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts", "mpeg", "mpg", "wmv", "flv", "rmvb", "ogv", "3gp", "vob", "asf", "mts")
            if (mime?.startsWith("video/") != true && mime != "application/x-matroska" && extension !in videoExtensions) {
                deliver(mapOf("error" to "文件类型不受支持，请选择视频文件。"), request); return
            }
            if (declaredSize > 0 && declaredSize + 16L * 1024 * 1024 > incoming.usableSpace) {
                deliver(mapOf("error" to "存储空间不足，无法接收此视频。"), request); return
            }
            val inferred = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime ?: "")
            val suffix = if (extension in videoExtensions) extension else if (inferred in videoExtensions) inferred else "video"
            val target = File(incoming, "open-${UUID.randomUUID()}.$suffix")
            val partFile = File(incoming, "${target.name}.part")
            partial = partFile
            val signal = CancellationSignal()
            cancellation = signal
            val input = if (uri.scheme == "file") File(uri.path ?: "").inputStream()
                else resolver.openAssetFileDescriptor(uri, "r", signal)?.createInputStream()
                    ?: throw java.io.FileNotFoundException()
            reading = input
            var total = 0L
            input.use { source ->
                partFile.outputStream().use { output ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        if (closed || generation != request || Thread.currentThread().isInterrupted) return
                        val count = source.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        total += count
                    }
                }
            }
            if (closed || generation != request) return
            if (total == 0L) { deliver(mapOf("error" to "视频文件为空。"), request); return }
            if (!partFile.renameTo(target)) throw java.io.IOException()
            partial = null
            deliver(mapOf("path" to target.path, "name" to name, "temporary" to true), request)
        } catch (_: SecurityException) {
            if (!closed && request == generation) deliver(mapOf("error" to "没有此视频的读取权限，请从原应用重新选择“打开方式”或“分享”。"), request)
        } catch (_: java.io.FileNotFoundException) {
            if (!closed && request == generation) deliver(mapOf("error" to "视频文件已不存在或无法读取，请重新选择。"), request)
        } catch (_: Exception) {
            if (!closed && request == generation) deliver(mapOf("error" to "接收视频失败，请检查存储空间和原应用的文件授权。"), request)
        } finally {
            partial?.delete()
            if (request == generation) { reading = null; cancellation = null }
        }
    }

    private fun deliver(value: Map<String, Any>, request: Int) {
        main.post {
            if (closed || request != generation) {
                (value["path"] as? String)?.let { File(it).delete() }
                return@post
            }
            if (ready) channel.invokeMethod("onOpen", value) else pending.add(value)
        }
    }

    private fun cancel() {
        generation++
        pending.forEach { value -> (value["path"] as? String)?.let { File(it).delete() } }
        pending.clear()
        cancellation?.cancel()
        cancellation = null
        runCatching { reading?.close() }
        reading = null
    }

    fun close() {
        closed = true
        cancel()
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}
