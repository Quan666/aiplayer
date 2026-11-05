import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../sources/source.dart';
import 'album_catalog.dart';

class AlbumCatalogCancelled implements Exception {
  const AlbumCatalogCancelled();
  @override
  String toString() => 'Album catalog request cancelled';
}

class AlbumCatalogFailure implements Exception {
  final String message;
  const AlbumCatalogFailure(this.message);
  @override
  String toString() => message;
}

/// One persistent isolate per browser. At most one build is running and one
/// newer build is waiting; superseded results are never published. The worker
/// retains its directory index, so filtering transfers only small options.
///
/// [build] accepts a stable listing snapshot. Replace [entries] or advance
/// [dataRevision] when files/metadata change; do not mutate a submitted list.
/// All index construction, sorting, aggregation and preferences IO stay here.
class AlbumCatalogWorker {
  final _queue = <_Request>[];
  Isolate? _isolate;
  ReceivePort? _port;
  StreamIterator<dynamic>? _responses;
  SendPort? _requests;
  _Request? _active;
  Object? _dataKey;
  bool _running = false, _closed = false, _closing = false;
  Completer<void>? _flush;
  Object? _flushError;
  StackTrace? _flushStack;
  int _indexTransfers = 0;

  int get indexTransfers => _indexTransfers;
  int get pendingCount => _queue.length;
  bool get isWorking => _active != null;

  /// Opt into a stable browsing timeline with [orderingRevision]. Metadata
  /// updates still refresh facts and filters, while ordering and date dividers
  /// retain their admitted timestamps. Advance it for an explicit sort/filter
  /// action or refresh; a changed listing also invalidates the saved timeline.
  /// Omitting it preserves the ordinary latest-metadata sorting behavior.
  Future<AlbumSnapshot> build(
    List<SourceEntry> entries, {
    required String sourceId,
    required String directory,
    AlbumOptions? options,
    Map<String, AlbumFileMetadata> metadata = const {},
    Object? dataRevision,
    int? orderingRevision,
    bool caseSensitive = true,
  }) {
    if (_closed || _closing) return Future.error(const AlbumCatalogCancelled());
    cancelBuilds();
    final request = _BuildRequest(
      entries,
      sourceId,
      directory,
      options ?? AlbumOptions(),
      metadata,
      dataRevision,
      orderingRevision,
      caseSensitive,
    );
    _enqueue(request);
    return request.result.future;
  }

  /// Cancels active/pending builds immediately, leaving a bounded already
  /// running CPU operation to finish without launching more work. No timer or
  /// frame is needed for lifecycle suspension.
  void cancelBuilds() {
    final active = _active;
    if (active is _BuildRequest) active.cancel();
    _queue.removeWhere((request) {
      if (request is! _BuildRequest) return false;
      request.cancel();
      return true;
    });
  }

  Future<Map<String, dynamic>> readPreferences(String filePath) {
    if (_closed || _closing) return Future.error(const AlbumCatalogCancelled());
    final request = _ReadPreferences(filePath);
    _enqueue(request);
    return request.result.future;
  }

  /// Store one file per source/directory to avoid independent route workers
  /// replacing a shared map from stale snapshots. Writes replace atomically.
  /// Superseded pending saves are cancelled; a completed future means this
  /// request's write reached disk.
  Future<void> savePreferences(String filePath, Map<String, dynamic> value) {
    if (_closed || _closing) return Future.error(const AlbumCatalogCancelled());
    _queue.removeWhere((request) {
      if (request is! _SavePreferences || request.path != filePath) {
        return false;
      }
      request.cancel();
      return true;
    });
    final request = _SavePreferences(filePath, value);
    _enqueue(request);
    return request.result.future;
  }

  void _enqueue(_Request request) {
    // Preference requests cannot turn rapid edits into an unbounded queue.
    if (_queue.length >= 8) _queue.removeAt(0).cancel();
    _queue.add(request);
    unawaited(_drain());
  }

  Future<void> _start() async {
    final port = _port = ReceivePort();
    final responses = _responses = StreamIterator<dynamic>(port);
    final isolate = await Isolate.spawn(
      _albumWorkerMain,
      port.sendPort,
      debugName: 'album-catalog',
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    );
    if (_closed) {
      isolate.kill(priority: Isolate.immediate);
      throw const AlbumCatalogCancelled();
    }
    _isolate = isolate;
    if (!await responses.moveNext() || responses.current is! SendPort) {
      throw const AlbumCatalogFailure('相册后台任务启动失败');
    }
    _requests = responses.current as SendPort;
  }

