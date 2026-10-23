import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../sources/source.dart';
import 'media_presentation.dart';
import 'store.dart';

/// Prepared library content. UI builds only the cards it can display.
class LibrarySnapshot {
  final String query;
  final List<SyncRecord> media, recent;
  final Map<String, SyncRecord> byId;
  final Map<String, List<SyncRecord>> series;
  final Map<String, LibraryFolderSnapshot> folders;
  final List<MapEntry<String, List<SyncRecord>>> posters, files;
  final Map<String, Map<String, dynamic>> locations, progress;

  // Exposes execution placement to regression tests without timing thresholds.
  final int preparationIsolate;

  const LibrarySnapshot({
    required this.query,
    required this.media,
    required this.byId,
    required this.series,
    required this.folders,
    required this.recent,
    required this.posters,
    required this.files,
    required this.locations,
    required this.progress,
    required this.preparationIsolate,
  });
}

class LibraryFolderSnapshot {
  final List<SourceEntry> entries;
  final List<SyncRecord> records;
  LibraryFolderSnapshot({List<SourceEntry>? entries, List<SyncRecord>? records})
    : entries = entries ?? [],
      records = records ?? [];
}

/// One lazy worker and read-only SQLite connection per model. AppModel admits
/// one request at a time, so searches cannot create an unbounded worker queue.
class LibrarySnapshotReader {
  final AppStore store;
  LibrarySnapshotReader(this.store);

  Isolate? _worker;
  ReceivePort? _events;
  Future<SendPort>? _starting;
  Completer<SendPort>? _ready;
  SendPort? _requestPort;
  final _pending = <int, Completer<LibrarySnapshot>>{};
  int _nextRequest = 0;
  bool _disposed = false;
  _SnapshotData? _memoryData;
  Object? _memoryRevision;

  Future<LibrarySnapshot> read({
    required String query,
    required (int, int, int) revision,
  }) async {
    if (_disposed) throw const Cancelled();
    if (store.path == ':memory:') {
      // Private in-memory databases cannot be opened by another connection.
      // This equivalent path is for tests; production uses the disk worker.
      if (_memoryData == null || _memoryRevision != revision) {
        _memoryData = _SnapshotData.fromRecords(
          store.all('media'),
          store.records('progress'),
          store.localEntries('location:'),
        );
        _memoryRevision = revision;
      }
      return _memoryData!.prepare(query);
    }
    final port = await (_starting ??= _startWorker());
    if (_disposed) throw const Cancelled();
    final id = _nextRequest++;
    final result = Completer<LibrarySnapshot>();
    _pending[id] = result;
    port.send((id, revision, query));
    return result.future;
  }

  Future<SendPort> _startWorker() {
    final events = _events = ReceivePort();
    final ready = _ready = Completer<SendPort>();
    events.listen((message) {
      if (message is SendPort) {
        _requestPort = message;
        if (!ready.isCompleted) ready.complete(message);
      } else if (message case (int id, LibrarySnapshot snapshot)) {
        _pending.remove(id)?.complete(snapshot);
      } else if (message case (int id, String error, String trace)) {
        _pending
            .remove(id)
            ?.completeError(StateError(error), StackTrace.fromString(trace));
      } else if (!_disposed) {
        _stopWorker(
          StateError('Library snapshot worker stopped: $message'),
          events,
        );
      }
    });
    // Attach to ready.future before spawning: disposal during isolate startup
    // must cancel the caller without leaving an unobserved completer error.
    unawaited(
      Isolate.spawn(
        _snapshotWorker,
        (store.path, events.sendPort),
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: 'library-snapshot',
      ).then<void>(
        (worker) {
          if (_disposed || !identical(_events, events)) {
            worker.kill(priority: Isolate.immediate);
          } else {
            _worker = worker;
          }
        },
        onError: (Object error, StackTrace trace) {
          _stopWorker(error, events, trace);
        },
      ),
    );
    return ready.future;
  }

  void _stopWorker(Object error, ReceivePort events, [StackTrace? trace]) {
    if (!identical(_events, events)) return;
    _fail(error, trace);
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _events = null;
    _requestPort = null;
    _starting = null;
    events.close();
  }

