import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import '../core/network.dart';
import 'store.dart';
import 'local_video_removal.dart';

/// Serializes local state on one connection outside the UI isolate.
class LocalStateWorker {
  final _messages = ReceivePort();
  final _pending = <int, Completer<dynamic>>{};
  final _outbox = <List<Object?>>[];
  final _closed = Completer<void>();
  SendPort? _commands;
  int _serial = 0;
  bool _closing = false, _stopped = false;

  LocalStateWorker(String databasePath) {
    _messages.listen((dynamic message) {
      // Exit notifications use the result port too, preserving the worker's
      // result/close order instead of racing an independent exit listener.
      if (message == null) {
        _stop(const Cancelled());
        return;
      }
      if (message is SendPort) {
        _commands = message;
        for (final command in _outbox) {
          message.send(command);
        }
        _outbox.clear();
        return;
      }
      final row = message as List;
      if (row.length == 2 && row[0] is String && row[1] is String) {
        _stop(AppFailure(row[0] as String));
        return;
      }
      if (row[0] == 'closed') {
        _stop(const Cancelled());
        return;
      }
      final result = _pending.remove(row[1] as int);
      if (row[0] == 'result') {
        result?.complete(row.length > 2 ? row[2] : null);
      } else {
        result?.completeError(
          row[2] == 'cancelled'
              ? const Cancelled()
              : AppFailure(row[3] as String),
        );
      }
    });
    unawaited(
      Isolate.spawn(
        _localStateWorkerMain,
        [databasePath, _messages.sendPort],
        onError: _messages.sendPort,
        onExit: _messages.sendPort,
      ).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _stop(AppFailure('$error'));
        },
      ),
    );
  }

  void _stop(Object error) {
    if (_stopped) return;
    _stopped = _closing = true;
    for (final result in _pending.values) {
      result.completeError(error);
    }
    _pending.clear();
    _outbox.clear();
    _messages.close();
    _closed.complete();
  }

  void _send(List<Object?> command) {
    if (_stopped) return;
    final commands = _commands;
    if (commands == null) {
      _outbox.add(command);
    } else {
      commands.send(command);
    }
  }

  Future<dynamic> _call(
    String operation,
    List<Object?> values,
    CancelToken? cancel,
  ) {
    if (_closing || cancel?.cancelled == true) {
      return Future.error(const Cancelled());
    }
    if (_pending.length >= 128) {
      return Future.error(const AppFailure('后台状态任务繁忙，请稍后重试。'));
    }
    final id = ++_serial;
    final result = Completer<dynamic>();
    _pending[id] = result;
    _send([operation, id, ...values]);
    final cancellation = cancel?.whenCancelled.asStream().listen((_) {
      if (_pending.containsKey(id)) _send(['cancel', id]);
    });
    return result.future.whenComplete(() => cancellation?.cancel());
  }

  Future<void> saveMetadataTasks(List<Map<String, dynamic>> snapshot) async {
    await _call('metadata', [snapshot], null);
  }

  Future<void> registerBrowse(
    String id,
    String source,
    String path,
    int size, {
    CancelToken? cancel,
  }) async {
    await _call('browse', [id, source, path, size], cancel);
  }

  Future<bool> deleteLocalVideo(
    String documentsPath,
    String id,
    Map<String, dynamic> expected, {
    CancelToken? cancel,
  }) async =>
      await _call('deleteLocalVideo', [documentsPath, id, expected], cancel) ==
      true;

  /// Drain accepted checkpoints; optional browse work is cancelled on close.
  Future<void> close() {
    if (!_closing) {
      _closing = true;
      _send(['close']);
    }
    return _closed.future;
  }
}

void _localStateWorkerMain(List<Object?> startup) async {
  final store = await retryStoreBusy(
    () => AppStore.openExisting(startup[0] as String),
  );
  // Retry outside SQLite so cancellation and close messages can run while a
  // different connection owns the writer lock.
  store.db.execute('PRAGMA busy_timeout=0');
  final reply = startup[1] as SendPort;
  final commands = ReceivePort();
  final queue = Queue<List>();
  final cancellable = <int, CancelToken>{};
  var running = false, closing = false;

  void finishClose() {
    if (!closing || running || queue.isNotEmpty) return;
    store.dispose();
    commands.close();
    Isolate.exit(reply, ['closed']);
  }

  Future<void> drain() async {
    if (running) return;
    running = true;
    while (queue.isNotEmpty) {
      final row = queue.removeFirst();
      final id = row[1] as int;
      final cancel = cancellable[id];
      try {
        dynamic result;
        await retryStoreBusy(() {
          cancel?.check();
          if (row[0] == 'deleteLocalVideo') {
            result = removeLocalVideo(
              store,
              row[2] as String,
              row[3] as String,
              row[4] as Map<String, dynamic>,
            );
            return;
          }
          store.transaction(() {
            cancel?.check();
            if (row[0] == 'metadata') {
              store.setLocal('metadata:pending-tasks', row[2]);
            } else {
              final mediaId = row[2] as String;
              final source = row[3] as String;
              final path = row[4] as String;
              final size = row[5] as int;
              final location = store.locationFor(source, path);
              if (location != null &&
                  store.get('media', location['id'])?.deleted == false) {
                return;
              }
              store.setLocal('browse:$mediaId', {
                'source': source,
                'path': path,
                'size': size,
              });
              final index = List<String>.from(
                store.local('browse:index') ?? <String>[],
              );
              if (!index.contains(mediaId)) {
                index.add(mediaId);
                store.setLocal('browse:index', index);
              }
            }
          });
        });
        reply.send(['result', id, result]);
      } catch (error) {
        reply.send([
          'failure',
          id,
          error is Cancelled ? 'cancelled' : 'error',
          '$error',
        ]);
      } finally {
        cancellable.remove(id);
      }
    }
    running = false;
    finishClose();
  }

  commands.listen((dynamic message) {
    final row = message as List;
    if (row[0] == 'close') {
      closing = true;
      for (final cancel in cancellable.values) {
        cancel.cancel();
      }
      finishClose();
    } else if (row[0] == 'cancel') {
      cancellable[row[1]]?.cancel();
    } else {
      if (row[0] == 'browse' || row[0] == 'deleteLocalVideo') {
        cancellable[row[1] as int] = CancelToken();
      }
      queue.add(row);
      unawaited(drain());
    }
  });
  reply.send(commands.sendPort);
}
