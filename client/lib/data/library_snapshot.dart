import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../danmaku/release_name.dart';
import '../sources/source.dart';
import 'media_episodes.dart';
import 'media_presentation.dart';
import 'store.dart';

/// Prepared library content. UI builds only the cards it can display.
class LibrarySnapshot {
  final String query;
  final List<SyncRecord> media, recent;
  final Map<String, SyncRecord> byId;
  final Map<String, List<SyncRecord>> series;
  final Map<String, String> seriesKeys;
  final Map<String, String> episodeKeys;
  final Map<String, List<SyncRecord>> episodeVersions, episodes;
  final Map<String, SyncRecord> representatives;
  final Map<String, SyncRecord> latestBySeries;
  final Map<String, MediaCollectionDetails> details;
  final Map<String, Map<String, SyncRecord>> recordsBySource;
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
    required this.seriesKeys,
    required this.episodeKeys,
    required this.episodeVersions,
    required this.episodes,
    required this.representatives,
    required this.latestBySeries,
    required this.details,
    required this.recordsBySource,
    required this.folders,
    required this.recent,
    required this.posters,
    required this.files,
    required this.locations,
    required this.progress,
    required this.preparationIsolate,
  });

  String seriesKeyFor(SyncRecord record) =>
      seriesKeys[record.id] ?? mediaSeriesKey(record);

  List<SyncRecord> seriesFor(SyncRecord record) =>
      series[seriesKeyFor(record)] ?? const [];

  String episodeKeyFor(SyncRecord record) =>
      episodeKeys[record.id] ??
      mediaEpisodeKey(record, seriesKey: seriesKeyFor(record));

  List<SyncRecord> versionsFor(SyncRecord record) =>
      episodeVersions[episodeKeyFor(record)] ?? const [];

  List<SyncRecord> episodesFor(SyncRecord record) =>
      episodes[seriesKeyFor(record)] ?? const [];

  SyncRecord representativeFor(SyncRecord record) =>
      representatives[seriesKeyFor(record)] ?? record;

  SyncRecord? latestFor(SyncRecord record) =>
      latestBySeries[seriesKeyFor(record)];

  MediaCollectionDetails detailsFor(SyncRecord record) =>
      details[seriesKeyFor(record)] ??
      const MediaCollectionDetails(title: '影视资料');
}

class LibraryFolderSnapshot {
  final List<SourceEntry> entries;
  final List<SyncRecord> records;

  /// Null for mixed or unknown folders. Standalone extras do not hide a series.
  final String? seriesKey;
  final Map<String, SyncRecord> latestBySeries;
  // A parsed or verified collection identity selects one group in this folder.
  // Ambiguous aliases are omitted; unrelated historical files stay isolated.
  final Map<String, String> seriesByIdentity;
  LibraryFolderSnapshot({
    List<SourceEntry>? entries,
    List<SyncRecord>? records,
    this.seriesKey,
    this.latestBySeries = const {},
    this.series = const {},
    this.seriesByIdentity = const {},
  }) : entries = entries ?? [],
       records = records ?? [];
  final Map<String, List<SyncRecord>> series;
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

/// One index owns membership for cards, details, search and recent playback.
/// A verified series can adopt parsed siblings using unambiguous filename
/// evidence without rewriting their metadata or overriding a manual match.
class _LibrarySeriesIndex {
  late final Map<String, String> keys;
  late final Map<String, List<SyncRecord>> groups;

  _LibrarySeriesIndex(List<SyncRecord> records) {
    final aliases = <String, Set<String>>{};
    final evidence = <String, Set<String>>{};
    for (final record in records) {
      final names = evidence[record.id] = _aliases(record);
      if (!_verified(record)) continue;
      final key = mediaSeriesKey(record);
      for (final name in names) {
        (aliases[name] ??= {}).add(key);
      }
    }
    final resolved = <String, String>{};
    final members = <String, List<SyncRecord>>{};
    for (final record in records) {
      var key = mediaSeriesKey(record);
      if (!_verified(record)) {
        final candidates = <String>{
          for (final name in evidence[record.id]!) ...?aliases[name],
        };
        if (candidates.length == 1) key = candidates.single;
      }
      resolved[record.id] = key;
      (members[key] ??= []).add(record);
    }
    keys = Map.unmodifiable(resolved);
    groups = Map.unmodifiable({
      for (final entry in members.entries)
        entry.key: List<SyncRecord>.unmodifiable(
          entry.value..sort(compareMediaEpisodes),
        ),
    });
  }

