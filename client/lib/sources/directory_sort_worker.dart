import 'dart:async';
import 'dart:isolate';

import 'directory_sort.dart';
import 'source.dart';

class DirectorySortCancelled implements Exception {
  const DirectorySortCancelled();
}

/// One worker per browser, with one running request and a bounded pending queue.
/// Only directory entries and sort options cross the isolate boundary.
class DirectorySortWorker {
  final _queue = <_SortRequest>[];
  Isolate? _isolate;
  ReceivePort? _port;
  StreamIterator<dynamic>? _responses;
  SendPort? _requests;
  _SortRequest? _active;
  bool _running = false, _closed = false;

  Future<List<SourceEntry>> sort(
    List<SourceEntry> entries,
    DirectorySort order, {
    required bool hideHiddenFiles,
  }) {
    if (_closed) return Future.error(const DirectorySortCancelled());
    final request = _SortRequest(entries, order, hideHiddenFiles);
    // A browser normally has one listing and at most four preview requests.
    // Navigation cancellation prevents obsolete folders accumulating behind it.
    if (_queue.length == 8) {
      _queue.removeAt(0).result.completeError(const DirectorySortCancelled());
    }
    _queue.add(request);
    unawaited(_drain());
    return request.result.future;
  }

  void cancelPending() {
    for (final request in _queue) {
      request.result.completeError(const DirectorySortCancelled());
    }
    _queue.clear();
  }

  Future<void> _start() async {
    _port = ReceivePort();
    _responses = StreamIterator(_port!);
    final isolate = await Isolate.spawn(_sortDirectory, _port!.sendPort);
    if (_closed) {
      isolate.kill(priority: Isolate.immediate);
      throw const DirectorySortCancelled();
    }
    _isolate = isolate;
    if (!await _responses!.moveNext()) {
      throw const DirectorySortCancelled();
    }
    _requests = _responses!.current as SendPort;
  }

  Future<void> _drain() async {
    if (_running || _closed) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final request = _active = _queue.removeAt(0);
        try {
          if (_requests == null) await _start();
          if (_closed) break;
          _requests!.send((
            request.entries,
            request.order.field,
            request.order.descending,
            request.order.showSubtitles,
            request.hideHiddenFiles,
          ));
          if (!await _responses!.moveNext()) {
            throw const DirectorySortCancelled();
          }
          final response = _responses!.current as (List<SourceEntry>?, String?);
          if (request.result.isCompleted) continue;
          if (response.$2 != null) {
            request.result.completeError(StateError(response.$2!));
          } else {
            request.result.complete(response.$1!);
          }
        } catch (error, stack) {
          if (!request.result.isCompleted) {
            request.result.completeError(error, stack);
          }
        } finally {
          _active = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    cancelPending();
    final active = _active;
    if (active != null && !active.result.isCompleted) {
      active.result.completeError(const DirectorySortCancelled());
    }
    _isolate?.kill(priority: Isolate.immediate);
    unawaited(_responses?.cancel());
    _port?.close();
  }
}

class _SortRequest {
  final List<SourceEntry> entries;
  final DirectorySort order;
  final bool hideHiddenFiles;
  final result = Completer<List<SourceEntry>>();

  _SortRequest(this.entries, this.order, this.hideHiddenFiles);
}

void _sortDirectory(SendPort replies) {
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  requests.listen((message) {
    final (entries, field, descending, showSubtitles, hideHidden) =
        message as (List<SourceEntry>, String, bool, bool, bool);
    try {
      final sorted = DirectorySort(
        field: field,
        descending: descending,
        showSubtitles: showSubtitles,
      ).apply(entries, hideHiddenFiles: hideHidden);
      replies.send((sorted, null));
    } catch (error) {
      replies.send((null, error.toString()));
    }
  });
}
