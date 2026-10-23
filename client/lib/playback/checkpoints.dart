import 'dart:async';

/// Progress is cheap enough to checkpoint while playing. Artwork is only
/// requested by a pause/background/exit event, after its UI updates settle.
class PlaybackCheckpoints {
  static const interval = Duration(seconds: 10);
  static const eventDelay = Duration(milliseconds: 250);
  final bool Function() isPlaying;
  final void Function() saveProgress;
  final Future<void> Function() capturePreview;
  final void Function(Object) onError;
  Timer? _periodic, _event;
  Future<void>? _capture, _closing;
  bool _pendingPreview = false, _stopped = false;

  PlaybackCheckpoints({
    required this.isPlaying,
    required this.saveProgress,
    required this.capturePreview,
    required this.onError,
  });

  void start() {
    if (_stopped || _periodic != null) return;
    _periodic = Timer.periodic(interval, (_) {
      if (isPlaying()) _save();
    });
  }

  void checkpoint({bool capturePreview = true}) {
    if (_stopped) return;
    _pendingPreview |= capturePreview;
    _event ??= Timer(eventDelay, _flush);
  }

  void _save() {
    try {
      saveProgress();
    } catch (error) {
      onError(error);
    }
  }

  void _flush() {
    _event = null;
    if (_stopped) return;
    _save();
    if (!_pendingPreview || _capture != null) return;
    _pendingPreview = false;
    _capture = Future<void>.sync(capturePreview)
        .catchError((Object error) => onError(error))
        .whenComplete(() {
          _capture = null;
          // A newer event supersedes the captured position. There is never
          // more than one native screenshot command in flight.
          if (_pendingPreview && !_stopped) {
            _event ??= Timer(eventDelay, _flush);
          }
        });
  }

  /// Stop timers immediately, before native shutdown waits begin.
  void stop() {
    _stopped = true;
    _periodic?.cancel();
    _event?.cancel();
    _pendingPreview = false;
  }

  /// Finish taking the last native frame before the player is disposed. The
  /// capture callback queues compression/storage separately from this barrier.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    stop();
    _save();
    await _capture;
    try {
      await capturePreview();
    } catch (error) {
      onError(error);
    }
    // A pending seek may have finished while the native screenshot completed.
    _save();
  }
}
