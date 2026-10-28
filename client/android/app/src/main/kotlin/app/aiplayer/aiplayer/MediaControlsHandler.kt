package app.aiplayer.aiplayer

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import android.view.ViewConfiguration
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** System/headset transport controls for the currently open local player. */
internal class MediaControlsHandler(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "app.aiplayer/media_controls")
    private val handler = Handler(Looper.getMainLooper())
    private var session: MediaSession? = null
    private var sessionId = 0L
    private var pauseRevision = 0L
    private var latestSessionId = 0L
    private var latestPauseRevision = 0L
    private var clearedThroughSessionId = 0L
    private var closed = false
    private var playing = false
    private var canGoNext = false
    private var canGoPrevious = false
    private var noisyReceiver: BroadcastReceiver? = null
    private var tap: Runnable? = null
    private var buttons: MediaButtonDispatcher? = null
    private var metadata: Pair<String, Long>? = null
    private var originalVolumeStream: Int? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    update(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                    result.success(null)
                }
                "clear" -> {
                    val id = call.argument<Number>("sessionId")?.toLong() ?: 0L
                    if (id > 0L) {
                        latestSessionId = maxOf(latestSessionId, id)
                        clearedThroughSessionId = maxOf(clearedThroughSessionId, id)
                        if (sessionId <= id) release()
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun update(values: Map<*, *>) {
        val id = (values["sessionId"] as? Number)?.toLong() ?: return
        if (closed || id <= clearedThroughSessionId || id < latestSessionId) return
        val revision = (values["pauseRevision"] as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L
        if (id == latestSessionId && revision < latestPauseRevision) return
        latestSessionId = id
        latestPauseRevision = revision
        if (values["active"] != true) {
            release()
            return
        }
        if (sessionId != id || pauseRevision != revision || session == null) {
            // Replace callback ownership at the pause boundary. Queued callbacks
            // and a pending headset click retain the old revision and cannot
            // turn into fresh play requests after a rapid background/foreground.
            release()
            sessionId = id
            pauseRevision = revision
            createSession(id, revision)
        }
        val current = session ?: return
        playing = values["playing"] == true
        canGoNext = values["canGoNext"] == true
        canGoPrevious = values["canGoPrevious"] == true
        val buffering = values["buffering"] == true
        val completed = values["completed"] == true
        val duration = (values["durationMs"] as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L
        val position = (values["positionMs"] as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L
        val speed = (values["speed"] as? Number)?.toFloat()?.takeIf { it.isFinite() && it > 0f } ?: 1f
        val title = values["title"] as? String ?: ""
        val nextMetadata = title to duration
        if (metadata != nextMetadata) {
            metadata = nextMetadata
            current.setMetadata(MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, duration)
                .build())
        }
        var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_FAST_FORWARD or PlaybackState.ACTION_REWIND
        if (canGoNext) actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
        if (canGoPrevious) actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        val state = when {
            completed -> PlaybackState.STATE_STOPPED
            buffering && playing -> PlaybackState.STATE_BUFFERING
            playing -> PlaybackState.STATE_PLAYING
            else -> PlaybackState.STATE_PAUSED
        }
        current.setPlaybackState(PlaybackState.Builder()
            .setActions(actions)
            .setState(state, position, if (playing && !buffering && !completed) speed else 0f,
                SystemClock.elapsedRealtime())
            .build())
        current.isActive = true
        watchNoisy(playing && !completed, id, revision)
    }

    @Suppress("DEPRECATION")
    private fun createSession(id: Long, revision: Long) {
        val current = MediaSession(activity, "aiplayer")
        session = current
        current.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
        // No restart receiver/service: closing playback gives media keys back to the system.
        current.setMediaButtonReceiver(null)
        current.setPlaybackToLocal(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build())
        originalVolumeStream = activity.volumeControlStream
        activity.volumeControlStream = AudioManager.STREAM_MUSIC
        buttons = MediaButtonDispatcher(
            scheduleTap = { action ->
                val pending = Runnable { tap = null; action() }
                tap = pending
                handler.postDelayed(pending, ViewConfiguration.getDoubleTapTimeout().toLong())
            },
            cancelTap = { tap?.let(handler::removeCallbacks); tap = null },
            canGoNext = { canGoNext },
            emit = { action -> send(id, revision, action) },
        )
        current.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = send(id, revision, "play")
            override fun onPause() = send(id, revision, "pause")
            override fun onStop() = send(id, revision, "stop")
            override fun onSkipToNext() = send(id, revision, "next")
            override fun onSkipToPrevious() = send(id, revision, "previous")
            override fun onFastForward() = send(id, revision, "seekForward")
            override fun onRewind() = send(id, revision, "seekBackward")
            override fun onSeekTo(pos: Long) = send(id, revision, "seek", pos.coerceAtLeast(0L))

            override fun onMediaButtonEvent(intent: Intent): Boolean {
                if (!isCurrent(id, revision) || session !== current || intent.action != Intent.ACTION_MEDIA_BUTTON) {
                    return false
                }
                val event = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                } else {
                    intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                } ?: return false
                return dispatchKeyEvent(event)
            }
        }, handler)
    }

    fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (session?.isActive != true) return false
        return buttons?.handle(event.keyCode, event.action, event.repeatCount,
            event.downTime, event.eventTime, event.deviceId) == true
    }

    private fun isCurrent(id: Long, revision: Long): Boolean =
        !closed && id == sessionId && revision == pauseRevision && session?.isActive == true

    private fun send(id: Long, revision: Long, action: String, position: Long? = null) {
        if (!isCurrent(id, revision)) return
        if (action == "next" && !canGoNext || action == "previous" && !canGoPrevious) return
        val args = mutableMapOf<String, Any>(
            "sessionId" to id, "pauseRevision" to revision, "action" to action)
        if (position != null) args["positionMs"] = position
        channel.invokeMethod("command", args)
    }

    @Suppress("DEPRECATION")
    private fun watchNoisy(enabled: Boolean, id: Long, revision: Long) {
        if (!enabled) {
            noisyReceiver?.let(activity::unregisterReceiver)
            noisyReceiver = null
            return
        }
        if (noisyReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (isCurrent(id, revision) && playing &&
                    intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    // A pending single-click must not resume audio on the speaker
                    // after the unplug pause arrives during the double-tap window.
                    buttons?.clear()
                    send(id, revision, "pause")
                }
            }
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(receiver, filter)
        }
        noisyReceiver = receiver
    }

    private fun release() {
        sessionId = 0L
        pauseRevision = 0L
        playing = false
        canGoNext = false
        canGoPrevious = false
        buttons?.clear()
        buttons = null
        watchNoisy(false, 0L, 0L)
        session?.apply {
            isActive = false
            setCallback(null)
            release()
        }
        session = null
        metadata = null
        originalVolumeStream?.let { activity.volumeControlStream = it }
        originalVolumeStream = null
    }

    fun close() {
        closed = true
        release()
        channel.setMethodCallHandler(null)
    }
}
