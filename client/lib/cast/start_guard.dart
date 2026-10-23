import 'dart:async';
import '../core/network.dart';

/// Cancels waiting for a slow connection without abandoning resources that
/// arrive later. Stop commands run after [settle], so a late start cannot play
/// over a completed stop operation.
class CastStartGuard {
  final _cancelled = Completer<void>();
  Future<void>? _running;
  bool get cancelled => _cancelled.isCompleted;

  Future<void> run(Future<void> Function() action) {
    if (cancelled) return Future.error(const Cancelled());
    return _running ??= Future.sync(action).whenComplete(() => _running = null);
  }

  Future<T> acquire<T>(Future<T> pending, FutureOr<void> Function(T) release) =>
      Future.any([
        pending.then((value) async {
          if (cancelled) {
            await release(value);
            throw const Cancelled();
          }
          return value;
        }),
        _cancelled.future.then<T>((_) => throw const Cancelled()),
      ]);

  void cancel() {
    if (!cancelled) _cancelled.complete();
  }

  Future<void> settle() async {
    try {
      await _running;
    } catch (_) {
      /* Start reports its own error. */
    }
  }
}