  static bool _verified(SyncRecord record) =>
      record.data['tmdbId'] != null || record.data['bangumiId'] != null;

  static Set<String> _aliases(SyncRecord record) {
    if (record.data['metadataType'] == 'movie') return const {};
    final names = <String>{};
    void add(String title, String season, String episode) {
      final name = title.toLowerCase().replaceAll(
        RegExp(r'[\s\p{P}\p{S}]', unicode: true),
        '',
      );
      if (episode.isEmpty || name.isEmpty || name == '未分类') return;
      final number = num.tryParse(season);
      final normalizedSeason = season.isEmpty
          ? '1'
          : number != null &&
                number.isFinite &&
                number == number.roundToDouble()
          ? '${number.toInt()}'
          : season;
      names.add('parsed:$name:$normalizedSeason');
    }

    add(
      '${record.data['series'] ?? ''}',
      '${record.data['season'] ?? ''}',
      '${record.data['episode'] ?? ''}',
    );
    // An edited, still-unverified identity is authoritative. The old filename
    // must not pull it back into the series the user just corrected away from.
    if (!_verified(record) && names.isNotEmpty) return names;
    final filename = '${record.data['fileName'] ?? record.data['title'] ?? ''}';
    final parsed = parseReleaseName(filename);
    add(
      parsed.anime,
      '${record.data['season'] ?? ''}'.isNotEmpty
          ? '${record.data['season']}'
          : parsed.season,
      parsed.episode,
    );
    return names;
  }
}

class _SnapshotData {
  final List<SyncRecord> media;
  late final List<SyncRecord> recent;
  final Map<String, SyncRecord> byId;
  late final Map<String, List<SyncRecord>> series;
  late final Map<String, String> seriesKeys;
  late final Map<String, String> episodeKeys;
  late final Map<String, List<SyncRecord>> episodeVersions, episodes;
  late final Map<String, SyncRecord> representatives;
  late final Map<String, SyncRecord> latestBySeries;
  late final Map<String, MediaCollectionDetails> details;
  late final Map<String, Map<String, SyncRecord>> recordsBySource;
  late final Map<String, LibraryFolderSnapshot> folders;
  final Map<String, Map<String, dynamic>> locations, progress;
  LibrarySnapshot? _lastSnapshot;

  _SnapshotData._(
    this.media,
    List<SyncRecord> history,
    this.locations,
    this.progress,
  ) : byId = Map.unmodifiable({for (final record in media) record.id: record}) {
    final index = _LibrarySeriesIndex(media);
    series = index.groups;
    seriesKeys = index.keys;
    episodeKeys = Map.unmodifiable({
      for (final record in media)
        record.id: mediaEpisodeKey(record, seriesKey: seriesKeys[record.id]),
    });
    episodeVersions = Map.unmodifiable({
      for (final entry in series.entries)
        for (final versions in groupMediaEpisodes(
          entry.value,
          seriesKey: entry.key,
        ).entries)
          versions.key: List<SyncRecord>.unmodifiable(versions.value),
    });
    episodes = Map.unmodifiable({
      for (final entry in series.entries)
        entry.key: List<SyncRecord>.unmodifiable(
          uniqueMediaEpisodes(
            entry.value,
            seriesKey: entry.key,
            playable: (record) => locations.containsKey(record.id),
          )..sort(compareMediaEpisodes),
        ),
    });
    folders = _groupFolders(media, locations, seriesKeys, history);
    representatives = Map.unmodifiable({
      for (final entry in series.entries)
        entry.key: entry.value.firstWhere(
          _LibrarySeriesIndex._verified,
          orElse: () => entry.value.first,
        ),
    });
    final seen = <String>{};
    recent = List.unmodifiable(
      history.where((record) => seen.add(seriesKeys[record.id]!)),
    );
    latestBySeries = Map.unmodifiable({
      for (final record in recent) seriesKeys[record.id]!: record,
    });
    details = Map.unmodifiable({
      for (final entry in series.entries)
        entry.key: MediaCollectionDetails.fromRecords(entry.value),
    });
    final sources = <String, Map<String, SyncRecord>>{};
    for (final record in media) {
      final location = locations[record.id];
      if (location?['source'] is! String || location?['path'] is! String) {
        continue;
      }
      (sources[location!['source'] as String] ??=
              {})[(location['path'] as String).replaceAll('\\', '/')] =
          record;
    }
    recordsBySource = Map.unmodifiable({
      for (final entry in sources.entries)
        entry.key: Map<String, SyncRecord>.unmodifiable(entry.value),
    });
  }

