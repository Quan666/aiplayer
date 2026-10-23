import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/network.dart';
import '../core/logger.dart';
import '../danmaku/release_name.dart';
import '../sources/configuration.dart';
import '../sources/directory_sort.dart';
import '../sources/source.dart';
import 'library_catalog.dart';
import 'media_presentation.dart';
import 'source_preview.dart';
import 'store.dart';

class DirectoryMetadataResult {
  final DirectoryCollection collection;
  final bool changed;
  final List<String> mediaIds;
  const DirectoryMetadataResult(this.collection, this.changed, this.mediaIds);
}

String _exclusionKey(String source, String path) =>
    'automatic-import-excluded:${sha256.convert(utf8.encode(jsonEncode([source, path])))}';

SyncRecord? _sourceRecord(AppStore store, String source, String path) {
  final location = store.locationFor(source, path);
  if (location == null) return null;
  final record = store.get('media', location['id']);
  return record?.deleted == false ? record : null;
}

String _episodeTitle(AppStore store, SyncRecord record) {
  // Older sync bindings and episode-name refreshes update this local override.
  // Keep the same precedence as AppModel.originalEpisodeTitle.
  final local = store.local('episodeTitle:${record.id}');
  return local is String ? local : '${record.data['episodeTitle'] ?? ''}';
}

bool persistDirectoryEpisodeNames(
  AppStore store,
  SyncRecord anchor,
  Map<String, dynamic> subject,
  Map<String, String> names, {
  Set<String>? mediaIds,
}) {
  if (names.isEmpty) return false;
  String identity(SyncRecord record) =>
      '${normalizedSeries('${record.data['series'] ?? ''}')}:${'${record.data['season'] ?? ''}'.isEmpty ? '1' : record.data['season']}';
  var changed = false;
  store.transaction(() {
    final records = mediaIds == null
        ? store.all('media')
        : [for (final id in mediaIds) ?store.get('media', id)];
    // Keep the legacy parsed-name cache for older imports; the canonical title
    // lives with each episode so background snapshots and sync agree.
    store.setLocal('metadataEpisodeNames:${identity(anchor)}', names);
    for (final item in records) {
      if (item.deleted ||
          item.data['transient'] == true ||
          (mediaIds == null && identity(item) != identity(anchor))) {
        continue;
      }
      final sameSubject = subject['provider'] == 'tmdb'
          ? '${item.data['tmdbId']}' == '${subject['id']}' &&
                '${item.data['metadataType'] ?? 'tv'}' ==
                    '${subject['mediaType'] ?? 'tv'}'
          : '${item.data['bangumiId']}' == '${subject['id']}';
      if (!sameSubject ||
          '${item.data['season'] ?? ''}' != '${anchor.data['season'] ?? ''}') {
        continue;
      }
      final name = names['${item.data['episode']}'];
      if (name == null || name.isEmpty) continue;
      if (item.data['episodeTitle'] != name) {
        store.save('media', item.id, {...item.data, 'episodeTitle': name});
        changed = true;
      }
      if (store.local('episodeTitle:${item.id}') != name) {
        store.setLocal('episodeTitle:${item.id}', name);
        changed = true;
      }
    }
  });
  return changed;
}

