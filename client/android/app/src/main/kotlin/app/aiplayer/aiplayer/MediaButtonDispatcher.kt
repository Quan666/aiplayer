package app.aiplayer.aiplayer

import android.view.KeyEvent

/** One bounded, event-driven single/double-tap decision for headset buttons. */
internal class MediaButtonDispatcher(
    private val scheduleTap: (() -> Unit) -> Unit,
    private val cancelTap: () -> Unit,
    private val canGoNext: () -> Boolean,
    private val emit: (String) -> Unit,
) {
    private data class Press(val key: Int, val down: Long, val time: Long, val device: Int)
    private var lastPress: Press? = null
    private var tapPending = false

    fun handles(key: Int): Boolean = actionFor(key) != null

    fun handle(key: Int, action: Int, repeat: Int, down: Long, time: Long, device: Int): Boolean {
        val command = actionFor(key) ?: return false
        // Consume release/repeat as well: Flutter must not toggle the same key again.
        if (action != KeyEvent.ACTION_DOWN || repeat != 0) return true
        val press = Press(key, down, time, device)
        if (press == lastPress) return true
        lastPress = press
        if (command == "toggle") {
            if (tapPending) {
                cancelTap()
                tapPending = false
                emit(if (canGoNext()) "next" else "toggle")
            } else {
                tapPending = true
                scheduleTap {
                    if (tapPending) {
                        tapPending = false
                        emit("toggle")
                    }
                }
            }
        } else {
            if (tapPending) {
                cancelTap()
                tapPending = false
                emit("toggle")
            }
            emit(command)
        }
        return true
    }

    fun clear() {
        cancelTap()
        tapPending = false
        lastPress = null
    }

    private fun actionFor(key: Int): String? = when (key) {
        KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> "toggle"
        KeyEvent.KEYCODE_MEDIA_PLAY -> "play"
        KeyEvent.KEYCODE_MEDIA_PAUSE -> "pause"
        KeyEvent.KEYCODE_MEDIA_STOP -> "stop"
        KeyEvent.KEYCODE_MEDIA_NEXT -> "next"
        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "previous"
        KeyEvent.KEYCODE_MEDIA_FAST_FORWARD, KeyEvent.KEYCODE_MEDIA_SKIP_FORWARD -> "seekForward"
        KeyEvent.KEYCODE_MEDIA_REWIND, KeyEvent.KEYCODE_MEDIA_SKIP_BACKWARD -> "seekBackward"
        else -> null
    }
}
