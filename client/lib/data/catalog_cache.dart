import '../core/network.dart';
import 'store.dart';

class _Lookup {
  final cancel = CancelToken();
  final callers = <Object>{};
  late final Future<Object?> result;
}

/// Successful public catalogue data survives restarts. Concurrent readers share
/// transport work, but cancelling one reader never cancels another reader.
class CatalogCache {
  final AppStore? store;
  final _memory = <String, Object?>{};
  final _pending = <String, _Lookup>{};
  CatalogCache(this.store);

  Future<T> load<T>(
    String key, {
    required Future<T> Function(CancelToken) fetch,
    required T Function(Object?) decode,
    required bool Function(T) keep,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final saved = store?.local(key) ?? _memory[key];
    if (saved != null) {
      try {
        final value = decode(saved);
        if (keep(value)) return value;
      } catch (_) {
        // Malformed or obsolete local entries are not successful lookups.
      }
    }
    var request = _pending[key];
    if (request == null) {
      final next = request = _Lookup();
      _pending[key] = next;
      next.result = Future<T>.sync(() => fetch(next.cancel))
          .then((value) {
            next.cancel.check();
            if (keep(value)) {
              if (store != null) {
                store!.setLocal(key, value);
              } else {
                _memory[key] = value;
              }
            }
            return value;
          })
          .whenComplete(() {
            if (identical(_pending[key], next)) _pending.remove(key);
          });
    }
    final active = request;
    final caller = Object();
    active.callers.add(caller);
    var waiting = true;
    void leave() {
      if (!waiting) return;
      waiting = false;
      active.callers.remove(caller);
      if (active.callers.isEmpty) {
        active.cancel.cancel();
        if (identical(_pending[key], active)) _pending.remove(key);
      }
    }

    try {
      final value = await Future.any<Object?>([
        active.result,
        if (cancel != null)
          cancel.whenCancelled.then<Object?>((_) {
            leave();
            throw const Cancelled();
          }),
      ]);
      cancel?.check();
      return decode(value);
    } finally {
      leave();
    }
  }

  void invalidate() {
    for (final request in _pending.values) {
      request.cancel.cancel();
    }
    _pending.clear();
    _memory.clear();
  }
}
