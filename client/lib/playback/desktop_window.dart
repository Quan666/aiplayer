import 'dart:io';

import 'package:flutter/services.dart';

/// Controls the application's existing desktop window. Playback stays in Dart's
/// navigator; this bridge never creates another window or Flutter engine.
abstract final class DesktopWindow {
  // Retain the channel name also used by device information lookup.
  static const channel = MethodChannel('app.aiplayer/desktop_player');
  static const _window = MethodChannel('app.aiplayer/window_mode');
  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static void watchClose(Future<void> Function()? onClose) {
    if (!supported) return;
    channel.setMethodCallHandler(
      onClose == null
          ? null
          : (call) async {
              if (call.method == 'closeRequested') await onClose();
            },
    );
  }

  static Future<void> ready() async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>('ready');
    } on MissingPluginException {
      // Widget tests and non-desktop hosts have no native window bridge.
    }
  }

  static Future<void> close() async {
    if (supported) await channel.invokeMethod<void>('closeWindow');
  }

  static Future<bool> setFullscreen(bool enabled) async {
    if (!supported) return false;
    return await _window.invokeMethod<bool>('setVideoFullscreen', {
          'enabled': enabled,
        }) ??
        false;
  }
}
