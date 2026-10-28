package app.aiplayer.aiplayer

import android.view.KeyEvent

fun main() {
    val commands = mutableListOf<String>()
    var pending: (() -> Unit)? = null
    var next = true
    val buttons = MediaButtonDispatcher(
        scheduleTap = { check(pending == null); pending = it },
        cancelTap = { pending = null },
        canGoNext = { next },
        emit = commands::add,
    )
    var clock = 1L
    fun press(key: Int, action: Int = KeyEvent.ACTION_DOWN, repeat: Int = 0): Boolean =
        buttons.handle(key, action, repeat, clock, clock++, 0)
    fun settle() { val callback = pending; pending = null; callback?.invoke() }

    check(press(KeyEvent.KEYCODE_HEADSETHOOK))
    check(commands.isEmpty())
    check(press(KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.ACTION_UP))
    settle()
    check(commands == listOf("toggle"))

    commands.clear()
    press(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
    press(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.ACTION_DOWN, 1)
    settle()
    check(commands == listOf("toggle"))

    commands.clear()
    press(KeyEvent.KEYCODE_HEADSETHOOK)
    press(KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.ACTION_UP)
    press(KeyEvent.KEYCODE_HEADSETHOOK)
    settle()
    check(commands == listOf("next"))

    commands.clear()
    next = false
    press(KeyEvent.KEYCODE_HEADSETHOOK)
    press(KeyEvent.KEYCODE_HEADSETHOOK)
    settle()
    check(commands == listOf("toggle"))

    commands.clear()
    val key = KeyEvent.KEYCODE_MEDIA_NEXT
    check(buttons.handle(key, KeyEvent.ACTION_DOWN, 0, 100, 100, 1))
    check(buttons.handle(key, KeyEvent.ACTION_DOWN, 0, 100, 100, 1))
    check(buttons.handle(key, KeyEvent.ACTION_UP, 0, 100, 101, 1))
    check(commands == listOf("next"))

    commands.clear()
    press(KeyEvent.KEYCODE_HEADSETHOOK)
    press(KeyEvent.KEYCODE_MEDIA_PAUSE)
    settle()
    check(commands == listOf("toggle", "pause"))

    commands.clear()
    press(KeyEvent.KEYCODE_HEADSETHOOK)
    val staleTap = pending
    buttons.clear()
    staleTap?.invoke()
    settle()
    check(commands.isEmpty())
    check(pending == null)

    val keys = mapOf(
        KeyEvent.KEYCODE_MEDIA_PLAY to "play",
        KeyEvent.KEYCODE_MEDIA_PAUSE to "pause",
        KeyEvent.KEYCODE_MEDIA_STOP to "stop",
        KeyEvent.KEYCODE_MEDIA_PREVIOUS to "previous",
        KeyEvent.KEYCODE_MEDIA_NEXT to "next",
        KeyEvent.KEYCODE_MEDIA_FAST_FORWARD to "seekForward",
        KeyEvent.KEYCODE_MEDIA_SKIP_FORWARD to "seekForward",
        KeyEvent.KEYCODE_MEDIA_REWIND to "seekBackward",
        KeyEvent.KEYCODE_MEDIA_SKIP_BACKWARD to "seekBackward",
    )
    for ((code, action) in keys) {
        commands.clear()
        check(press(code))
        check(press(code, KeyEvent.ACTION_UP))
        check(press(code, KeyEvent.ACTION_DOWN, 1))
        check(commands == listOf(action))
    }
    check(!press(KeyEvent.KEYCODE_VOLUME_UP))
    check(!press(KeyEvent.KEYCODE_VOLUME_DOWN))
    check(!press(KeyEvent.KEYCODE_DPAD_CENTER))
    println("Android media button checks passed")
}