  Future<void> _drain() async {
    if (_running || _closed) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final request = _active = _queue.removeAt(0);
        try {
          if (_requests == null) await _start();
          if (_closed || request.completed) continue;
          if (request is _BuildRequest) {
            final key = (
              request.entries,
              request.sourceId,
              request.directory,
              request.metadata,
              request.revision,
              request.caseSensitive,
            );
            final reuse = _dataKey == key;
            if (!reuse) _indexTransfers++;
            _requests!.send(
              _BuildMessage(
                reuse ? null : request.entries,
                request.sourceId,
                request.directory,
                request.options,
                reuse ? null : request.metadata,
                request.orderingRevision,
                request.caseSensitive,
              ),
            );
            _dataKey = key;
          } else if (request is _ReadPreferences) {
            _requests!.send(('read', request.path));
          } else if (request is _SavePreferences) {
            _requests!.send(('save', request.path, request.value));
          }
          final responses = _responses!;
          if (!await responses.moveNext() || responses.current is! _Reply) {
            throw const AlbumCatalogFailure('相册后台任务已退出');
          }
          final reply = responses.current as _Reply;
          if (reply.error != null) {
            _dataKey = null;
            throw AlbumCatalogFailure(reply.error!);
          }
          if (!request.completed) request.complete(reply.value);
        } catch (error, stack) {
          if (!request.completed) request.fail(error, stack);
          if (_closing && request is _SavePreferences) {
            _flushError = error;
            _flushStack = stack;
          }
          if (error is! AlbumCatalogCancelled) _resetWorker();
        } finally {
          _active = null;
        }
      }
    } finally {
      _running = false;
      if (_closing && !_closed) close();
    }
  }

  void _resetWorker() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _requests = null;
    _dataKey = null;
    unawaited(_responses?.cancel());
    _responses = null;
    _port?.close();
    _port = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _active?.cancel();
    for (final request in _queue) {
      request.cancel();
    }
    _queue.clear();
    _resetWorker();
    final flush = _flush;
    if (flush != null && !flush.isCompleted) {
      if (_flushError != null) {
        flush.completeError(_flushError!, _flushStack);
      } else {
        flush.complete();
      }
    }
  }

  /// Finish already accepted settings writes before releasing the worker.
  /// New work is rejected; catalog/reads are cancelled immediately. The local
  /// JSON files are small and writes atomic; the deadline bounds a failed or
  /// stalled filesystem without exposing a partially replaced preferences file.
  Future<void> flushPreferencesAndClose({
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (_closed) return Future.value();
    if (_flush != null) return _flush!.future;
    _closing = true;
    final flush = _flush = Completer<void>();
    final active = _active;
    if (active is! _SavePreferences) active?.cancel();
    _queue.removeWhere((request) {
      if (request is _SavePreferences) return false;
      request.cancel();
      return true;
    });
    if (!_running) {
      if (_queue.isEmpty) {
        close();
      } else {
        unawaited(_drain());
      }
    }
    return flush.future.timeout(
      timeout,
      onTimeout: () {
        close();
        throw TimeoutException('相册设置保存超时', timeout);
      },
    );
  }

  void dispose() => close();
}

abstract class _Request<T> {
  final result = Completer<T>();
  bool get completed => result.isCompleted;
  void complete(dynamic value) => result.complete(value as T);
  void fail(Object error, StackTrace stack) =>
      result.completeError(error, stack);
  void cancel() {
    if (!completed) result.completeError(const AlbumCatalogCancelled());
  }
}

class _BuildRequest extends _Request<AlbumSnapshot> {
  final List<SourceEntry> entries;
  final String sourceId, directory;
  final AlbumOptions options;
  final Map<String, AlbumFileMetadata> metadata;
  final Object? revision;
  final int? orderingRevision;
  final bool caseSensitive;
  _BuildRequest(
    this.entries,
    this.sourceId,
    this.directory,
    this.options,
    this.metadata,
    this.revision,
    this.orderingRevision,
    this.caseSensitive,
  );
}

class _ReadPreferences extends _Request<Map<String, dynamic>> {
  final String path;
  _ReadPreferences(this.path);
}