bool _equalJson(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _equalJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equalJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class _DirectoryDonorEvidence {
  final SyncRecord? first;
  final bool manual;
  final Set<String> keys;
  final Map<String, String> episodeTitles;
  const _DirectoryDonorEvidence(
    this.first,
    this.manual,
    this.keys,
    this.episodeTitles,
  );
}

_DirectoryDonorEvidence _readDirectoryDonors(
  AppStore store,
  String sourceId,
  List<SourceEntry> videos,
) {
  final known = [
    for (final entry in videos) ?_sourceRecord(store, sourceId, entry.path),
  ];
  final verified = known
      .where(
        (record) =>
            record.data['tmdbId'] != null || record.data['bangumiId'] != null,
      )
      .toList();
  final manual = verified
      .where((record) => store.local('manualMetadata:${record.id}') == true)
      .toList();
  final donors = manual.isEmpty ? verified : manual;
  final keys = donors.map(mediaSeriesKey).toSet();
  final first = donors.firstOrNull;
  final titles = <String, String>{};
  if (keys.length == 1) {
    for (final record in known) {
      if (mediaSeriesKey(record) != keys.single) continue;
      final name = _episodeTitle(store, record);
      if (name.isNotEmpty) titles['${record.data['episode']}'] = name;
    }
  }
  return _DirectoryDonorEvidence(
    first,
    manual.isNotEmpty,
    Set.unmodifiable(keys),
    Map.unmodifiable(titles),
  );
}

/// One recognition group's donor evidence, reused across its bounded commits.
/// An import copies that evidence; only edits outside this operation require a
/// reread of the whole group. This cache must not outlive the recognition group.
class DirectoryMetadataDonorCache {
  final String sourceId;
  final List<SourceEntry> videos;
  AppStore? _store;
  (int, int, int, int)? _revision;
  _DirectoryDonorEvidence? _value;

  DirectoryMetadataDonorCache(this.sourceId, List<SourceEntry> videos)
    : videos = List.unmodifiable(videos);

  (int, int, int, int) _readRevision(AppStore store) => (
    store.recordsRevision('media'),
    store.locationRevision,
    store.localPrefixRevision('manualMetadata:'),
    store.localPrefixRevision('episodeTitle:'),
  );

  _DirectoryDonorEvidence _read(AppStore store, String source) {
    if (source != sourceId) {
      throw ArgumentError(
        'Directory donor cache belongs to a different source',
      );
    }
    final revision = _readRevision(store);
    if (!identical(_store, store) || _revision != revision || _value == null) {
      _value = _readDirectoryDonors(store, sourceId, videos);
      _store = store;
      _revision = revision;
    }
    return _value!;
  }

  void _checkpoint(AppStore store) {
    // Capture our own writes while BEGIN IMMEDIATE still holds the writer
    // lock. Capturing after COMMIT could swallow a concurrent manual edit.
    // A rollback advances AppStore's unknown revision and invalidates this too.
    _revision = _readRevision(store);
  }
}

/// This store-only operation runs on the worker connection in production.
/// Its transaction preserves both catalogue edits and portable media bindings.
DirectoryMetadataResult synchronizeDirectoryCollection(
  AppStore store,
  String sourceId,
  DirectoryCollection value, {
  bool? importMissing,
  String? anchorId,
  List<SourceEntry>? donorVideos,
  DirectoryMetadataDonorCache? donorCache,
}) {
  late DirectoryMetadataResult result;
  store.transaction(() {
    if (anchorId != null && store.get('media', anchorId)?.deleted != false) {
      result = DirectoryMetadataResult(value, false, const []);
      return;
    }
    final evidence =
        donorCache?._read(store, sourceId) ??
        _readDirectoryDonors(store, sourceId, donorVideos ?? value.videos);
    final keys = evidence.keys;
    var resolved = value;
    if (keys.length == 1) {
      final donor = evidence.first!;
      final incoming = value.subject == null
          ? null
          : subjectMediaFields(value.subject!);
      final sameSubject =
          incoming != null &&
          incoming['tmdbId'] == donor.data['tmdbId'] &&
          incoming['bangumiId'] == donor.data['bangumiId'] &&
          (incoming['tmdbId'] == null ||
              incoming['metadataType'] ==
                  (donor.data['metadataType'] ?? 'tv')) &&
          (value.season.isEmpty ? '1' : value.season) ==
              ('${donor.data['season'] ?? ''}'.isEmpty
                  ? '1'
                  : '${donor.data['season']}');
      final names = <String, String>{};
      for (final entry in value.videos) {
        final episode = value.identities[entry.path]?.episode;
        if (episode == null) continue;
        final saved = evidence.episodeTitles[episode] ?? '';
        final incoming = sameSubject ? value.episodeTitles[episode] ?? '' : '';
        final title = evidence.manual
            ? saved.isNotEmpty
                  ? saved
                  : incoming
            : incoming.isNotEmpty
            ? incoming
            : saved;
        if (title.isNotEmpty) names[episode] = title;
      }
      resolved = DirectoryCollection(
        title: '${donor.data['series'] ?? value.title}',
        season: '${donor.data['season'] ?? value.season}',
        videos: value.videos,
        identities: {
          for (final entry in value.videos)
            entry.path: ReleaseName(
              '${donor.data['series'] ?? value.title}',
              '${donor.data['season'] ?? value.season}',
              value.identities[entry.path]?.episode ?? '',
            ),
        },
        subject: sameSubject && !evidence.manual
            ? {...mediaFieldsSubject(donor.data), ...value.subject!}
            : mediaFieldsSubject(donor.data),
        episodeTitles: names,
        episodeCount: value.episodeCount,
      );
    } else if (keys.length > 1) {
      resolved = value.withMetadata(null, {});
    }
    var changed = false;
    final ids = <String>[];
    final imported = <String>[];
    for (final entry in resolved.videos) {
      var record = _sourceRecord(store, sourceId, entry.path);
      if (record == null) {
        if (!(importMissing ?? resolved.subject != null) ||
            store.local(_exclusionKey(sourceId, entry.path)) == true) {
          continue;
        }
        final id = const Uuid().v4();
        final identity =
            resolved.identities[entry.path] ?? _mediaIdentity(entry);
        store.save('media', id, {
          'title': entry.name,
          'fileName': entry.name,
          'series': identity.anime.isEmpty ? '未分类' : identity.anime,
          'season': identity.season,
          'episode': identity.episode,
          'size': entry.size,
          'duration': 0,
          if (sourceId == 'local') 'localOnly': true,
        });
        store.setLocal('location:$id', {
          'id': id,
          'source': sourceId,
          'path': entry.path,
          'size': entry.size,
          'modified': entry.modified,
        });
        record = store.get('media', id)!;
        imported.add(id);
        changed = true;
      }
      if (adoptBrowsingMediaPreview(store, sourceId, entry.path, record.id)) {
        changed = true;
      }
      ids.add(record.id);
      if (store.local('manualMetadata:${record.id}') == true) continue;
      if (keys.length > 1 &&
          (record.data['tmdbId'] != null || record.data['bangumiId'] != null)) {
        continue;
      }
      final identity = resolved.identities[entry.path];
      if (identity == null) continue;
      final data = {...record.data};
      final subject = resolved.subject;
      if (subject != null) {
        final incoming = subjectMediaFields(subject);
        final oldId = data['tmdbId'] ?? data['bangumiId'];
        if (oldId != null &&
            (data['tmdbId'] != incoming['tmdbId'] ||
                data['bangumiId'] != incoming['bangumiId'] ||
                (data['tmdbId'] != null &&
                    (data['metadataType'] ?? 'tv') !=
                        incoming['metadataType']))) {
          continue;
        }
        data.remove('tmdbId');
        data.remove('bangumiId');
        data.addAll(incoming);
      }
      final title = resolved.episodeTitle(entry.path);
      data.addAll({
        'series': identity.anime,
        'season': identity.season,
        'episode': identity.episode,
        if (title.isNotEmpty) 'episodeTitle': title,
      });
      if (!_equalJson(data, record.data)) {
        store.save('media', record.id, data);
        changed = true;
      }
      if (title.isNotEmpty &&
          store.local('episodeTitle:${record.id}') != title) {
        store.setLocal('episodeTitle:${record.id}', title);
        changed = true;
      }
    }
    if (imported.isNotEmpty) {
      final key = sourceId == 'local'
          ? 'syncProfile:localMedia'
          : 'syncProfile:remoteMedia';
      final bindings = {
        ...(store.local(key) as List? ?? const []).whereType<String>(),
        ...imported,
      };
      store.setLocal(key, bindings.toList());
    }
    result = DirectoryMetadataResult(resolved, changed, List.unmodifiable(ids));
    donorCache?._checkpoint(store);
  });
  return result;
}

/// Parse and sort the source listing on the same worker that owns the writes.
/// A series may share its folder with a trailer or another show. In that case
/// use the selected episode's original filename as evidence, instead of making
/// every episode depend on the entire folder passing identifyDirectory.
Future<DirectoryMetadataResult?> synchronizeDirectoryListing(
  AppStore store,
  String sourceId,
  String path,
  List<SourceEntry> entries, {
  required bool hideHidden,
  String? anchorId,
  CancelToken? cancel,
}) async {
  cancel?.check();
  final visible = entries
      .where((entry) => !hideHidden || !isHiddenEntry(entry))
      .toList();
  final anchor = anchorId == null ? null : store.get('media', anchorId);
  final location = anchorId == null ? null : store.local('location:$anchorId');
  if (anchorId != null &&
      (anchor == null ||
          anchor.deleted ||
          location is! Map ||
          location['source'] != sourceId ||
          !visible.any((entry) => entry.path == location['path']))) {
    return null;
  }
  // A season-only directory (S01 / 第1季) contributes no series title. Once
  // one file has been identified, its identity is evidence for the numeric
  // siblings; requiring a title in every filename loses those episodes.
  final folderIdentity = sourceDirectoryIdentity(store, sourceId, path);
  final originalIdentity = parseReleaseName(
    '${anchor?.data['fileName'] ?? anchor?.data['title'] ?? ''}',
  );
  final anchoredFolder =
      folderIdentity.anime.isEmpty &&
          anchor != null &&
          anchor.data['metadataType'] != 'movie' &&
          (anchor.data['tmdbId'] != null || anchor.data['bangumiId'] != null) &&
          normalizedSeries('${anchor.data['series'] ?? ''}').isNotEmpty &&
          anchor.data['series'] != '未分类'
      ? ReleaseName(
          originalIdentity.episode.isNotEmpty &&
                  originalIdentity.anime.isNotEmpty
              ? originalIdentity.anime
              : '${anchor.data['series']}',
          '${anchor.data['season'] ?? folderIdentity.season}',
        )
      : null;
  final verifiedAnchor =
      anchor?.data['tmdbId'] != null || anchor?.data['bangumiId'] != null;
  // A named anchor can complete numeric siblings even when the folder was
  // renamed or the source is rooted at S02. identifyDirectory can return just
  // the named files in that case, so anchored details must inspect every file.
  var collection = anchorId == null
      ? identifyDirectory(path, visible, folderIdentity: folderIdentity)
      : null;
  if (collection == null && anchorId != null) {
    if (anchor == null || anchor.deleted || location is! Map) return null;
    final originalEvidence = _mediaIdentity(
      SourceEntry(
        name: '${anchor.data['fileName'] ?? anchor.data['title'] ?? ''}',
        path: '${location['path']}',
      ),
      fallback: anchoredFolder ?? folderIdentity,
    );
    final evidence = ReleaseName(
      originalEvidence.anime,
      originalEvidence.season.isNotEmpty
          ? originalEvidence.season
          : '${anchor.data['season'] ?? ''}',
      originalEvidence.episode,
    );
    String season(String value) => value.isEmpty ? '1' : value;
    final key = normalizedSeries(evidence.anime);
    if (key.isEmpty ||
        (evidence.episode.isEmpty &&
            '${anchor.data['episode'] ?? ''}'.isEmpty)) {
      return null;
    }
    final titles = <String>{
      key,
      if (verifiedAnchor) normalizedSeries('${anchor.data['series'] ?? ''}'),
      if (verifiedAnchor)
        normalizedSeries('${anchor.data['metadataTitle'] ?? ''}'),
    }..remove('');
    final bareEpisode = RegExp(
      r'^(?:EP?)?(\d{1,4})(?:[ ._-].*)?$',
      caseSensitive: false,
    );
    final videos = <SourceEntry>[];
    final identities = <String, ReleaseName>{};
    for (var index = 0; index < visible.length; index++) {
      if (index % 128 == 0) {
        await Future<void>.delayed(Duration.zero);
        cancel?.check();
      }
      final entry = visible[index];
      if (entry.directory || !isVideo(entry.name)) continue;
      final existing = _sourceRecord(store, sourceId, entry.path);
      final verified =
          existing != null &&
          (existing.data['tmdbId'] != null ||
              existing.data['bangumiId'] != null);
      if (verified && mediaSeriesKey(existing) != mediaSeriesKey(anchor)) {
        continue;
      }
      final parsed = parseReleaseName(entry.name);
      final bare = parsed.episode.isEmpty
          ? bareEpisode.firstMatch(p.basenameWithoutExtension(entry.name))
          : null;
      final episode = verified
          ? '${existing.data['episode'] ?? parsed.episode}'
          : bare == null
          ? parsed.episode
          : '${int.parse(bare[1]!)}';
      final fileSeason = parsed.season.isNotEmpty
          ? parsed.season
          : folderIdentity.season.isNotEmpty
          ? folderIdentity.season
          : evidence.season;
      // Numeric and title-less filenames get their work from the selected
      // episode, not the folder's display name. Named files still need title
      // evidence; a verified sibling supplies its own authoritative identity.
      if (episode.isEmpty ||
          (!verified &&
              ((bare == null &&
                      parsed.anime.isNotEmpty &&
                      !titles.contains(normalizedSeries(parsed.anime))) ||
                  season(fileSeason) != season(evidence.season)))) {
        continue;
      }
      videos.add(entry);
      identities[entry.path] = ReleaseName(
        evidence.anime,
        evidence.season,
        episode,
      );
    }
    if (videos.isNotEmpty) {
      collection = DirectoryCollection(
        title: evidence.anime,
        season: evidence.season,
        videos: videos,
        identities: identities,
        episodeCount: identities.values
            .map((value) => value.episode)
            .toSet()
            .length,
      );
    }
  }
  // A manual or synced match can identify files whose basenames carry no
  // useful episode information. Reuse those verified identities on first
  // open, before playback can trigger a separate model refresh. Require every
  // listed video to belong to the same work/season; an unknown or conflicting
  // file must not inherit its neighbours' metadata.
  if (collection == null && anchorId == null) {
    collection = await _identifiedDirectoryCollection(
      store,
      sourceId,
      visible,
      cancel,
    );
  }
  if (collection == null) return null;
  final donors = DirectoryMetadataDonorCache(sourceId, collection.videos);
  final ids = <String>[];
  final identities = <String, ReleaseName>{};
  final names = <String, String>{};
  var changed = false;
  var resolved = collection;
  for (var offset = 0; offset < collection.videos.length; offset += 128) {
    await Future<void>.delayed(Duration.zero);
    cancel?.check();
    if (anchorId != null && store.get('media', anchorId)?.deleted != false) {
      break;
    }
    final batch = collection.videos.skip(offset).take(128).toList();
    final result = await retryStoreBusy(() {
      cancel?.check();
      return synchronizeDirectoryCollection(
        store,
        sourceId,
        DirectoryCollection(
          title: collection!.title,
          season: collection.season,
          videos: batch,
          identities: collection.identities,
          subject: collection.subject,
          episodeTitles: collection.episodeTitles,
          episodeCount: collection.episodeCount,
        ),
        importMissing: true,
        anchorId: anchorId,
        donorCache: donors,
      );
    });
    changed |= result.changed;
    ids.addAll(result.mediaIds);
    resolved = result.collection;
    identities.addAll(resolved.identities);
    names.addAll(resolved.episodeTitles);
  }
  cancel?.check();
  return DirectoryMetadataResult(
    DirectoryCollection(
      title: resolved.title,
      season: resolved.season,
      videos: collection.videos,
      identities: {...collection.identities, ...identities},
      subject: resolved.subject,
      episodeTitles: names,
      episodeCount: collection.episodeCount,
    ),
    changed,
    List.unmodifiable(ids),
  );
}

Future<DirectoryCollection?> _identifiedDirectoryCollection(
  AppStore store,
  String sourceId,
  List<SourceEntry> entries,
  CancelToken? cancel,
) async {
  final videos = <SourceEntry>[];
  final identities = <String, ReleaseName>{};
  final names = <String, String>{};
  SyncRecord? first;
  String? seriesKey;
  for (var index = 0; index < entries.length; index++) {
    if (index % 128 == 0) {
      await Future<void>.delayed(Duration.zero);
      cancel?.check();
    }
    final entry = entries[index];
    if (entry.directory || !isVideo(entry.name)) continue;
    final record = _sourceRecord(store, sourceId, entry.path);
    if (record == null ||
        (record.data['bangumiId'] == null && record.data['tmdbId'] == null)) {
      return null;
    }
    final key = mediaSeriesKey(record);
    if (seriesKey != null && seriesKey != key) return null;
    seriesKey = key;
    first ??= record;
    final episode = '${record.data['episode'] ?? ''}';
    videos.add(entry);
    identities[entry.path] = ReleaseName(
      '${first.data['series'] ?? ''}',
      '${first.data['season'] ?? ''}',
      episode,
    );
    final name = _episodeTitle(store, record);
    if (name.isNotEmpty) names[episode] = name;
  }
  if (first == null) return null;
  return DirectoryCollection(
    title: '${first.data['series'] ?? ''}',
    season: '${first.data['season'] ?? ''}',
    videos: videos,
    identities: identities,
    subject: mediaFieldsSubject(first.data),
    episodeTitles: names,
    episodeCount: identities.values
        .map((identity) => identity.episode)
        .where((episode) => episode.isNotEmpty)
        .toSet()
        .length,
  );
}

ReleaseName _mediaIdentity(SourceEntry entry, {ReleaseName? fallback}) {
  var folder = directoryIdentity(
    p.posix.dirname(entry.path.replaceAll('\\', '/')),
  );
  if (folder.anime.isEmpty && fallback != null) folder = fallback;
  var guess = parseReleaseName(entry.name);
  if (guess.episode.isEmpty && folder.anime.isNotEmpty) {
    final bare = RegExp(
      r'^(?:EP?)?(\d{1,4})(?:[ ._-].*)?$',
      caseSensitive: false,
    ).firstMatch(p.basenameWithoutExtension(entry.name));
    if (bare != null) {
      guess = ReleaseName(
        folder.anime,
        folder.season,
        '${int.parse(bare[1]!)}',
      );
    }
  }
  final compatible =
      guess.anime.isEmpty ||
      normalizedSeries(guess.anime) == normalizedSeries(folder.anime);
  return ReleaseName(
    guess.anime.isEmpty ? folder.anime : guess.anime,
    guess.season.isNotEmpty
        ? guess.season
        : compatible
        ? folder.season
        : '',
    guess.episode,
  );
}

class DirectoryRecognitionProgress {
  final int folders, videos, matched, failed;
  const DirectoryRecognitionProgress({
    this.folders = 0,
    this.videos = 0,
    this.matched = 0,
    this.failed = 0,
  });
}

/// A reusable isolate owns both the independent SQLite connection and recursive
/// source enumeration. Browsing updates remain available while a scan awaits IO.
class DirectoryMetadataWorker {
  final String databasePath;
  final _messages = ReceivePort(),
      _errors = ReceivePort(),
      _exit = ReceivePort();
  final _ready = Completer<SendPort>(), _closed = Completer<void>();
  final _pending = <int, Completer<dynamic>>{};
  final _progress = <int, void Function(DirectoryRecognitionProgress)>{};
  SendPort? _commands;
  int _serial = 0;
  bool _closing = false;
  DirectoryMetadataWorker(this.databasePath) {
    _messages.listen((dynamic message) {
      if (message is SendPort) {
        _commands = message;
        _ready.complete(message);
        if (_closing) message.send(['close']);
        return;
      }
      final row = message as List;
      final id = row[1] as int;
      if (row[0] == 'progress') {
        _progress[id]?.call(row[2] as DirectoryRecognitionProgress);
      } else if (row[0] == 'result') {
        _pending.remove(id)?.complete(row[2]);
        _progress.remove(id);
      } else if (row[0] == 'failure') {
        _pending
            .remove(id)
            ?.completeError(
              row[2] == 'cancelled'
                  ? const Cancelled()
                  : AppFailure(row[3] as String),
            );
        _progress.remove(id);
      }
    });
    void stopped() {
      _closing = true;
      final error = const Cancelled();
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final value in _pending.values) {
        value.completeError(error);
      }
      _pending.clear();
      _progress.clear();
      _messages.close();
      _errors.close();
      _exit.close();
      if (!_closed.isCompleted) _closed.complete();
    }

    _errors.listen((_) => stopped());
    _exit.listen((_) => stopped());
    unawaited(
      Isolate.spawn(
        _directoryWorkerMain,
        [databasePath, _messages.sendPort],
        onError: _errors.sendPort,
        onExit: _exit.sendPort,
      ).then<void>((_) {}, onError: (Object _, StackTrace _) => stopped()),
    );
  }

  Future<T> _call<T>(
    String operation,
    List<dynamic> values, {
    CancelToken? cancel,
    void Function(DirectoryRecognitionProgress)? onProgress,
  }) async {
    if (_closing) throw const Cancelled();
    if (_pending.length >= 32) throw const AppFailure('后台目录任务繁忙，请稍后重试。');
    final commands = await _ready.future;
    cancel?.check();
    if (_closing) throw const Cancelled();
    if (_pending.length >= 32) throw const AppFailure('后台目录任务繁忙，请稍后重试。');
    final id = ++_serial;
    final result = Completer<dynamic>();
    _pending[id] = result;
    if (onProgress != null) _progress[id] = onProgress;
    commands.send([operation, id, ...values]);
    unawaited(
      cancel?.whenCancelled.then((_) {
        if (_pending.containsKey(id)) commands.send(['cancel', id]);
      }),
    );
    return (await result.future) as T;
  }

  Future<DirectoryMetadataResult> synchronize(
    String sourceId,
    DirectoryCollection collection, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) => _call('synchronize', [
    sourceId,
    collection,
    importMissing,
    anchorId,
  ], cancel: cancel);

  Future<DirectoryInspection> prepareInspection(
    String sourceId,
    String path,
    String context,
    List<SourceEntry> entries, {
    CancelToken? cancel,
  }) => _call('inspect', [sourceId, path, context, entries], cancel: cancel);

  Future<void> persistPreview(
    String sourceId,
    String path,
    DirectoryPreview preview, {
    CancelToken? cancel,
  }) => _call('preview', [sourceId, path, preview], cancel: cancel);

  Future<bool> episodeNamesCovered(
    Map<String, ReleaseName> identities,
    Map<String, String> names, {
    CancelToken? cancel,
  }) => _call('episodeCoverage', [identities, names], cancel: cancel);

  Future<DirectoryPreview?> readPreview(
    String sourceId,
    String path, {
    CancelToken? cancel,
  }) => _call('readPreview', [sourceId, path], cancel: cancel);

  Future<DirectoryMetadataResult?> synchronizeListing(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    required bool hideHidden,
    String? anchorId,
    CancelToken? cancel,
  }) => _call('listing', [
    sourceId,
    path,
    entries,
    hideHidden,
    anchorId,
  ], cancel: cancel);

  Future<DirectoryRecognitionProgress> recognize(
    String sourceId,
    String root, {
    required Map<String, dynamic> source,
    required String password,
    required String tmdbCredential,
    required bool hideHidden,
    required String strategy,
    required CancelToken cancel,
    void Function(DirectoryRecognitionProgress)? onProgress,
  }) => _call(
    'recognize',
    [sourceId, root, source, password, tmdbCredential, hideHidden, strategy],
    cancel: cancel,
    onProgress: onProgress,
  );

  Future<bool> persistEpisodeNames(
    SyncRecord anchor,
    Map<String, dynamic> subject,
    Map<String, String> names, {
    Set<String>? mediaIds,
    CancelToken? cancel,
  }) =>
      _call('episodeNames', [anchor, subject, names, mediaIds], cancel: cancel);

  Future<void> close() {
    if (!_closing) {
      _closing = true;
      _commands?.send(['close']);
    }
    return _closed.future;
  }
}

