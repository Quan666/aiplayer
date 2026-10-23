import 'dart:async';

/// mpv accepting a seek command does not mean its observed playback position
/// has changed. Resume local playback only after the remote position is visible.
Future<bool> restoreCastPosition({
  required Duration target,
  required Future<void> Function(Duration) seek,
  required Duration Function() position,
  bool Function()? cancelled,
  Duration deadline = const Duration(milliseconds: 1500),
  Duration tolerance = const Duration(milliseconds: 1500),
}) async {
  final elapsed = Stopwatch()..start();
  try {
    await seek(target).timeout(deadline);
    while (elapsed.elapsed < deadline) {
      if (cancelled?.call() == true) return false;
      if ((position() - target).abs() <= tolerance) return true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return !(cancelled?.call() ?? false) &&
        (position() - target).abs() <= tolerance;
  } catch (_) {
    return false;
  }
}
