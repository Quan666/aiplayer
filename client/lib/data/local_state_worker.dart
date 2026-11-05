import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../core/network.dart';
import '../sources/source.dart';
import 'store.dart';
import 'local_video_removal.dart';
import 'media_technical_info.dart';
import 'media_preview_persistence.dart';
import 'source_preview.dart';

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

  Future<void> patchSettings(
    Map<String, dynamic> patch, {
    List<String> remove = const [],
  }) async {
    await _call('settings', [patch, remove], null);
  }

  Future<List<SyncRecord>> unmatchedMetadataCandidates() async =>
      (await _call('metadataCandidates', const [], null) as List)
          .cast<SyncRecord>();

  Future<SyncRecord> preparePersonalMediaForPlayback(
    String sourceId,
    SourceEntry entry, {
    CancelToken? cancel,
  }) async =>
      await _call('personalMedia', [sourceId, entry], cancel) as SyncRecord;

  Future<String> registerBrowse(
    String id,
    String source,
    String path,
    int size, {
    CancelToken? cancel,
    String previewRevision = '',
  }) async =>
      await _call('browse', [id, source, path, size, previewRevision], cancel)
          as String;

  Future<SourcePreviewBinding> sourcePreviewBinding(
    String source,
    SourceEntry entry,
    int formatVersion, {
    required CancelToken cancel,
    bool albumCover = false,
    bool originalResolution = false,
  }) async => await _call('sourcePreviewBinding', [
    source,
    entry,
    formatVersion,
    albumCover,
    originalResolution,
  ], cancel) as SourcePreviewBinding;

  Future<void> invalidateBrowsePreviews(String source) async =>
      _call('invalidateBrowsePreviews', [source], null);

  Future<bool> discardMissingMediaPreview(
    String id,
    String path,
    Map<String, dynamic> expected, {
    required CancelToken cancel,
  }) async =>
      await _call('discardMissingMediaPreview', [id, path, expected], cancel) ==
      true;

  Future<bool> deleteLocalVideo(
    String documentsPath,
    String id,
    Map<String, dynamic> expected, {
    CancelToken? cancel,
  }) async =>
      await _call('deleteLocalVideo', [documentsPath, id, expected], cancel) ==
      true;

  Future<PersistedMediaPreview?> persistMediaPreview(
    Map<String, dynamic> input, {
    required CancelToken cancel,
  }) async => await _call('preview', [input], cancel) as PersistedMediaPreview?;

  Future<Map<String, String>> readMediaTechnicalLabels(
    List<String> ids, {
    CancelToken? cancel,
  }) async => Map<String, String>.unmodifiable(
    Map<String, String>.from(
      await _call('mediaTechnicalLabels', [ids], cancel),
    ),
  );

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
        if (row[0] == 'sourcePreviewBinding') {
          cancel!.check();
          result = await readSourcePreviewBinding(
            store,
            row[2] as String,
            row[3] as SourceEntry,
            row[4] as int,
            albumCover: row[5] as bool,
            originalResolution: row[6] as bool,
          );
          cancel.check();
        } else if (row[0] == 'discardMissingMediaPreview') {
          result = await retryStoreBusy(() async {
            cancel!.check();
            if (await File(row[3] as String).exists()) return false;
            cancel.check();
            var removed = false;
            store.transaction(
              () => removed = discardPreparedMediaPreview(
                store,
                row[2] as String,
                Map<String, dynamic>.from(row[4] as Map),
              ),
            );
            return removed;
          });
        } else if (row[0] == 'metadataCandidates') {
          result = unmatchedMetadataCandidates(store);
        } else if (row[0] == 'mediaTechnicalLabels') {
          result = await _readMediaTechnicalLabels(
            store,
            (row[2] as List).cast<String>(),
            cancel!,
          );
        } else {
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
              } else if (row[0] == 'preview') {
                result = persistCapturedMediaPreview(
                  store,
                  Map<String, dynamic>.from(row[2]),
                );
              } else if (row[0] == 'invalidateBrowsePreviews') {
                invalidateSourceBrowsePreviews(store, row[2] as String);
              } else if (row[0] == 'personalMedia') {
                result = registerPersonalMediaForPlayback(
                  store,
                  row[2] as String,
                  row[3] as SourceEntry,
                );
              } else if (row[0] == 'settings') {
                final settings = Map<String, dynamic>.from(
                  store.local('settings') ?? {},
                );
                for (final key in (row[3] as List).cast<String>()) {
                  settings.remove(key);
                }
                settings.addAll(Map<String, dynamic>.from(row[2]));
                store.setLocal('settings', settings);
                // Legacy automatic queues must never restart on a later opt-in.
                store.removeLocal('metadata:automatic-pending');
              } else {
                final mediaId = row[2] as String;
                final source = row[3] as String;
                final path = row[4] as String;
                final size = row[5] as int;
                final location = mediaId.startsWith('browse-album-')
                    ? null
                    : store.locationFor(source, path);
                if (location != null &&
                    store.get('media', location['id'])?.deleted == false) {
                  result = location['id'] as String;
                  return;
                }
                result = mediaId;
                final fileRevision = row[6] as String;
                final previewRevision = browsePreviewRevision(
                  store,
                  source,
                  fileRevision,
                );
                store.setLocal('browse:$mediaId', {
                  'source': source,
                  'path': path,
                  'size': size,
                  if (previewRevision.isNotEmpty)
                    'previewRevision': previewRevision,
                  if (previewRevision != fileRevision)
                    'fileRevision': fileRevision,
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
        }
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
      if (row[0] == 'browse' ||
          row[0] == 'sourcePreviewBinding' ||
          row[0] == 'discardMissingMediaPreview' ||
          row[0] == 'preview' ||
          row[0] == 'personalMedia' ||
          row[0] == 'deleteLocalVideo' ||
          row[0] == 'mediaTechnicalLabels') {
        cancellable[row[1] as int] = CancelToken();
      }
      queue.add(row);
      unawaited(drain());
    }
  });
  reply.send(commands.sendPort);
}