  void _fail(Object error, [StackTrace? trace]) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(error, trace);
    for (final result in _pending.values) {
      result.completeError(error, trace);
    }
    _pending.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fail(const Cancelled());
    final port = _requestPort;
    if (port != null) {
      port.send(null);
    } else {
      _worker?.kill(priority: Isolate.immediate);
    }
    _events?.close();
    _memoryData = null;
  }
}

void _snapshotWorker((String, SendPort) arguments) {
  final (path, replies) = arguments;
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  database.execute('PRAGMA busy_timeout=5000');
  final requests = ReceivePort();
  _SnapshotData? data;
  Object? currentRevision;
  replies.send(requests.sendPort);
  requests.listen((message) {
    if (message == null) {
      database.dispose();
      requests.close();
      Isolate.exit();
    }
    final (id, revision, query) = message as (int, (int, int, int), String);
    try {
      if (data == null || revision != currentRevision) {
        // A deferred read transaction gives all three tables one WAL snapshot.
        database.execute('BEGIN');
        try {
          data = _SnapshotData.fromRecords(
            database
                .select(
                  "SELECT * FROM records WHERE kind='media' AND deleted=0 ORDER BY id",
                )
                .map(_readRecord),
            database
                .select(
                  "SELECT * FROM records WHERE kind='progress' AND deleted=0 ORDER BY id",
                )
                .map(_readRecord),
            {
              for (final row in database.select(
                "SELECT key,value FROM local WHERE key>='location:' AND key<'location;'",
              ))
                row['key'] as String: jsonDecode(row['value'] as String),
            },
          );
          database.execute('COMMIT');
        } catch (_) {
          database.execute('ROLLBACK');
          rethrow;
        }
        currentRevision = revision;
      }
      replies.send((id, data!.prepare(query)));
    } catch (error, trace) {
      replies.send((id, '$error', '$trace'));
    }
  });
}

SyncRecord _readRecord(Row row) => SyncRecord(
  id: row['id'],
  kind: row['kind'],
  version: row['version'],
  revision: row['revision'],
  modifiedAt: row['modified_at'],
  deviceId: row['device_id'],
  deviceName: row['device_name'],
  dirty: row['dirty'] == 1,
  deleted: row['deleted'] == 1,
  data: Map<String, dynamic>.from(jsonDecode(row['data'])),
);

dynamic _freeze(dynamic value) => switch (value) {
  Map() => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _freeze(entry.value),
  }),
  List() => List<dynamic>.unmodifiable(value.map(_freeze)),
  _ => value,
};

SyncRecord _freezeRecord(SyncRecord record) => SyncRecord(
  id: record.id,
  kind: record.kind,
  data: _freeze(record.data) as Map<String, dynamic>,
  modifiedAt: record.modifiedAt,
  deviceId: record.deviceId,
  deviceName: record.deviceName,
  version: record.version,
  revision: record.revision,
  deleted: record.deleted,
  dirty: record.dirty,
);

class _SnapshotData {
  final List<SyncRecord> media, recent;
  final Map<String, SyncRecord> byId;
  final Map<String, List<SyncRecord>> series;
  final Map<String, LibraryFolderSnapshot> folders;
  final Map<String, Map<String, dynamic>> locations, progress;
  LibrarySnapshot? _lastSnapshot;

  _SnapshotData._(this.media, this.recent, this.locations, this.progress)
    : byId = Map.unmodifiable({for (final record in media) record.id: record}),
      series = _groupSeries(media),
      folders = _groupFolders(media, locations);

