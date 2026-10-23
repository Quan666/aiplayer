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

/// Desktop window managers can briefly withdraw/occlude a window while
/// changing fullscreen geometry. Confirm hidden before pausing; never resume
/// playback automatically, which would override a user's explicit pause.
class PlaybackBackgroundGuard {
  final void Function() onBackground;
  final bool deferHidden;
  Timer? _confirmation;
  bool _disposed = false;

  PlaybackBackgroundGuard({
    required this.onBackground,
    required this.deferHidden,
  });

  void update(AppLifecycleState state) {
    if (_disposed) return;
    _confirmation?.cancel();
    if (!playbackIsBackgrounded(state)) return;
    if (deferHidden && state == AppLifecycleState.hidden) {
      _confirmation = Timer(const Duration(milliseconds: 250), onBackground);
    } else {
      onBackground();
    }
  }

  void dispose() {
    _disposed = true;
    _confirmation?.cancel();
  }
}

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
