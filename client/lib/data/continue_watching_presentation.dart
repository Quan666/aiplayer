import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../core/network.dart';
import 'media_presentation.dart';
import 'media_previews.dart';
import 'media_title_translation.dart';
import 'store.dart';

/// Everything a history card needs, prepared before its lazy UI build.
class ContinueWatchingPresentation {
  final String title, episode, originDeviceId, originDeviceName;
  final String originDevicePlatform, remoteDeviceName;
  final String? thumbnail;
  final double position, duration;
  final int preparationIsolate;

  const ContinueWatchingPresentation({
    required this.title,
    required this.episode,
    required this.thumbnail,
    required this.position,
    required this.duration,
    required this.originDeviceId,
    required this.originDeviceName,
    required this.originDevicePlatform,
    required this.remoteDeviceName,
    required this.preparationIsolate,
  });
}

typedef _Presentations = Map<String, ContinueWatchingPresentation>;

/// One reusable reader, with one running and one replaceable pending request.
/// SQLite and fingerprint/title hashing execute entirely in the reader isolate.
class ContinueWatchingPresentationReader {
  final AppStore store;
  ContinueWatchingPresentationReader(this.store);

  ReceivePort? _events;
  SendPort? _port;
  Future<SendPort>? _starting;
  _ReadRequest? _active, _pending;
  bool _disposed = false;
  int _nextId = 0;

