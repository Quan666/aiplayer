import 'dart:async';

import 'package:flutter/foundation.dart';

/// Keeps the scrubbed position visible until the decoder reaches it. A seek
/// command completing only means that it was accepted, not that a new frame
/// or position has arrived from the native player.
class PlaybackSeekTimeline extends ChangeNotifier {
  final ValueListenable<Duration> position;
  final Future<void> Function(Duration) seek;
  Duration? target;
  Duration origin = Duration.zero;
  bool dragging = false;
  Timer? _expiry;
  int _generation = 0;
  bool _disposed = false;

  PlaybackSeekTimeline({required this.position, required this.seek}) {
    position.addListener(_positionChanged);
  }

  Duration get displayed => target ?? position.value;

  void begin(Duration value) {
    _generation++;
    _expiry?.cancel();
    origin = position.value;
    dragging = true;
    target = value;
    notifyListeners();
  }

  void update(Duration value) {
    if (!dragging || target == value) return;
    target = value;
    notifyListeners();
  }

  void finish({bool commit = true}) {
    // Raw pointer-up and the Slider's end callback can both arrive. Only the
    // first one consumes a gesture, so neither double-seeks nor late cancels
    // can bring its preview back.
    if (!dragging) return;
    dragging = false;
    final destination = target;
    if (commit && destination != null) {
      final generation = ++_generation;
      // A disconnected source must not leave an optimistic position forever.
      _expiry = Timer(const Duration(seconds: 10), () {
        _clearPending(generation);
      });
      unawaited(_commit(destination, generation));
    } else {
      target = null;
    }
    notifyListeners();
  }

  Future<void> _commit(Duration destination, int generation) async {
    try {
      await seek(destination);
    } catch (_) {
      // PlaybackSession reports decoder errors. Restore the actual timeline
      // if this command itself failed, without discarding a newer gesture.
      _clearPending(generation);
    }
  }

  void _positionChanged() {
    final pending = target;
    if (!dragging &&
        pending != null &&
        (position.value - pending).inMilliseconds.abs() <= 500) {
      _clearPending(_generation);
    }
  }

  void _clearPending(int generation) {
    if (_disposed || generation != _generation || dragging || target == null) {
      return;
    }
    _expiry?.cancel();
    target = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _expiry?.cancel();
    position.removeListener(_positionChanged);
    super.dispose();
  }
}
