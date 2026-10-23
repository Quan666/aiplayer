import 'dart:math';
import 'dart:async';
import 'package:flutter/services.dart';

enum PlaybackTapRegion { left, center, right }

/// Gesture regions follow the visible player's three equal-width columns.
PlaybackTapRegion playbackTapRegion({
  required double localX,
  required double width,
}) {
  if (!localX.isFinite || !width.isFinite || width <= 0) {
    return PlaybackTapRegion.center;
  }
  if (localX < width / 3) return PlaybackTapRegion.left;
  if (localX >= width * 2 / 3) return PlaybackTapRegion.right;
  return PlaybackTapRegion.center;
}

String? shortcutAction(
  KeyEvent event,
  Map<String, String> shortcuts, {
  bool editingText = false,
  bool respectRepeatPolicy = true,
}) {
  if (editingText || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
    return null;
  }
  final keyboard = HardwareKeyboard.instance;
  final modifiers = <String>[
    if (keyboard.isControlPressed) 'Ctrl',
    if (keyboard.isAltPressed) 'Alt',
    if (keyboard.isShiftPressed) 'Shift',
    if (keyboard.isMetaPressed) 'Meta',
  ];
  final key = switch (event.logicalKey) {
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.arrowLeft => 'ArrowLeft',
    LogicalKeyboardKey.arrowRight => 'ArrowRight',
    LogicalKeyboardKey.arrowUp => 'ArrowUp',
    LogicalKeyboardKey.arrowDown => 'ArrowDown',
    LogicalKeyboardKey.escape => 'Escape',
    LogicalKeyboardKey.comma => 'Comma',
    LogicalKeyboardKey.period => 'Period',
    LogicalKeyboardKey.enter => 'Enter',
    LogicalKeyboardKey.backspace => 'Backspace',
    LogicalKeyboardKey.home => 'Home',
    LogicalKeyboardKey.end => 'End',
    _ => event.logicalKey.keyLabel.toUpperCase(),
  };
  final pressed = [...modifiers, key].join('+').toLowerCase();
  for (final entry in shortcuts.entries) {
    final parts = entry.value
        .split('+')
        .map((part) => part.trim().toLowerCase())
        .toList();
    final normalized = [
      for (final modifier in ['ctrl', 'alt', 'shift', 'meta'])
        if (parts.contains(modifier)) modifier,
      parts.last,
    ].join('+');
    if (normalized != pressed) continue;
    if (respectRepeatPolicy &&
        event is KeyRepeatEvent &&
        !{
          'seekBackward',
          'seekForward',
          'volumeUp',
          'volumeDown',
        }.contains(entry.key)) {
      return null;
    }
    return entry.key;
  }
  return null;
}

double gestureSeekTarget({
  required double startSeconds,
  required double deltaX,
  required double width,
  required double durationSeconds,
}) {
  if (width <= 0 || durationSeconds <= 0) return 0;
  return (startSeconds + deltaX / width * min(120, durationSeconds)).clamp(
    0,
    durationSeconds,
  );
}

double gestureLevel({
  required double start,
  required double deltaY,
  required double height,
}) {
  if (height <= 0) return start.clamp(0, 1);
  return (start - deltaY / height).clamp(0, 1);
}

/// Use display-corrected dimensions, then account for the video rotation tag.
/// null means metadata has not arrived; defer automatic orientation until then.
bool? videoIsLandscape({int? width, int? height, int rotation = 0}) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  final quarterTurn = rotation.abs() % 180 == 90;
  // Only a strictly taller video requires portrait playback; square footage
  // keeps the landscape window instead of introducing an unnecessary rotation.
  return quarterTurn ? height >= width : width >= height;
}

/// Texture allocation and decoder output size can arrive on different frames.
/// Size the video from its display metadata so a temporary texture size never
/// changes the visible aspect ratio. Display dimensions include pixel aspect.
double? videoAspectRatio({int? width, int? height, int rotation = 0}) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return rotation.abs() % 180 == 90 ? height / width : width / height;
}

/// One timer for all control interactions. Pointer drags and modal panels hold
/// it open; releasing an interaction always starts a fresh, complete interval.
class PlaybackControlsTimer {
  final void Function() onHide;
  Timer? _timer;
  int _holds = 0, _seconds = 3;
  bool _playing = false, _disposed = false;
  int _generation = 0;
  PlaybackControlsTimer(this.onHide);
  void configure({required bool playing, required int seconds}) {
    if (_playing == playing && _seconds == seconds) return;
    _playing = playing;
    _seconds = seconds;
    arm();
  }

  void arm() {
    cancel();
    if (_disposed || !_playing || _seconds <= 0 || _holds > 0) return;
    final generation = _generation;
    _timer = Timer(Duration(seconds: _seconds), () {
      if (generation != _generation) return;
      _timer = null;
      if (!_disposed && _playing && _holds == 0) onHide();
    });
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void hold() {
    if (_disposed) return;
    _holds++;
    cancel();
  }

  void release() {
    if (_holds > 0) _holds--;
    arm();
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}

/// A click is decided from the state at pointer-down. Hover, a delayed tap
/// recognizer, or a playback update must not turn a reveal into a hide.
class PlaybackTapIntent {
  bool? _visibleAtDown;
  Stopwatch? _hoverReveal;
  void hoverRevealed() => _hoverReveal = Stopwatch()..start();
  void pointerDown({required bool visible}) {
    final hover = _hoverReveal;
    _visibleAtDown =
        visible && !(hover != null && hover.elapsedMilliseconds < 500);
    _hoverReveal = null;
  }

  bool resolve({required bool visible}) {
    final show = !(_visibleAtDown ?? visible);
    _visibleAtDown = null;
    return show;
  }

  void cancel() => _visibleAtDown = null;
}
