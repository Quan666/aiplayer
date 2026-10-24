package app.aiplayer.aiplayer

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.util.Rational
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.Settings
import android.os.Build
import android.os.PowerManager
import android.view.OrientationEventListener
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

class MainActivity : FlutterActivity() {
    private var windowModeChannel: MethodChannel? = null
    private var externalVideos: ExternalVideoHandler? = null
    private var systemProxy: SystemProxyHandler? = null
    private var deviceInfoChannel: MethodChannel? = null
    private var displayChannel: MethodChannel? = null
    private var discoveryChannel: MethodChannel? = null
    private var originalBrightness: Float? = null
    private var displayActive = false
    private var highRefreshRequested = false
    private var immersiveActive = false
    private var orientationListener: OrientationEventListener? = null
    private var lastGravityOrientation: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deviceInfoChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "app.aiplayer/device_info").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "getDeviceInfo") result.notImplemented()
                else {
                    val name = Settings.Global.getString(contentResolver, "device_name")
                        ?.takeIf { it.isNotBlank() } ?: Build.MODEL
                    val model = if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true))
                        Build.MODEL else "${Build.MANUFACTURER} ${Build.MODEL}"
                    result.success(mapOf("name" to name, "model" to model, "platform" to "Android"))
                }
            }
        }
        externalVideos = ExternalVideoHandler(this, flutterEngine.dartExecutor.binaryMessenger)
        externalVideos?.accept(intent)
        systemProxy?.close()
        systemProxy = SystemProxyHandler(flutterEngine.dartExecutor.binaryMessenger)
        displayChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.aiplayer/display"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                runOnUiThread {
                    when (call.method) {
                        "watchOrientation" -> {
                            watchOrientation(call.arguments == true)
                            result.success(null)
                        }
                        "setImmersive" -> {
                            applyImmersiveBars(call.arguments == true)
                            result.success(null)
                        }
                        "setHighRefreshRate" -> {
                            setHighRefreshRate(call.arguments == true)
                            result.success(null)
                        }
                        "readBrightness" -> result.success(readBrightness())
                        "setBrightness" -> {
                            val value = (call.arguments as? Number)?.toDouble()
                            if (displayActive && value != null && value.isFinite()) {
                                val attributes = window.attributes
                                if (originalBrightness == null) {
                                    originalBrightness = attributes.screenBrightness
                                }
                                attributes.screenBrightness = value.coerceIn(0.0, 1.0).toFloat()
                                window.attributes = attributes
                            }
                            result.success(null)
                        }
                        "restoreBrightness", "dispose" -> {
                            restoreBrightness()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        }
        windowModeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "app.aiplayer/window_mode").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                when (call.method) {
                    "supported" -> result.success(supported)
                    "enter" -> {
                        if (!supported) result.success(false)
                        else try {
                            val value = (call.argument<Number>("aspectRatio")?.toDouble() ?: (16.0 / 9))
                            val ratio = if (value.isFinite()) value.coerceIn(.42, 2.39) else 16.0 / 9
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational((ratio * 1000).toInt(), 1000)).build()
                            result.success(enterPictureInPictureMode(params))
                        } catch (_: Exception) {
                            result.error("pip_denied", "无法进入小窗，请在系统设置中允许画中画。", null)
                        }
                    }
                    "exit" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode) {
                            startActivity(Intent(this, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        discoveryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.aiplayer/discovery"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                runOnUiThread {
                    when (call.method) {
                        "interfaces" -> {
                            try {
                                result.success(localInterfaces())
                            } catch (_: SecurityException) {
                                result.error("permission_denied", "无法读取本地网络信息。", null)
                            } catch (_: Exception) {
                                result.error("discovery_failed", "无法读取本地网络信息。", null)
                            }
                        }
                        "cancel" -> result.success(null)
                        else -> result.notImplemented()
                    }
                }
            }
        }
    }

    override fun onPictureInPictureModeChanged(active: Boolean, configuration: Configuration) {
        super.onPictureInPictureModeChanged(active, configuration)
        windowModeChannel?.invokeMethod("changed", active)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        externalVideos?.accept(intent)
    }

    private fun localInterfaces(): List<Map<String, Any>> {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return manager.allNetworks.flatMap { network ->
            val capabilities = manager.getNetworkCapabilities(network)
            if (capabilities == null || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
                (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))) {
                emptyList()
            } else {
                manager.getLinkProperties(network)?.linkAddresses.orEmpty().mapNotNull { link ->
                    val address = link.address
                    val host = address.hostAddress
                    if (address is Inet4Address && !address.isLoopbackAddress &&
                        !address.isAnyLocalAddress && host != null) {
                        mapOf<String, Any>("address" to host, "prefixLength" to link.prefixLength)
                    } else null
                }
            }
        }.distinctBy { "${it["address"]}/${it["prefixLength"]}" }
    }

    private fun watchOrientation(enabled: Boolean) {
        orientationListener?.disable()
        orientationListener = null
        lastGravityOrientation = null
        if (!enabled) return
        orientationListener = object : OrientationEventListener(this) {
            override fun onOrientationChanged(degrees: Int) {
                if (degrees == ORIENTATION_UNKNOWN) return
                // Hysteresis around diagonal angles prevents rapid route flips.
                val orientation = when (degrees) {
                    in 0..25, in 335..359 -> "portraitUp"
                    in 65..115 -> "landscapeRight"
                    in 155..205 -> "portraitDown"
                    in 245..295 -> "landscapeLeft"
                    else -> return
                }
                val previous = lastGravityOrientation
                lastGravityOrientation = orientation
                if (previous == null || previous == orientation) return
                val unlocked = runCatching {
                    Settings.System.getInt(contentResolver, Settings.System.ACCELEROMETER_ROTATION, 0) == 1
                }.getOrDefault(false)
                if (displayActive && unlocked) {
                    displayChannel?.invokeMethod("orientationChanged", orientation)
                }
            }
        }.also { if (displayActive && it.canDetectOrientation()) it.enable() }
    }

    private fun applyImmersiveBars(enabled: Boolean) {
        immersiveActive = enabled
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.apply {
                if (enabled) {
                    systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    hide(WindowInsets.Type.systemBars())
                } else {
                    show(WindowInsets.Type.systemBars())
                }
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && immersiveActive) applyImmersiveBars(true)
        if (hasFocus) applyRefreshRatePreference()
    }

    private fun setHighRefreshRate(enabled: Boolean) {
        highRefreshRequested = enabled
        applyRefreshRatePreference()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applyRefreshRatePreference()
    }

    @Suppress("DEPRECATION")
    private fun applyRefreshRatePreference() {
        val currentDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else windowManager.defaultDisplay
        if (currentDisplay == null) return
        val current = currentDisplay.mode
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        val enabled = highRefreshRequested && displayActive && !power.isPowerSaveMode
        val rates = currentDisplay.supportedModes
            .filter { it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight }
            .map { it.refreshRate }
            .filter { it.isFinite() && it > 60.5f }
        // Prefer a useful 90/120 Hz UI rate over a panel's extreme maximum.
        // Request only a rate: locking a physical mode can cause visible mode
        // switches, and prevents Android from choosing its own idle cadence.
        val smoothRate = rates.filter { it <= 120.5f }.maxOrNull()
            ?: rates.minOrNull() ?: 0f
        val preferred = if (enabled) smoothRate else 0f
        val attributes = window.attributes
        if (attributes.preferredDisplayModeId == 0 &&
            attributes.preferredRefreshRate == preferred) return
        attributes.preferredDisplayModeId = 0
        attributes.preferredRefreshRate = preferred
        window.attributes = attributes
    }

    private fun readBrightness(): Double {
        val value = window.attributes.screenBrightness
        if (value >= 0f) return value.toDouble().coerceIn(0.0, 1.0)
        // Reading the system value needs no WRITE_SETTINGS permission. The app
        // always changes its own window, leaving automatic/system brightness alone.
        return try {
            (Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0)
                .coerceIn(0.0, 1.0)
        } catch (_: Exception) {
            0.5
        }
    }

    private fun restoreBrightness() {
        val value = originalBrightness ?: return
        originalBrightness = null
        val attributes = window.attributes
        attributes.screenBrightness = value
        window.attributes = attributes
    }

    override fun onResume() {
        super.onResume()
        displayActive = true
        applyRefreshRatePreference()
        lastGravityOrientation = null
        orientationListener?.let { if (it.canDetectOrientation()) it.enable() }
    }

    override fun onPause() {
        displayActive = false
        applyRefreshRatePreference()
        orientationListener?.disable()
        restoreBrightness()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        windowModeChannel?.setMethodCallHandler(null)
        windowModeChannel = null
        deviceInfoChannel?.setMethodCallHandler(null)
        deviceInfoChannel = null
        externalVideos?.close()
        externalVideos = null
        systemProxy?.close()
        systemProxy = null
        watchOrientation(false)
        applyImmersiveBars(false)
        restoreBrightness()
        displayChannel?.setMethodCallHandler(null)
        displayChannel = null
        discoveryChannel?.setMethodCallHandler(null)
        discoveryChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
