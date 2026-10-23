import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Temporary display brightness while a mobile player is in the foreground.
/// Native code retains and restores the previous value, including on app pause.
class PlayerDisplay {
  static const _channel = MethodChannel('app.aiplayer/display');

  static bool get supported => Platform.isAndroid || Platform.isIOS;

  /// App-wide high-refresh preference, also used by library and source pages.
  /// Native code requests a suitable rate without locking a display mode;
  /// battery saver and actual frame scheduling remain under system control.
  static Future<void> setHighRefreshRate(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('setHighRefreshRate', enabled);
    } catch (_) {
      // Display preferences must never prevent launching or playing a video.
    }
  }

  /// Native insets API keeps immersive playback working on current Android
  /// targets without disabling edge-to-edge or changing the target SDK.
  static Future<void> setImmersive(bool immersive) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setImmersive', immersive);
    } catch (_) {
      // Older runtimes use SystemChrome's compatibility path.
    }
  }

  /// Explicitly show both bars before requesting edge-to-edge. Android < 29
  /// ignores edgeToEdge, so using it alone leaves immersive flags behind.
  /// Keep the video's orientation when only revealing system bars in playback;
  /// give orientation back to the system when the player page is disposed.
  static Future<void> restoreSystemUi({bool restoreOrientation = true}) async {
    if (restoreOrientation) await SystemChrome.setPreferredOrientations([]);
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await setImmersive(false);
  }

  final orientation = ValueNotifier<String?>(null);
  static PlayerDisplay? _orientationOwner;
  bool _watchingOrientation = false;

  Future<void> watchOrientation(bool enabled) async {
    if (!Platform.isAndroid || _disposed || enabled == _watchingOrientation) {
      return;
    }
    _watchingOrientation = enabled;
    if (enabled) {
      _orientationOwner = this;
      _channel.setMethodCallHandler((call) async {
        if (!_disposed &&
            call.method == 'orientationChanged' &&
            call.arguments is String) {
          orientation.value = call.arguments as String;
        }
      });
    }
    try {
      await _channel.invokeMethod<void>('watchOrientation', enabled);
    } catch (_) {}
  }

  bool _disposed = false;

  Future<double> readBrightness() async {
    if (!supported || _disposed) return 0.5;
    try {
      final value = await _channel.invokeMethod<num>('readBrightness');
      if (value == null || !value.isFinite) return 0.5;
      return value.toDouble().clamp(0.0, 1.0);
    } catch (_) {
      return 0.5;
    }
  }

  Future<void> setBrightness(double value) async {
    if (!supported || _disposed || !value.isFinite) return;
    try {
      await _channel.invokeMethod<void>('setBrightness', value.clamp(0.0, 1.0));
    } catch (_) {
      // Brightness is optional: a missing/failed platform channel must not
      // interrupt playback or expose native exception details to the user.
    }
  }

  Future<void> restoreBrightness() async {
    if (!supported || _disposed) return;
    try {
      await _channel.invokeMethod<void>('restoreBrightness');
    } catch (_) {
      // Native lifecycle hooks also restore when the app loses focus.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(_orientationOwner, this)) {
      _orientationOwner = null;
      _channel.setMethodCallHandler(null);
      try {
        await _channel.invokeMethod<void>('watchOrientation', false);
      } catch (_) {}
    }
    orientation.dispose();
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('dispose');
    } catch (_) {
      // Disposal remains safe on unsupported or unavailable native runtimes.
    }
  }
}