List<SyncRecord> unmatchedMetadataCandidates(AppStore store) {
  final manual = store.localEntries('manualMetadata:');
  return store
      .records('media')
      .where(
        (record) =>
            !record.deleted &&
            record.data['personalMedia'] != true &&
            record.data['bangumiId'] == null &&
            record.data['tmdbId'] == null &&
            manual['manualMetadata:${record.id}'] != true,
      )
      .toList();
}

/// Called with a transaction on the bounded local-state worker. Keeps personal
/// media out of automatic film metadata, library presentation and cloud uploads.
SyncRecord registerPersonalMediaForPlayback(
  AppStore store,
  String sourceId,
  SourceEntry entry,
) {
  final existing = store.locationFor(sourceId, entry.path);
  final id = existing?['id'] as String? ?? const Uuid().v4();
  final previous = store.get('media', id);
  if (previous == null || previous.deleted) {
    store.save('media', id, {
      'title': entry.name,
      'fileName': entry.name,
      'series': entry.name,
      'season': '',
      'episode': '',
      'size': entry.size,
      'duration': 0,
      'personalMedia': true,
      'localOnly': true,
    });
  }
  if (existing == null ||
      (entry.size > 0 && existing['size'] != entry.size) ||
      (entry.modified > 0 && existing['modified'] != entry.modified)) {
    final previewRevision =
        existing?['previewRevision'] ??
        matchingBrowsingPreviewRevision(
          store,
          sourceId,
          entry.path,
          entry.size,
          entry.modified,
        );
    store.setLocal('location:$id', {
      ...?existing,
      'id': id,
      'source': sourceId,
      'path': entry.path,
      'size': entry.size > 0 ? entry.size : existing?['size'] ?? 0,
      'modified': entry.modified > 0
          ? entry.modified
          : existing?['modified'] ?? 0,
      'previewRevision': ?previewRevision,
    });
  }
  final stored = store.get('media', id)!;
  if (stored.data['personalMedia'] == true) return stored;
  // Opening a file from an album changes this playback session's behavior,
  // never an existing film's identity, library membership or sync policy.
  return SyncRecord(
    id: stored.id,
    kind: stored.kind,
    data: Map.unmodifiable({...stored.data, 'personalMedia': true}),
    modifiedAt: stored.modifiedAt,
    deviceId: stored.deviceId,
    deviceName: stored.deviceName,
    version: stored.version,
    revision: stored.revision,
    deleted: stored.deleted,
    dirty: stored.dirty,
  );
}

Future<Map<String, String>> _readMediaTechnicalLabels(
  AppStore store,
  List<String> ids,
  CancelToken cancel,
) async {
  final labels = <String, String>{};
  for (var offset = 0; offset < ids.length; offset += 32) {
    await retryStoreBusy(() {
      cancel.check();
      final end = (offset + 32).clamp(0, ids.length);
      for (var index = offset; index < end; index++) {
        final id = ids[index];
        if (labels.containsKey(id)) continue;
        final record = store.get('media', id);
        if (record != null && !record.deleted) {
          labels[id] = MediaTechnicalInfo.forRecord(store, record).label;
        }
      }
    });
    // This is the state worker, not the UI isolate. Let its port receive
    // cancellation between bounded read batches without opening more workers.
    if (offset + 32 < ids.length) await Future<void>.delayed(Duration.zero);
  }
  cancel.check();
  return labels;
}
