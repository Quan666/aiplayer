import 'dart:math';

/// Replay completed videos from the beginning. Keep the end window proportional
/// for short clips; a fixed ten-second cutoff would disable their resume entirely.
double playbackResumeSeconds({required double position, double? duration}) {
  if (!position.isFinite || position <= 0) return 0;
  if (duration != null && duration.isFinite && duration > 0) {
    final endWindow = min(10.0, duration * .02);
    if (position >= duration - endWindow) return 0;
  }
  return position;
}
