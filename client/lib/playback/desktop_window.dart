import 'dart:async';
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
  static final _controlsVisible = ValueNotifier(true);
  static ValueListenable<bool> get controlsVisible => _controlsVisible;
  static DesktopPlaybackControls? _playbackControls;
  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static void watchClose(Future<void> Function()? onClose) {
    if (!supported) return;
    if (onClose == null) {
      _playbackControls = null;
      _setControlsVisible(true);
    }
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

  static Future<void> _control(String method, [Object? arguments]) async {
    if (!supported) return;
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Tests and an engine detaching during close have no native controls.
    }
  }

  /// A replacement player owns visibility immediately. Late callbacks or
  /// disposal from the previous player cannot reveal its window controls.
  static DesktopPlaybackControls beginPlaybackControls() {
    final controls = DesktopPlaybackControls._();
    _playbackControls = controls;
    _setControlsVisible(true);
    return controls;
  }

  static void _setControlsVisible(bool visible) {
    if (_controlsVisible.value == visible) return;
    _controlsVisible.value = visible;
    // Native traffic lights and hit testing update even without another frame.
    unawaited(_control('setControlsVisible', {'visible': visible}));
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

/// Lifetime of a player's control overlay; uses its existing hide timer.
final class DesktopPlaybackControls {
  DesktopPlaybackControls._();

  void setVisible(bool visible) {
    if (identical(DesktopWindow._playbackControls, this)) {
      DesktopWindow._setControlsVisible(visible);
    }
  }

  void dispose() {
    if (!identical(DesktopWindow._playbackControls, this)) return;
    DesktopWindow._playbackControls = null;
    DesktopWindow._setControlsVisible(true);
  }
}