  Future<Map<String, ContinueWatchingPresentation>> read(
    List<String> ids, {
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (_disposed) throw const Cancelled();
    if (store.path == ':memory:') {
      // Private in-memory connections are only used by tests. Keep exactly the
      // same preparation logic; production opens an independent disk reader.
      final result = _prepare(ids, store.get, store.local);
      cancel?.check();
      return result;
    }
    final request = _ReadRequest(_nextId++, ids, cancel);
    final result = request.done.future;
    if (_active == null) {
      _active = request;
      unawaited(_start(request));
    } else {
      _pending?.fail(const Cancelled());
      _pending = request;
    }
    StreamSubscription<void>? cancellation;
    if (cancel != null) {
      cancellation = cancel.whenCancelled.asStream().listen((_) {
        request.fail(const Cancelled());
        if (identical(_pending, request)) _pending = null;
      });
    }
    try {
      return await result;
    } finally {
      await cancellation?.cancel();
    }
  }

  Future<void> _start(_ReadRequest request) async {
    try {
      request.cancel?.check();
      final port = await (_starting ??= _startWorker());
      if (_disposed || request.cancel?.cancelled == true) {
        throw const Cancelled();
      }
      port.send((request.id, request.ids));
    } catch (error, trace) {
      request.fail(error, trace);
      _finished(request);
    }
  }

  Future<SendPort> _startWorker() {
    final events = _events = ReceivePort();
    final ready = Completer<SendPort>();
    events.listen((message) {
      if (message is SendPort) {
        _port = message;
        if (_disposed) message.send(null);
        if (!ready.isCompleted) ready.complete(message);
      } else if (message case (int id, _Presentations result)) {
        final active = _active;
        if (active?.id == id) {
          if (!active!.done.isCompleted) active.done.complete(result);
          _finished(active);
        }
      } else if (message case (int id, String error, String trace)) {
        final active = _active;
        if (active?.id == id) {
          active!.fail(StateError(error), StackTrace.fromString(trace));
          _finished(active);
        }
      } else {
        final error = StateError('History presentation reader stopped');
        if (!ready.isCompleted) ready.completeError(error);
        _active?.fail(error);
        _pending?.fail(error);
        _active = _pending = null;
        _starting = null;
        _port = null;
        events.close();
        if (identical(_events, events)) _events = null;
      }
    });
    unawaited(
      Isolate.spawn(
            _readerWorker,
            (store.path, events.sendPort),
            onError: events.sendPort,
            onExit: events.sendPort,
            debugName: 'continue-watching-presentation',
          )
          .catchError((Object error, StackTrace trace) {
            if (!ready.isCompleted) ready.completeError(error, trace);
            events.close();
            throw error;
          })
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return ready.future;
  }

  void _finished(_ReadRequest request) {
    if (!identical(_active, request)) return;
    _active = null;
    final next = _pending;
    _pending = null;
    if (_disposed || next == null) return;
    _active = next;
    unawaited(_start(next));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active?.fail(const Cancelled());
    _pending?.fail(const Cancelled());
    _active = _pending = null;
    // Let an in-flight read finish and close its transaction/connection. It is
    // read-only, cannot notify a released page, and SQLite waits are bounded.
    _port?.send(null);
  }
}

class _ReadRequest {
  final int id;
  final List<String> ids;
  final CancelToken? cancel;
  final done = Completer<_Presentations>();
  _ReadRequest(this.id, this.ids, this.cancel);

  void fail(Object error, [StackTrace? trace]) {
    if (!done.isCompleted) done.completeError(error, trace);
  }
}

void _readerWorker((String, SendPort) arguments) {
  final (path, replies) = arguments;
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  database.execute('PRAGMA busy_timeout=5000');
  final records = database.prepare(
    'SELECT * FROM records WHERE kind=? AND id=?',
  );
  final locals = database.prepare('SELECT value FROM local WHERE key=?');
  SyncRecord? record(String kind, String id) {
    final rows = records.select([kind, id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return SyncRecord(
      id: row['id'],
      kind: row['kind'],
      data: Map<String, dynamic>.from(jsonDecode(row['data'] as String)),
      deviceId: row['device_id'],
      deviceName: row['device_name'],
      deleted: row['deleted'] == 1,
    );
  }

  dynamic local(String key) {
    final rows = locals.select([key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
  }

  final requests = ReceivePort();
  replies.send(requests.sendPort);
  requests.listen((message) {
    if (message == null) {
      records.dispose();
      locals.dispose();
      database.dispose();
      requests.close();
      return;
    }
    final (id, ids) = message as (int, List<String>);
    try {
      database.execute('BEGIN');
      late final _Presentations result;
      try {
        result = _prepare(ids, record, local);
        database.execute('COMMIT');
      } catch (_) {
        database.execute('ROLLBACK');
        rethrow;
      }
      replies.send((id, result));
    } catch (error, trace) {
      replies.send((id, '$error', '$trace'));
    }
  });
}

_Presentations _prepare(
  List<String> ids,
  SyncRecord? Function(String kind, String id) record,
  dynamic Function(String key) local,
) {
  final settings = local('settings') as Map? ?? const {};
  final profile = MediaTitleTranslations.profileFor(settings);
  final deviceId = '${local('syncDevice:id') ?? ''}';
  final titleStates = <String, Map>{};
  String display(String series, String original) {
    if (original.isEmpty) return original;
    final state = titleStates.putIfAbsent(
      series,
      () =>
          local(MediaTitleTranslations.stateKeyFor(series, profile)) as Map? ??
          const {},
    );
    return MediaTitleTranslations.displayFrom(state, original);
  }

  final result = <String, ContinueWatchingPresentation>{};
  for (final id in ids) {
    final media = record('media', id);
    if (media == null || media.deleted || media.data['transient'] == true) {
      continue;
    }
    final location = local('location:$id') as Map?;
    final size = location?['size'] ?? media.data['size'] ?? 0;
    final progressRecord = record('progress', '$id:$size');
    final progress = progressRecord?.deleted == false
        ? progressRecord!.data
        : null;
    final position = (progress?['position'] as num?)?.toDouble() ?? 0;
    // Preview identity follows AppModel._previewPosition, including legacy
    // tombstone payloads. Displayed resume progress still ignores tombstones.
    final previewPosition = (progressRecord?.data['position'] as num?)
        ?.toDouble();
    final source = location ?? local('browse:$id') as Map?;
    final previewRequest =
        source?['source'] is String && source?['path'] is String
        ? MediaPreviewRequest(
            id,
            source!['source'] as String,
            source['path'] as String,
            (source['size'] as num?)?.toInt() ?? 0,
            revision: source['previewRevision'] as String? ?? '',
            position:
                previewPosition != null &&
                    previewPosition.isFinite &&
                    previewPosition > 0
                ? previewPosition
                : null,
          )
        : null;
    final fingerprint = previewRequest?.contentFingerprint;
    final saved = local('preview:$id');
    final thumbnail =
        saved is Map &&
            saved['path'] is String &&
            saved['formatVersion'] == MediaPreview.formatVersion &&
            (saved['fingerprint'] == previewRequest?.fingerprint ||
                saved['contentFingerprint'] == fingerprint)
        ? saved['path'] as String
        : null;
    final metadata = local('mediaMetadata:$id');
    final localDuration =
        metadata is Map && metadata['fingerprint'] == fingerprint
        ? (metadata['duration'] as num?)?.toDouble()
        : null;
    double duration = (progress?['duration'] as num?)?.toDouble() ?? 0;
    if (progress?['duration'] == null) {
      for (final candidate in [
        localDuration,
        (progressRecord?.data['duration'] as num?)?.toDouble(),
        (media.data['duration'] as num?)?.toDouble(),
      ]) {
        if (candidate != null && candidate.isFinite && candidate > 0) {
          duration = candidate;
          break;
        }
      }
    }
    final series = mediaSeriesKey(media);
    final episodeTitle =
        (local('episodeTitle:$id') as String?) ??
        '${media.data['episodeTitle'] ?? ''}';
    final origin =
        progressRecord != null && progressRecord.deviceName.isNotEmpty
        ? progressRecord
        : media;
    result[id] = ContinueWatchingPresentation(
      title: display(series, mediaSeriesName(media)),
      episode: mediaEpisodeLabel(
        media,
        episodeTitle: display(series, episodeTitle),
      ),
      thumbnail: thumbnail,
      position: position,
      duration: duration,
      originDeviceId: origin.deviceId,
      originDeviceName: origin.deviceName,
      originDevicePlatform: '${progressRecord?.data['devicePlatform'] ?? ''}',
      remoteDeviceName: origin.deviceId != deviceId ? origin.deviceName : '',
      preparationIsolate: Isolate.current.hashCode,
    );
  }
  return Map.unmodifiable(result);
}
