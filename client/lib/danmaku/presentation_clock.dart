/// The native playback clock is corrected whenever a position event arrives.
/// Repeating those corrections in the painted position makes scrolling text
/// visibly jump backwards even when playback itself is moving forwards.
///
/// This clock is only for presentation. Native positions still own seeking and
/// progress. It has no timer: the overlay supplies its existing paint times.
class DanmakuPresentationClock {
  static const _discontinuitySeconds = .75;
  static const _correctionFraction = .1;
  static const _seekSettlement = Duration(milliseconds: 500);

  Object? _contextKey;
  Duration? _elapsed;
  double _position = 0;
  double _rate = 1;
  bool _playing = false;
  int? _timelineRevision;
  Duration? _nativePosition;
  Duration? _seekSettlesUntil;

  /// Discard the extrapolation when a hidden overlay becomes visible again.
  void reset() {
    _elapsed = null;
    _contextKey = null;
    _timelineRevision = null;
    _nativePosition = null;
    _seekSettlesUntil = null;
  }

  /// [elapsed] is a monotonic time shared by successive paints, including
  /// paints after an idle gap. [contextKey] changes on a seek, episode change,
  /// or a timing configuration change so those changes take effect immediately.
  /// A changed [timelineRevision] briefly accepts [nativePosition] updates
  /// directly: native seek reports can arrive after the command notification.
  double sample({
    required double position,
    required Duration elapsed,
    required bool playing,
    required double rate,
    required Object contextKey,
    int timelineRevision = 0,
    Duration? nativePosition,
  }) {
    if (!position.isFinite) return _position;
    final previousElapsed = _elapsed;
    final nextRate = rate.isFinite && rate > 0 ? rate : 0.0;
    final running = playing && nextRate > 0;
    final seeking =
        _timelineRevision != null && timelineRevision != _timelineRevision;
    if (seeking) {
      _seekSettlesUntil = elapsed + _seekSettlement;
    } else if (contextKey != _contextKey ||
        (_seekSettlesUntil != null && elapsed > _seekSettlesUntil!)) {
      _seekSettlesUntil = null;
    }
    final settling =
        _seekSettlesUntil != null &&
        nativePosition != null &&
        nativePosition != _nativePosition;
    if (previousElapsed == null ||
        contextKey != _contextKey ||
        elapsed < previousElapsed ||
        settling) {
      _position = position;
    } else {
      final delta =
          (elapsed - previousElapsed).inMicroseconds /
          Duration.microsecondsPerSecond;
      // Finish the preceding interval at its preceding rate. Pausing freezes
      // the displayed position; a stale native anchor cannot pull it backwards.
      final predicted = _position + (_playing ? delta * _rate : 0);
      final error = position - predicted;
      if (error.abs() > _discontinuitySeconds) {
        // Real timeline jumps, including delayed native seek reports, must not
        // take seconds of animation to catch up with the video.
        _position = position;
      } else if (_playing && running) {
        // Bound the correction by elapsed time, rather than frame count. Text
        // remains monotonic and has the same behaviour at 60 Hz and 120 Hz.
        final correction = delta * _rate * _correctionFraction;
        _position = predicted + error.clamp(-correction, correction);
      } else {
        _position = predicted;
      }
    }
    _contextKey = contextKey;
    _elapsed = elapsed;
    _rate = nextRate;
    _playing = running;
    _timelineRevision = timelineRevision;
    _nativePosition = nativePosition;
    return _position;
  }
}
