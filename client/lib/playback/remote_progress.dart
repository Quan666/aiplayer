import 'dart:async';
import 'dart:io';

import '../data/store.dart';

/// PiP and cast callbacks use the same background database path as inline
/// playback. Only the newest pending snapshot is retained while storage waits.
class RemotePlaybackProgress {
  final AppStore store;
  final String progressId, watchedId;
  final void Function() onSaved;
  final void Function(Object) onError;
  final bool enabled;
  Future<void>? _work;
  (double, double)? _pending, _writing;

  RemotePlaybackProgress({
    required this.store,
    required this.progressId,
    required this.watchedId,
    required this.onSaved,
    required this.onError,
    this.enabled = true,
  });

  Future<void> save({required double position, required double duration}) {
    if (!enabled || !position.isFinite || !duration.isFinite || duration <= 0) {
      return Future.value();
    }
    final snapshot = (position.clamp(0.0, duration), duration);
    if (_pending == snapshot || (_pending == null && _writing == snapshot)) {
      return _work ?? Future.value();
    }
    _pending = snapshot;
    if (_work != null) return _work!;
    final completion = Completer<void>();
    _work = completion.future;
    unawaited(
      _drain().then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  Future<void> _drain() async {
    try {
      while (_pending != null) {
        final snapshot = _pending!;
        _pending = null;
        _writing = snapshot;
        try {
          final changed = await store.savePlaybackProgress(progressId, {
            'position': snapshot.$1,
            'duration': snapshot.$2,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'devicePlatform': Platform.operatingSystem,
          }, watchedId: snapshot.$1 / snapshot.$2 >= .95 ? watchedId : null);
          if (changed) onSaved();
        } catch (error) {
          onError(error);
        } finally {
          _writing = null;
        }
      }
    } finally {
      _work = null;
    }
  }
}