class _SavePreferences extends _Request<void> {
  final String path;
  final Map<String, dynamic> value;
  _SavePreferences(this.path, this.value);
}

class _BuildMessage {
  final List<SourceEntry>? entries;
  final String sourceId, directory;
  final AlbumOptions options;
  final Map<String, AlbumFileMetadata>? metadata;
  final int? orderingRevision;
  final bool caseSensitive;
  _BuildMessage(
    this.entries,
    this.sourceId,
    this.directory,
    this.options,
    this.metadata,
    this.orderingRevision,
    this.caseSensitive,
  );
}

class _Reply {
  final Object? value;
  final String? error;
  const _Reply(this.value, [this.error]);
}

void _albumWorkerMain(SendPort responses) {
  final requests = ReceivePort();
  AlbumIndex? index;
  List<SourceEntry>? entries;
  final timelines = <(String, String, bool), _TimelineSession>{};
  var writeSequence = 0;
  responses.send(requests.sendPort);
  requests.listen((dynamic message) {
    try {
      if (message is _BuildMessage) {
        if (message.entries != null) {
          entries = message.entries!;
          index = AlbumIndex(
            message.entries!,
            sourceId: message.sourceId,
            directory: message.directory,
            metadata: message.metadata ?? const {},
            caseSensitive: message.caseSensitive,
          );
        }
        if (index == null) throw StateError('Missing directory index');
        final orderingRevision = message.orderingRevision;
        if (orderingRevision == null) {
          responses.send(_Reply(index!.filter(message.options)));
          return;
        }
        final key = (
          message.sourceId,
          message.directory,
          message.caseSensitive,
        );
        final previous = timelines.remove(key);
        final retain =
            previous != null &&
            previous.revision == orderingRevision &&
            _sameListing(previous.entries, entries!);
        final result = index!.filter(
          message.options,
          timelineById: retain ? previous.timeline : const {},
        );
        timelines[key] = _TimelineSession(
          orderingRevision,
          entries!,
          result.timelineById,
        );
        // Keep directory returns stable without retaining eight enormous
        // listings. This cache belongs solely to this worker and its lifetime.
        while (timelines.length > 8 ||
            timelines.length > 1 &&
                timelines.values.fold<int>(
                      0,
                      (total, session) => total + session.entries.length,
                    ) >
                    200000) {
          timelines.remove(timelines.keys.first);
        }
        responses.send(_Reply(result));
      } else if (message is (String, String) && message.$1 == 'read') {
        final file = File(message.$2);
        if (!file.existsSync()) {
          responses.send(const _Reply(<String, dynamic>{}));
        } else {
          if (file.lengthSync() > 1024 * 1024) {
            throw const FormatException('Preferences exceed size limit');
          }
          final value = jsonDecode(file.readAsStringSync());
          responses.send(
            _Reply(value is Map<String, dynamic> ? value : <String, dynamic>{}),
          );
        }
      } else if (message is (String, String, Map<String, dynamic>) &&
          message.$1 == 'save') {
        final encoded = jsonEncode(message.$3);
        if (utf8.encode(encoded).length > 1024 * 1024) {
          throw const FormatException('Preferences exceed size limit');
        }
        final file = File(message.$2);
        file.parent.createSync(recursive: true);
        final temporary = File('${file.path}.pending-$pid-${writeSequence++}');
        try {
          temporary.writeAsStringSync(encoded, flush: true);
          temporary.renameSync(file.path);
        } finally {
          if (temporary.existsSync()) temporary.deleteSync();
        }
        responses.send(const _Reply(null));
      } else {
        throw StateError('Unknown album worker request');
      }
    } catch (_) {
      // Do not leak filesystem paths or source names through raw exceptions.
      responses.send(const _Reply(null, '相册数据处理失败，请重试'));
    }
  });
}

class _TimelineSession {
  final int revision;
  final List<SourceEntry> entries;
  final Map<String, int?> timeline;
  const _TimelineSession(this.revision, this.entries, this.timeline);
}

bool _sameListing(List<SourceEntry> a, List<SourceEntry> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    final left = a[index], right = b[index];
    if (left.path != right.path ||
        left.name != right.name ||
        left.size != right.size ||
        left.modified != right.modified ||
        left.directory != right.directory ||
        left.hidden != right.hidden) {
      return false;
    }
  }
  return true;
}