  static Map<String, LibraryFolderSnapshot> _groupFolders(
    List<SyncRecord> media,
    Map<String, Map<String, dynamic>> locations,
  ) {
    final groups = <String, LibraryFolderSnapshot>{};
    for (final record in media) {
      final location = locations[record.id];
      if (location == null ||
          location['source'] is! String ||
          location['path'] is! String) {
        continue;
      }
      final path = (location['path'] as String).replaceAll('\\', '/');
      final key =
          '${location['source']}\u0000${p.posix.normalize(p.posix.dirname(path))}';
      final folder = groups.putIfAbsent(key, LibraryFolderSnapshot.new);
      folder.records.add(record);
      folder.entries.add(
        SourceEntry(
          name: '${record.data['fileName'] ?? p.posix.basename(path)}',
          path: path,
          size: (location['size'] as num?)?.toInt() ?? 0,
          modified: (location['modified'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return Map.unmodifiable({
      for (final entry in groups.entries)
        entry.key: LibraryFolderSnapshot(
          entries: List.unmodifiable(entry.value.entries),
          records: List.unmodifiable(entry.value.records),
        ),
    });
  }

  static Map<String, List<SyncRecord>> _groupSeries(List<SyncRecord> media) {
    final groups = <String, List<SyncRecord>>{};
    for (final record in media) {
      (groups[mediaSeriesKey(record)] ??= []).add(record);
    }
    return Map.unmodifiable({
      for (final entry in groups.entries)
        entry.key: List<SyncRecord>.unmodifiable(
          entry.value..sort(compareMediaEpisodes),
        ),
    });
  }

  factory _SnapshotData.fromRecords(
    Iterable<SyncRecord> records,
    Iterable<SyncRecord> history,
    Map<String, dynamic> savedLocations,
  ) {
    final media = List<SyncRecord>.unmodifiable(
      records
          .where(
            (record) => !record.deleted && record.data['transient'] != true,
          )
          .map(_freezeRecord),
    );
    final progress = Map<String, Map<String, dynamic>>.unmodifiable({
      for (final record in history)
        if (!record.deleted)
          record.id: _freeze(record.data) as Map<String, dynamic>,
    });
    final locations = Map<String, Map<String, dynamic>>.unmodifiable({
      for (final entry in savedLocations.entries)
        if (entry.value is Map)
          entry.key.substring('location:'.length):
              _freeze(entry.value) as Map<String, dynamic>,
    });
    final candidates = <({SyncRecord media, String updatedAt})>[];
    for (final item in media) {
      final size = locations[item.id]?['size'] ?? item.data['size'] ?? 0;
      final saved = progress['${item.id}:$size'];
      if (((saved?['position'] as num?) ?? 0) > 0) {
        candidates.add((
          media: item,
          updatedAt: '${saved?['updatedAt'] ?? ''}',
        ));
      }
    }
    candidates.sort((a, b) {
      final order = b.updatedAt.compareTo(a.updatedAt);
      return order == 0 ? a.media.id.compareTo(b.media.id) : order;
    });
    final seen = <String>{};
    final recent = List<SyncRecord>.unmodifiable(
      candidates
          .map((item) => item.media)
          .where((item) => seen.add(mediaSeriesKey(item))),
    );
    return _SnapshotData._(media, recent, locations, progress);
  }

  LibrarySnapshot prepare(String query) {
    if (_lastSnapshot?.query == query) return _lastSnapshot!;
    final groups = <String, List<SyncRecord>>{};
    for (final item in media) {
      final series = '${item.data['series']}';
      if (query.isNotEmpty &&
          !series.toLowerCase().contains(query) &&
          !'${item.data['title']}'.toLowerCase().contains(query)) {
        continue;
      }
      final identifiable =
          (item.data['episode'] as String? ?? '').isNotEmpty ||
          item.data['bangumiId'] != null ||
          item.data['tmdbId'] != null;
      final key = identifiable && series != '未分类' && series.isNotEmpty
          ? mediaSeriesKey(item)
          : 'file:${item.id}';
      (groups[key] ??= []).add(item);
    }
    final posters = <MapEntry<String, List<SyncRecord>>>[];
    final files = <MapEntry<String, List<SyncRecord>>>[];
    for (final entry in groups.entries) {
      final destination =
          entry.value.any((item) => '${item.data['poster'] ?? ''}'.isNotEmpty)
          ? posters
          : files;
      destination.add(MapEntry(entry.key, List.unmodifiable(entry.value)));
    }
    return _lastSnapshot = LibrarySnapshot(
      query: query,
      media: media,
      byId: byId,
      series: series,
      folders: folders,
      recent: recent,
      posters: List.unmodifiable(posters),
      files: List.unmodifiable(files),
      locations: locations,
      progress: progress,
      preparationIsolate: Isolate.current.hashCode,
    );
  }
}
