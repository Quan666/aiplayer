package app.aiplayer.aiplayer

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** PAC may call Binder or DNS. Resolve only on a bounded platform worker, never
 * on Flutter's platform/UI thread. No receiver, cache, timer or idle polling. */
class SystemProxyHandler(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "app.aiplayer/system_proxy")
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(
        1, 1, 30L, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(32),
        { runnable -> Thread(runnable, "aiplayer-system-proxy").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy()
    ).apply { allowCoreThreadTimeOut(true) }
    // Accessed only on the platform thread; worker replies are posted to it.
    private val pending = mutableMapOf<String, Pending>()
    @Volatile private var closed = false

    private class Pending(val result: MethodChannel.Result) {
        lateinit var work: FutureTask<Unit>
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "resolve" -> {
                    val id = call.argument<String>("id")
                    val url = call.argument<String>("url")
                    if (closed || id == null || id.length > 128 || url == null ||
                        url.length > 16384 || pending.containsKey(id)) {
                        result.error("proxy_unavailable", "无法读取系统代理。", null)
                    } else {
                        resolve(id, url, result)
                    }
                }
                "cancel" -> {
                    val id = call.argument<String>("id")
                    if (id != null) cancel(id, "proxy_cancelled")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun resolve(id: String, url: String, result: MethodChannel.Result) {
        val request = Pending(result)
        request.work = FutureTask {
            if (!closed && !Thread.currentThread().isInterrupted) {
                val value = try {
                    SystemProxyResolver.resolve(url)
                } catch (_: UnsupportedOperationException) {
                    null
                } catch (_: Exception) {
                    ""
                }
                main.post {
                    if (!closed && pending[id] === request) {
                        pending.remove(id)
                        when (value) {
                            null -> result.error("proxy_unsupported", "系统代理类型暂不支持。", null)
                            "" -> result.error("proxy_resolution_failed", "无法解析系统代理。", null)
                            else -> result.success(value)
                        }
                    }
                }
            }
        }
        pending[id] = request
        try {
            worker.execute(request.work)
        } catch (_: RejectedExecutionException) {
            pending.remove(id)
            result.error("proxy_busy", "系统代理查询繁忙，请稍后重试。", null)
        }
    }

    private fun cancel(id: String, code: String) {
        val request = pending.remove(id) ?: return
        request.work.cancel(true)
        worker.remove(request.work)
        request.result.error(code, "系统代理查询已取消。", null)
    }

    fun close() {
        if (closed) return
        closed = true
        channel.setMethodCallHandler(null)
        pending.keys.toList().forEach { cancel(it, "proxy_disposed") }
        worker.shutdownNow()
        main.removeCallbacksAndMessages(null)
    }
}