  static Map<String, LibraryFolderSnapshot> _groupFolders(
    List<SyncRecord> media,
    Map<String, Map<String, dynamic>> locations,
    Map<String, String> seriesKeys,
    List<SyncRecord> history,
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
    final latest = <String, Map<String, SyncRecord>>{};
    for (final record in history) {
      final location = locations[record.id];
      if (location?['source'] is! String || location?['path'] is! String) {
        continue;
      }
      final path = (location!['path'] as String).replaceAll('\\', '/');
      final folder =
          '${location['source']}\u0000${p.posix.normalize(p.posix.dirname(path))}';
      (latest[folder] ??= {}).putIfAbsent(seriesKeys[record.id]!, () => record);
    }
    String? collectionKey(LibraryFolderSnapshot folder) {
      final keys = {
        for (final record in folder.records)
          if (!seriesKeys[record.id]!.startsWith('file:'))
            seriesKeys[record.id]!,
      };
      return keys.length == 1 ? keys.single : null;
    }

    Map<String, List<SyncRecord>> collectionRecords(
      LibraryFolderSnapshot folder,
    ) {
      final groups = <String, List<SyncRecord>>{};
      for (final record in folder.records) {
        (groups[seriesKeys[record.id]!] ??= []).add(record);
      }
      return Map.unmodifiable({
        for (final entry in groups.entries)
          entry.key: List<SyncRecord>.unmodifiable(
            entry.value..sort(compareMediaEpisodes),
          ),
      });
    }

    Map<String, String> collectionIdentities(LibraryFolderSnapshot folder) {
      final candidates = <String, Set<String>>{};
      for (final record in folder.records) {
        final key = seriesKeys[record.id]!;
        for (final identity in {
          mediaSeriesKey(record),
          ..._LibrarySeriesIndex._aliases(record),
        }) {
          (candidates[identity] ??= {}).add(key);
        }
      }
      return Map.unmodifiable({
        for (final entry in candidates.entries)
          if (entry.value.length == 1) entry.key: entry.value.single,
      });
    }

    return Map.unmodifiable({
      for (final entry in groups.entries)
        entry.key: LibraryFolderSnapshot(
          entries: List.unmodifiable(entry.value.entries),
          records: List.unmodifiable(entry.value.records),
          seriesKey: collectionKey(entry.value),
          latestBySeries: Map.unmodifiable(latest[entry.key] ?? const {}),
          series: collectionRecords(entry.value),
          seriesByIdentity: collectionIdentities(entry.value),
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
    final recent = List<SyncRecord>.unmodifiable(
      candidates.map((item) => item.media),
    );
    return _SnapshotData._(media, recent, locations, progress);
  }

  LibrarySnapshot prepare(String query) {
    if (_lastSnapshot?.query == query) return _lastSnapshot!;
    final posters = <MapEntry<String, List<SyncRecord>>>[];
    final files = <MapEntry<String, List<SyncRecord>>>[];
    // Search chooses shortcuts, never a partial episode list. A filename hit
    // must open the same complete collection as the unfiltered library card.
    for (final entry in series.entries) {
      if (query.isNotEmpty &&
          !entry.value.any(
            (record) =>
                [
                  'series',
                  'metadataTitle',
                  'title',
                  'fileName',
                  'episodeTitle',
                ].any(
                  (field) => '${record.data[field] ?? ''}'
                      .toLowerCase()
                      .contains(query),
                ),
          )) {
        continue;
      }
      final destination =
          entry.value.any((item) => '${item.data['poster'] ?? ''}'.isNotEmpty)
          ? posters
          : files;
      destination.add(entry);
    }
    return _lastSnapshot = LibrarySnapshot(
      query: query,
      media: media,
      byId: byId,
      series: series,
      seriesKeys: seriesKeys,
      episodeKeys: episodeKeys,
      episodeVersions: episodeVersions,
      episodes: episodes,
      representatives: representatives,
      latestBySeries: latestBySeries,
      details: details,
      recordsBySource: recordsBySource,
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