void _directoryWorkerMain(List<dynamic> startup) async {
  final store = await retryStoreBusy(
    () => AppStore.openExisting(startup[0] as String),
  );
  final reply = startup[1] as SendPort;
  final commands = ReceivePort();
  final active = <int, CancelToken>{};
  var scanning = false, closing = false;
  void finishClose() {
    if (!closing || active.isNotEmpty) return;
    store.dispose();
    commands.close();
  }

  commands.listen((dynamic message) async {
    final row = message as List;
    if (row[0] == 'close') {
      closing = true;
      for (final token in active.values) {
        token.cancel();
      }
      finishClose();
      return;
    }
    final id = row[1] as int;
    if (row[0] == 'cancel') {
      active[id]?.cancel();
      return;
    }
    final cancel = active[id] = CancelToken();
    try {
      if (closing) throw const Cancelled();
      dynamic result;
      if (row[0] == 'inspect') {
        await Future<void>.delayed(Duration.zero);
        cancel.check();
        result = prepareDirectoryInspection(
          row[2] as String,
          row[3] as String,
          row[4] as String,
          row[5] as List<SourceEntry>,
          folderIdentity: sourceDirectoryIdentity(
            store,
            row[2] as String,
            row[3] as String,
          ),
        );
      } else if (row[0] == 'episodeCoverage') {
        cancel.check();
        result = directoryEpisodeNamesCovered(
          row[2] as Map<String, ReleaseName>,
          row[3] as Map<String, String>,
        );
      } else if (row[0] == 'readPreview') {
        await Future<void>.delayed(Duration.zero);
        cancel.check();
        result = readDirectoryPreview(
          store,
          row[2] as String,
          row[3] as String,
        );
      } else if (row[0] == 'preview') {
        await Future<void>.delayed(Duration.zero);
        cancel.check();
        await retryStoreBusy(() {
          cancel.check();
          persistDirectoryPreview(
            store,
            row[2] as String,
            row[3] as String,
            row[4] as DirectoryPreview,
          );
        });
      } else if (row[0] == 'synchronize') {
        // Give cancellation already queued at the command port a chance before
        // beginning this atomic transaction, whose work stays off the UI thread.
        await Future<void>.delayed(Duration.zero);
        cancel.check();
        result = await retryStoreBusy(() {
          cancel.check();
          return synchronizeDirectoryCollection(
            store,
            row[2] as String,
            row[3] as DirectoryCollection,
            importMissing: row[4] as bool?,
            anchorId: row[5] as String?,
          );
        });
      } else if (row[0] == 'listing') {
        await Future<void>.delayed(Duration.zero);
        result = await synchronizeDirectoryListing(
          store,
          row[2] as String,
          row[3] as String,
          row[4] as List<SourceEntry>,
          hideHidden: row[5] as bool,
          anchorId: row[6] as String?,
          cancel: cancel,
        );
      } else if (row[0] == 'episodeNames') {
        await Future<void>.delayed(Duration.zero);
        result = await retryStoreBusy(() {
          cancel.check();
          return persistDirectoryEpisodeNames(
            store,
            row[2] as SyncRecord,
            row[3] as Map<String, dynamic>,
            row[4] as Map<String, String>,
            mediaIds: row[5] as Set<String>?,
          );
        });
      } else {
        if (scanning) throw const AppFailure('已有目录正在识别，请等待完成。');
        scanning = true;
        try {
          result = await recognizeDirectoryTree(
            store,
            row[2] as String,
            row[3] as String,
            source: row[4] as Map<String, dynamic>,
            password: row[5] as String,
            tmdbCredential: row[6] as String,
            hideHidden: row[7] as bool,
            strategy: row[8] as String,
            cancel: cancel,
            onProgress: (progress) => reply.send(['progress', id, progress]),
          );
        } finally {
          scanning = false;
        }
      }
      cancel.check();
      reply.send(['result', id, result]);
    } catch (error) {
      reply.send([
        'failure',
        id,
        error is Cancelled ? 'cancelled' : 'error',
        safeFailure(error).message,
      ]);
    } finally {
      active.remove(id);
      finishClose();
    }
  });
  reply.send(commands.sendPort);
}

