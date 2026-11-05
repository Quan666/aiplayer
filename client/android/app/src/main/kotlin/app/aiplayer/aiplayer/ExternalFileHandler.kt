package app.aiplayer.aiplayer

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class ExternalFileProvider : FileProvider()

/** Only the explicitly selected URI receives a temporary read grant. */
class ExternalFileHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "app.aiplayer/file_open")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    private var opening = false
    private var resumed = false
    private var generation = 0

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "cancel") {
                generation++
                result.success(null)
            } else if (call.method != "open") {
                result.notImplemented()
            } else {
                val path = call.arguments as? String
                if (path.isNullOrBlank()) {
                    result.error("invalid_file", "文件位置无效。", null)
                } else if (opening) {
                    result.error("busy", "正在打开文件，请稍候。", null)
                } else if (!resumed) {
                    result.error("cancelled", "请返回应用后重试。", null)
                } else {
                    opening = true
                    val request = generation
                    worker.execute {
                        try {
                            val file = File(path).canonicalFile
                            if (!file.isFile || !file.canRead()) {
                                main.post {
                                    opening = false
                                    result.error("unreadable_file", "文件不可访问，请刷新后重试。", null)
                                }
                                return@execute
                            }
                            val uri = FileProvider.getUriForFile(
                                activity, "${activity.packageName}.external_files", file)
                            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
                                ?: "application/octet-stream"
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, mime)
                                clipData = ClipData.newRawUri(file.name, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            main.post {
                                opening = false
                                if (closed || !resumed || request != generation ||
                                    activity.isFinishing || activity.isDestroyed) {
                                    result.error("cancelled", "文件打开已取消。", null)
                                } else try {
                                    activity.startActivity(intent)
                                    result.success(null)
                                } catch (_: ActivityNotFoundException) {
                                    result.error("no_handler", "没有可打开此文件的应用。", null)
                                } catch (_: Exception) {
                                    result.error("open_failed", "无法使用其他应用打开此文件。", null)
                                }
                            }
                        } catch (_: Exception) {
                            main.post {
                                opening = false
                                result.error("open_failed", "无法使用其他应用打开此文件。", null)
                            }
                        }
                    }
                }
            }
        }
    }

    fun setResumed(active: Boolean) {
        if (resumed == active) return
        resumed = active
        if (!active) generation++
    }

    fun close() {
        closed = true
        generation++
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
}
