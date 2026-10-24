import 'dart:async';
import 'dart:ui' show AppLifecycleState;

/// Losing focus also happens while changing fullscreen or device orientation.
/// Only leaving the visible app should apply the pause-on-background setting.
bool playbackIsBackgrounded(AppLifecycleState? state) => switch (state) {
  AppLifecycleState.hidden ||
  AppLifecycleState.paused ||
  AppLifecycleState.detached => true,
  AppLifecycleState.resumed || AppLifecycleState.inactive || null => false,
};

/// Desktop occlusion/minimization must not interrupt playback. Mobile keeps
/// explicit background playback and PiP exemptions, independently of focus.
bool playbackShouldPauseInBackground({
  required bool mobile,
  required bool backgrounded,
  required bool pauseOnBackground,
  required bool pictureInPicture,
}) => mobile && backgrounded && pauseOnBackground && !pictureInPicture;

/// Orders native fullscreen and orientation changes without touching playback.
/// In particular, a transition must never restore an old playing state after
/// the user pauses or the app actually enters the background.
class FullscreenTransition {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  bool get isTransitioning => _pending > 0;

  /// Completes when all operations queued so far finish, including failed ones.
  Future<void> get idle => _tail;

  /// Callers receive their own operation's error; later operations still run.
  /// An operation must not await another [run] on this same queue.
  Future<void> run(Future<void> Function() operation) {
    _pending++;
    final result = _tail.then((_) async {
      try {
        await operation();
      } finally {
        _pending--;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