/// One source connection, one directory request and one catalogue lookup group
/// at a time. Committed directories remain useful if the user cancels later.
Future<DirectoryRecognitionProgress> recognizeDirectoryTree(
  AppStore store,
  String sourceId,
  String root, {
  required Map<String, dynamic> source,
  required String password,
  required String tmdbCredential,
  required bool hideHidden,
  required String strategy,
  required CancelToken cancel,
  void Function(DirectoryRecognitionProgress)? onProgress,
  SourceAdapter? adapter,
  LibraryCatalog? catalog,
}) async {
  SourceAdapter? connection = adapter;
  var folders = 0, videos = 0, matched = 0, failed = 0;
  DirectoryRecognitionProgress progress() => DirectoryRecognitionProgress(
    folders: folders,
    videos: videos,
    matched: matched,
    failed: failed,
  );
  final service =
      catalog ??
      LibraryCatalog(
        store,
        provider: () =>
            (store.local('settings') as Map?)?['metadataProvider'] as String? ??
            'bangumi',
        tmdbNameAssist: () =>
            (store.local('settings') as Map?)?['tmdbNameAssist'] != false,
        strategy: () => strategy,
        tmdbCredential: () async => tmdbCredential,
      );
  var finished = false;
  unawaited(
    cancel.whenCancelled.then((_) {
      if (!finished) unawaited(connection?.close().catchError((Object _) {}));
    }),
  );
  try {
    cancel.check();
    connection ??= sourceId == 'local'
        ? LocalSource()
        : await connectSource(source, password: password);
    final queue = <String>[root], seen = <String>{}, queued = <String>{};
    String normalize(String path) =>
        p.posix.normalize(path.replaceAll('\\', '/'));
    // Source adapters return paths in their own coordinate system. WebDAV
    // entries are relative to its configured URL even at the empty root; URL
    // paths here would reject every relative child as outside the subtree.
    final normalizedRoot = normalize(root);
    final sourceUri = source['kind'] == 'webdav'
        ? Uri.tryParse('${source['url'] ?? ''}')
        : null;
    final identityRoot = sourceUri == null
        ? ''
        : '/${sourceUri.pathSegments.join('/')}';
    bool within(String parent, String child) => parent == '.'
        ? child != '.' &&
              child != '..' &&
              !child.startsWith('../') &&
              !p.posix.isAbsolute(child)
        : p.posix.isWithin(parent, child);
    queued.add(normalizedRoot);
    while (queue.isNotEmpty) {
      cancel.check();
      final path = queue.removeLast();
      final normalized = path.isEmpty ? normalizedRoot : normalize(path);
      if (!seen.add(normalized)) continue;
      if (seen.length > 100000) throw const AppFailure('目录过多，请选择更小的文件夹。');
      List<SourceEntry>? entries;
      for (var attempt = 0; attempt < 3; attempt++) {
        cancel.check();
        try {
          entries = await connection.list(path);
          break;
        } catch (_) {
          cancel.check();
          if (attempt == 2) {
            failed++;
            break;
          }
          await Future.any([
            Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1))),
            cancel.whenCancelled,
          ]);
        }
      }
      cancel.check();
      if (entries == null) {
        onProgress?.call(progress());
        continue;
      }
      folders++;
      final visible = <SourceEntry>[];
      for (final entry in entries) {
        if (hideHidden && isHiddenEntry(entry)) continue;
        final child = normalize(entry.path);
        // Ignore parent/self aliases and paths outside the requested subtree.
        if (!within(normalizedRoot, child) || !within(normalized, child)) {
          continue;
        }
        if (entry.directory) {
          if (!seen.contains(child) && queued.add(child)) {
            if (queue.length >= 4096) throw const AppFailure('子文件夹过多，请分批识别。');
            queue.add(entry.path);
          }
        } else if (isVideo(entry.name)) {
          visible.add(entry);
        }
      }
      final folderIdentity = directoryIdentity(path, rootPath: identityRoot);
      final identified = identifyDirectory(
        path,
        visible,
        folderIdentity: folderIdentity,
      );
      final groups = <String, List<SourceEntry>>{};
      final identities = <String, ReleaseName>{};
      for (final entry in visible) {
        final identity =
            identified?.identities[entry.path] ??
            _mediaIdentity(entry, fallback: folderIdentity);
        identities[entry.path] = identity;
        (groups['${normalizedSeries(identity.anime)}:${identity.season}'] ??=
                [])
            .add(entry);
      }
      for (final group in groups.values) {
        cancel.check();
        final identity = identities[group.first.path]!;
        var collection = DirectoryCollection(
          title: identity.anime,
          season: identity.season,
          videos: group,
          identities: {
            for (final entry in group) entry.path: identities[entry.path]!,
          },
          episodeCount: {
            for (final entry in group)
              if (identities[entry.path]!.episode.isNotEmpty)
                identities[entry.path]!.episode,
          }.length,
        );
        try {
          final subject = await service.resolve(
            identity.anime,
            identity.season,
            cancel: cancel,
            force: true,
          );
          cancel.check();
          if (subject != null) {
            collection = collection.withMetadata(subject, const {});
            final names = await service.episodeNames(
              '${subject['id']}',
              subject: subject,
              cancel: cancel,
            );
            cancel.check();
            collection = collection.withMetadata(subject, names);
          }
        } on Cancelled {
          rethrow;
        } catch (_) {
          failed++;
        }
        // A giant single series still commits only bounded batches. Reuse the
        // full group's evidence until an external edit invalidates its snapshot.
        final donorCache = DirectoryMetadataDonorCache(sourceId, group);
        for (var offset = 0; offset < group.length; offset += 128) {
          await Future<void>.delayed(Duration.zero);
          cancel.check();
          final batch = group.skip(offset).take(128).toList();
          final result = await retryStoreBusy(() {
            cancel.check();
            return synchronizeDirectoryCollection(
              store,
              sourceId,
              DirectoryCollection(
                title: collection.title,
                season: collection.season,
                videos: batch,
                identities: collection.identities,
                subject: collection.subject,
                episodeTitles: collection.episodeTitles,
                episodeCount: collection.episodeCount,
              ),
              importMissing: true,
              donorCache: donorCache,
            );
          });
          // Excluded files still exist in the folder. Count discovery
          // independently from importing so they cannot become "no videos".
          videos += batch.length;
          if (result.collection.subject != null) {
            matched += result.mediaIds.length;
          }
          onProgress?.call(progress());
        }
      }
      onProgress?.call(progress());
    }
    return progress();
  } finally {
    finished = true;
    try {
      await connection?.close();
    } catch (_) {
      /* cancellation closes IO */
    }
  }
}
