import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef DesktopWindowState = ({bool fullscreen, bool maximized});

/// Controls the application's existing desktop window. Playback stays in Dart's
/// navigator; this bridge never creates another window or Flutter engine.
abstract final class DesktopWindow {
  // Retain the channel name also used by device information lookup.
  static const channel = MethodChannel('app.aiplayer/desktop_player');
  static const _window = MethodChannel('app.aiplayer/window_mode');
  static final _state = ValueNotifier<DesktopWindowState>((
    fullscreen: false,
    maximized: false,
  ));
  static ValueListenable<DesktopWindowState> get state => _state;
  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static void watchClose(Future<void> Function()? onClose) {
    if (!supported) return;
    _state.value = (fullscreen: false, maximized: false);
    channel.setMethodCallHandler(
      onClose == null
          ? null
          : (call) async {
              if (call.method == 'closeRequested') {
                await onClose();
              } else if (call.method == 'windowStateChanged') {
                _updateState(call.arguments);
              }
            },
    );
  }

  static Future<void> ready() async {
    if (!supported) return;
    try {
      _updateState(await channel.invokeMethod<Object?>('ready'));
    } on MissingPluginException {
      // Widget tests and non-desktop hosts have no native window bridge.
    }
  }

  static void _updateState(Object? value) {
    if (value is! Map ||
        value['fullscreen'] is! bool ||
        value['maximized'] is! bool) {
      return;
    }
    _state.value = (
      fullscreen: value['fullscreen'] as bool,
      maximized: value['maximized'] as bool,
    );
  }

  static Future<void> _control(String method) async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Tests and an engine detaching during close have no native controls.
    }
  }

  static Future<void> startDrag() => _control('startDrag');
  static Future<void> minimize() => _control('minimize');
  static Future<void> toggleMaximize() => _control('toggleMaximize');

  /// Goes through the same native close request as the system close button,
  /// allowing the app to save progress before [close] destroys the window.
  static Future<void> requestClose() => _control('requestClose');

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
