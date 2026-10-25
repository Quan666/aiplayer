import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:path/path.dart' as p;

import '../core/network.dart';
import 'media_identity.dart';
import '../sources/directory_sort.dart';
import '../sources/source.dart';
import 'library_sort.dart';
import 'media_episodes.dart';
import 'media_presentation.dart';
import 'media_title_translation.dart';
import 'store.dart';

typedef LibrarySearchRevision = (int, int, (String, String, String));

/// Prepared library content. UI builds only the cards it can display.
class LibrarySnapshot {
  final String query;
  final LibrarySort sort;
  final List<SyncRecord> media, recent;

  /// Search matches any episode in a collection while retaining its latest
  /// resume record. The complete history remains available through [recent].
  final List<SyncRecord> searchRecent;
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
  final List<SourceEntry> localEntries;
  final Map<String, SyncRecord> localRecords;
  final int localHiddenEntries,
      localSubtitleEntries,
      localHiddenSubtitleEntries;
  final List<MapEntry<String, List<SyncRecord>>> groups, posters, files;
  final Map<String, Map<String, dynamic>> locations, progress;

  // Exposes execution placement to regression tests without timing thresholds.
  final int preparationIsolate;

  const LibrarySnapshot({
    required this.query,
    required this.sort,
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
    this.localEntries = const [],
    this.localRecords = const {},
    this.localHiddenEntries = 0,
    this.localSubtitleEntries = 0,
    this.localHiddenSubtitleEntries = 0,
    required this.recent,
    required this.searchRecent,
    required this.groups,
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
  final Map<String, SyncRecord> recordsByPath;

  /// Null for mixed or unknown folders. Standalone extras do not hide a series.
  final String? seriesKey;
  final Map<String, SyncRecord> latestBySeries;
  // A parsed or verified collection identity selects one group in this folder.
  // Ambiguous aliases are omitted; unrelated historical files stay isolated.
  final Map<String, String> seriesByIdentity;
  LibraryFolderSnapshot({
    List<SourceEntry>? entries,
    List<SyncRecord>? records,
    this.recordsByPath = const {},
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
  (int, int, int)? _memoryRevision;
  _LibrarySearchLabels? _memorySearchLabels;
  (int, LibrarySearchRevision)? _memorySearchRevision;

  Future<LibrarySnapshot> read({
    required String query,
    required (int, int, int) revision,
    LibrarySort sort = const LibrarySort(),
    LibrarySearchRevision? searchRevision,
  }) async {
    if (_disposed) throw const Cancelled();
    if (query.isNotEmpty && searchRevision == null) {
      final settings = store.local('settings') as Map? ?? const {};
      searchRevision = (
        store.localPrefixRevision('episodeTitle:'),
        store.localPrefixRevision('media-title-display:'),
        MediaTitleTranslations.profileInputs(settings),
      );
    }
    if (store.path == ':memory:') {
      // Private in-memory databases cannot be opened by another connection.
      // This equivalent path is for tests; production uses the disk worker.
      if (_memoryData == null || _memoryRevision != revision) {
        final previous = _memoryRevision;
        _memoryData =
            _memoryData != null &&
                previous?.$1 == revision.$1 &&
                previous?.$3 == revision.$3
            ? _memoryData!.withProgress(store.records('progress'))
            : _SnapshotData.fromRecords(
                store.all('media'),
                store.records('progress'),
                store.localEntries('location:'),
              );
        _memoryRevision = revision;
      }
      if (query.isNotEmpty &&
          _memorySearchRevision != (revision.$1, searchRevision!)) {
        _memorySearchLabels = _LibrarySearchLabels(_memoryData!.media, {
          ...store.localEntries('episodeTitle:'),
          ...store.localEntries('media-title-display:'),
          'settings': store.local('settings'),
        });
        _memorySearchRevision = (revision.$1, searchRevision);
      }
      return _memoryData!.prepare(
        query,
        sort,
        query.isEmpty ? null : _memorySearchLabels,
      );
    }
    final port = await (_starting ??= _startWorker());
    if (_disposed) throw const Cancelled();
    final id = _nextRequest++;
    final result = Completer<LibrarySnapshot>();
    _pending[id] = result;
    port.send((id, revision, query, sort, searchRevision));
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
    _memorySearchLabels = null;
  }
}

void _snapshotWorker((String, SendPort) arguments) {
  final (path, replies) = arguments;
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  database.execute('PRAGMA busy_timeout=5000');
  final requests = ReceivePort();
  _SnapshotData? data;
  (int, int, int)? currentRevision;
  _LibrarySearchLabels? searchLabels;
  (int, LibrarySearchRevision)? currentSearchRevision;
  replies.send(requests.sendPort);
  requests.listen((message) {
    if (message == null) {
      database.dispose();
      requests.close();
      Isolate.exit();
    }
    final (
      id,
      revision,
      query,
      sort,
      searchRevision,
    ) = message
        as (int, (int, int, int), String, LibrarySort, LibrarySearchRevision?);
    try {
      final refreshData = data == null || revision != currentRevision;
      final refreshSearch =
          query.isNotEmpty &&
          currentSearchRevision != (revision.$1, searchRevision!);
      if (refreshData || refreshSearch) {
        // A deferred read transaction gives all three tables one WAL snapshot.
        database.execute('BEGIN');
        try {
          if (refreshData) {
            final history = database
                .select(
                  "SELECT * FROM records WHERE kind='progress' AND deleted=0 ORDER BY id",
                )
                .map(_readRecord);
            final previous = currentRevision;
            data =
                data != null &&
                    previous?.$1 == revision.$1 &&
                    previous?.$3 == revision.$3
                ? data!.withProgress(history)
                : _SnapshotData.fromRecords(
                    database
                        .select(
                          "SELECT * FROM records WHERE kind='media' AND deleted=0 ORDER BY id",
                        )
                        .map(_readRecord),
                    history,
                    {
                      for (final row in database.select(
                        "SELECT key,value FROM local WHERE key>='location:' AND key<'location;'",
                      ))
                        row['key'] as String: jsonDecode(
                          row['value'] as String,
                        ),
                    },
                  );
          }
          if (refreshSearch) {
            searchLabels = _LibrarySearchLabels(data!.media, {
              for (final row in database.select(
                "SELECT key,value FROM local WHERE key='settings' "
                "OR (key>='episodeTitle:' AND key<'episodeTitle;') "
                "OR (key>='media-title-display:' AND key<'media-title-display;')",
              ))
                row['key'] as String: jsonDecode(row['value'] as String),
            });
          }
          database.execute('COMMIT');
        } catch (_) {
          database.execute('ROLLBACK');
          rethrow;
        }
        currentRevision = revision;
        if (refreshSearch) {
          currentSearchRevision = (revision.$1, searchRevision);
        }
      }
      replies.send((
        id,
        data!.prepare(query, sort, query.isEmpty ? null : searchLabels),
      ));
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

/// Display overrides are read in bulk only while a search is active. Keeping
/// their index separate avoids reparsing media or folders after a translation.
class _LibrarySearchLabels {
  final Map<String, List<String>> labels;

  _LibrarySearchLabels(List<SyncRecord> media, Map<String, dynamic> local)
    : labels = {} {
    final profile = MediaTitleTranslations.profileFor(
      local['settings'] as Map? ?? const {},
    );
    final states = <String, Map>{};
    for (final record in media) {
      final key = mediaSeriesKey(record);
      final state = states.putIfAbsent(
        key,
        () =>
            local[MediaTitleTranslations.stateKeyFor(key, profile)] as Map? ??
            const {},
      );
      final episodeTitle =
          local['episodeTitle:${record.id}'] as String? ??
          '${record.data['episodeTitle'] ?? ''}';
      final title = MediaTitleTranslations.displayFrom(
        state,
        mediaSeriesName(record),
      );
      final episode = MediaTitleTranslations.displayFrom(state, episodeTitle);
      labels[record.id] = [
        episodeTitle.toLowerCase(),
        title.toLowerCase(),
        mediaEpisodeLabel(record, episodeTitle: episode).toLowerCase(),
      ];
    }
  }

  bool matches(String id, String query) =>
      labels[id]?.any((label) => label.contains(query)) ?? false;
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
  late final List<SourceEntry> localEntries;
  late final Map<String, SyncRecord> localRecords;
  late final int localHiddenEntries,
      localSubtitleEntries,
      localHiddenSubtitleEntries;
  final Map<String, Map<String, dynamic>> locations, progress;
  late final Map<String, _LibraryGroupOrder> _ordering;
  LibrarySnapshot? _lastSnapshot;
  _LibrarySearchLabels? _lastSearchLabels;

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
    final imports = <SourceEntry>[];
    final imported = <String, SyncRecord>{};
    var hiddenEntries = 0, subtitleEntries = 0, hiddenSubtitleEntries = 0;
    for (final record in media) {
      final location = locations[record.id];
      if (location?['source'] != 'local') continue;
      imported[record.id] = record;
      final entry = SourceEntry(
        name: '${record.data['fileName'] ?? record.data['title'] ?? ''}',
        path: record.id,
        size: (location?['size'] as num?)?.toInt() ?? 0,
        modified: (location?['modified'] as num?)?.toInt() ?? 0,
      );
      imports.add(entry);
      final hidden = isHiddenEntry(entry), subtitle = isSubtitle(entry.name);
      if (hidden) hiddenEntries++;
      if (subtitle) subtitleEntries++;
      if (hidden && subtitle) hiddenSubtitleEntries++;
    }
    localEntries = List.unmodifiable(imports);
    localRecords = Map.unmodifiable(imported);
    localHiddenEntries = hiddenEntries;
    localSubtitleEntries = subtitleEntries;
    localHiddenSubtitleEntries = hiddenSubtitleEntries;
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
    _ordering = {
      for (final entry in series.entries)
        entry.key: _LibraryGroupOrder(
          details[entry.key]!.title,
          entry.value,
          locations,
          progress,
        ),
    };
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

  /// Progress commits must not repeatedly parse the library or rebuild its
  /// metadata indices. Otherwise a live writer can outpace preparation and
  /// prevent any strictly current snapshot from reaching the UI.
  _SnapshotData._progress(_SnapshotData previous, this.progress)
    : media = previous.media,
      byId = previous.byId,
      locations = previous.locations {
    series = previous.series;
    seriesKeys = previous.seriesKeys;
    episodeKeys = previous.episodeKeys;
    episodeVersions = previous.episodeVersions;
    episodes = previous.episodes;
    representatives = previous.representatives;
    details = previous.details;
    recordsBySource = previous.recordsBySource;
    localEntries = previous.localEntries;
    localRecords = previous.localRecords;
    localHiddenEntries = previous.localHiddenEntries;
    localSubtitleEntries = previous.localSubtitleEntries;
    localHiddenSubtitleEntries = previous.localHiddenSubtitleEntries;
    final history = _history(media, locations, progress);
    final seen = <String>{};
    recent = List.unmodifiable(
      history.where((record) => seen.add(seriesKeys[record.id]!)),
    );
    latestBySeries = Map.unmodifiable({
      for (final record in recent) seriesKeys[record.id]!: record,
    });
    final folderLatest = _folderLatest(history, locations, seriesKeys);
    folders = Map.unmodifiable({
      for (final entry in previous.folders.entries)
        entry.key: LibraryFolderSnapshot(
          entries: entry.value.entries,
          records: entry.value.records,
          recordsByPath: entry.value.recordsByPath,
          seriesKey: entry.value.seriesKey,
          latestBySeries: Map.unmodifiable(folderLatest[entry.key] ?? const {}),
          series: entry.value.series,
          seriesByIdentity: entry.value.seriesByIdentity,
        ),
    });
    final playedAt = <String, int>{};
    for (final record in history) {
      final size = locations[record.id]?['size'] ?? record.data['size'] ?? 0;
      final time = _LibraryGroupOrder._time(
        progress['${record.id}:$size']?['updatedAt'],
      );
      final key = seriesKeys[record.id]!;
      if (time != null && (playedAt[key] == null || time > playedAt[key]!)) {
        playedAt[key] = time;
      }
    }
    _ordering = {
      for (final entry in previous._ordering.entries)
        entry.key: entry.value.withRecent(playedAt[entry.key]),
    };
  }

  _SnapshotData withProgress(Iterable<SyncRecord> records) =>
      _SnapshotData._progress(this, _freezeProgress(records));

  static Map<String, Map<String, SyncRecord>> _folderLatest(
    List<SyncRecord> history,
    Map<String, Map<String, dynamic>> locations,
    Map<String, String> seriesKeys,
  ) {
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
    return latest;
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
    final latest = _folderLatest(history, locations, seriesKeys);
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
          recordsByPath: Map.unmodifiable({
            for (var index = 0; index < entry.value.entries.length; index++)
              entry.value.entries[index].path: entry.value.records[index],
          }),
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
    final progress = _freezeProgress(history);
    final locations = Map<String, Map<String, dynamic>>.unmodifiable({
      for (final entry in savedLocations.entries)
        if (entry.value is Map)
          entry.key.substring('location:'.length):
              _freeze(entry.value) as Map<String, dynamic>,
    });
    return _SnapshotData._(
      media,
      _history(media, locations, progress),
      locations,
      progress,
    );
  }

  static Map<String, Map<String, dynamic>> _freezeProgress(
    Iterable<SyncRecord> history,
  ) => Map<String, Map<String, dynamic>>.unmodifiable({
    for (final record in history)
      if (!record.deleted)
        record.id: _freeze(record.data) as Map<String, dynamic>,
  });

  static List<SyncRecord> _history(
    List<SyncRecord> media,
    Map<String, Map<String, dynamic>> locations,
    Map<String, Map<String, dynamic>> progress,
  ) {
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
    return List<SyncRecord>.unmodifiable(candidates.map((item) => item.media));
  }

  LibrarySnapshot prepare(
    String query,
    LibrarySort sort, [
    _LibrarySearchLabels? searchLabels,
  ]) {
    if (_lastSnapshot?.query == query &&
        _lastSnapshot?.sort == sort &&
        identical(_lastSearchLabels, searchLabels)) {
      return _lastSnapshot!;
    }
    final groups = <MapEntry<String, List<SyncRecord>>>[];
    final posters = <MapEntry<String, List<SyncRecord>>>[];
    final files = <MapEntry<String, List<SyncRecord>>>[];
    final matchedSeries = <String>{};
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
                ) ||
                (searchLabels?.matches(record.id, query) ?? false),
          )) {
        continue;
      }
      groups.add(entry);
      if (query.isNotEmpty) matchedSeries.add(entry.key);
    }
    groups.sort((a, b) {
      final result = _ordering[a.key]!.compareTo(_ordering[b.key]!, sort);
      return result != 0 ? result : a.key.compareTo(b.key);
    });
    for (final entry in groups) {
      final destination =
          entry.value.any((item) => '${item.data['poster'] ?? ''}'.isNotEmpty)
          ? posters
          : files;
      destination.add(entry);
    }
    _lastSearchLabels = searchLabels;
    return _lastSnapshot = LibrarySnapshot(
      query: query,
      sort: sort,
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
      localEntries: localEntries,
      localRecords: localRecords,
      localHiddenEntries: localHiddenEntries,
      localSubtitleEntries: localSubtitleEntries,
      localHiddenSubtitleEntries: localHiddenSubtitleEntries,
      recent: recent,
      searchRecent: query.isEmpty
          ? recent
          : List.unmodifiable(
              recent.where(
                (record) => matchedSeries.contains(seriesKeys[record.id]),
              ),
            ),
      groups: List.unmodifiable(groups),
      posters: List.unmodifiable(posters),
      files: List.unmodifiable(files),
      locations: locations,
      progress: progress,
      preparationIsolate: Isolate.current.hashCode,
    );
  }
}

/// Aggregate once per data revision, never once per comparison or UI build.
/// Unknown values remain last in either direction; ties use names and group IDs.
class _LibraryGroupOrder {
  final _LibrarySortName name;
  int? recent, modified, updated, size;

  _LibraryGroupOrder(
    String title,
    List<SyncRecord> records,
    Map<String, Map<String, dynamic>> locations,
    Map<String, Map<String, dynamic>> progress,
  ) : name = _LibrarySortName(title) {
    for (final record in records) {
      final location = locations[record.id];
      final bytes = _number(location?['size'] ?? record.data['size']);
      if (bytes != null) size = (size ?? 0) + bytes;
      final recordTime = _time(record.modifiedAt);
      updated = _latest(updated, recordTime);
      modified = _latest(
        modified,
        _time(location?['modified']) ??
            _time(record.data['modified']) ??
            recordTime,
      );
      final progressSize = location?['size'] ?? record.data['size'] ?? 0;
      final saved = progress['${record.id}:$progressSize'];
      if (saved?['position'] is num && (saved!['position'] as num) > 0) {
        recent = _latest(recent, _time(saved['updatedAt']));
      }
    }
  }

  _LibraryGroupOrder._recent(_LibraryGroupOrder previous, this.recent)
    : name = previous.name,
      modified = previous.modified,
      updated = previous.updated,
      size = previous.size;

  _LibraryGroupOrder withRecent(int? value) =>
      value == recent ? this : _LibraryGroupOrder._recent(this, value);

  static int? _number(dynamic value) =>
      value is num && value.isFinite && value >= 0 ? value.toInt() : null;

  static int? _time(dynamic value) {
    if (value is num) {
      return value.isFinite && value > 0 ? value.toInt() : null;
    }
    return value is String
        ? DateTime.tryParse(value)?.millisecondsSinceEpoch
        : null;
  }

  static int? _latest(int? a, int? b) => a == null
      ? b
      : b == null || a >= b
      ? a
      : b;

  int? _value(String field) => switch (field) {
    'modified' => modified,
    'updated' => updated,
    'size' => size,
    _ => recent,
  };

  int compareTo(_LibraryGroupOrder other, LibrarySort sort) {
    final nameOrder = name.compareTo(other.name);
    if (sort.field == 'name') {
      return sort.descending ? -nameOrder : nameOrder;
    }
    final a = _value(sort.field), b = other._value(sort.field);
    if (a == null && b != null) return 1;
    if (a != null && b == null) return -1;
    final order = a == null ? 0 : a.compareTo(b!);
    if (order == 0) return nameOrder;
    return sort.descending ? -order : order;
  }
}

class _LibrarySortName {
  static final _chunks = RegExp(r'\d+|\D+');
  final String value;
  final List<({String text, String? number})> parts;

  _LibrarySortName(String name)
    : value = name.toLowerCase(),
      parts = _chunks.allMatches(name.toLowerCase()).map((match) {
        final text = match[0]!;
        final first = text.codeUnitAt(0);
        String? number;
        if (first >= 48 && first <= 57) {
          var start = 0;
          while (start < text.length && text.codeUnitAt(start) == 48) {
            start++;
          }
          number = text.substring(start);
        }
        return (text: text, number: number);
      }).toList();

  int compareTo(_LibrarySortName other) {
    for (var i = 0; i < parts.length && i < other.parts.length; i++) {
      final a = parts[i], b = other.parts[i];
      final an = a.number, bn = b.number;
      final order = an != null && bn != null
          ? an.length == bn.length
                ? an.compareTo(bn)
                : an.length.compareTo(bn.length)
          : a.text.compareTo(b.text);
      if (order != 0) return order;
    }
    final length = parts.length.compareTo(other.parts.length);
    return length != 0 ? length : value.compareTo(other.value);
  }
}
