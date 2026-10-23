import 'dart:convert';
import 'dart:async';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/network.dart';
import '../danmaku/release_name.dart';
import '../sources/source.dart';
import 'store.dart';
import 'catalog_cache.dart';
import 'media_presentation.dart';
import 'tmdb_catalog.dart';

String normalizedSeries(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[\s\p{P}\p{S}]', unicode: true),
  '',
);

/// A season belongs to its own Bangumi subject. Never reuse a first-season
/// poster just because the series title matches a later season's filename.
ReleaseName subjectIdentity(String name) {
  var value = name.trim();
  final numeric = RegExp(
    r'\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s+Season)?$',
    caseSensitive: false,
  ).firstMatch(value);
  if (numeric != null) {
    return ReleaseName(
      value.substring(0, numeric.start).trim(),
      '${int.parse(numeric[1]!)}',
    );
  }
  final roman = RegExp(
    r'\s+(II|III|IV|V|VI)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (roman != null) {
    const numbers = {'II': '2', 'III': '3', 'IV': '4', 'V': '5', 'VI': '6'};
    return ReleaseName(
      value.substring(0, roman.start).trim(),
      numbers[roman[1]!.toUpperCase()]!,
    );
  }
  return parseReleaseName(value);
}

/// A season directory carries the season, while its parent carries the title.
/// This evidence is available before any file has been played or identified.
ReleaseName directoryIdentity(String path, {String rootPath = ''}) {
  final relative = path.replaceAll('\\', '/');
  final fullPath = p.posix.normalize(
    rootPath.isEmpty
        ? relative
        : p.posix.join(rootPath, relative.replaceFirst(RegExp(r'^/+'), '')),
  );
  final name = p.posix.basename(fullPath);
  if (name == '.' || name == '/' || name.isEmpty) return const ReleaseName('');
  final parsed = parseReleaseName(name);
  if (parsed.anime.isNotEmpty || parsed.season.isEmpty) {
    return subjectIdentity(name);
  }
  final parent = p.posix.dirname(fullPath);
  if (parent == '.' || parent == '/' || parent == fullPath) return parsed;
  final parentName = p.posix.basename(parent);
  final parentIdentity = parseReleaseName(parentName);
  if (parentIdentity.anime.isEmpty) return parsed;
  return ReleaseName(subjectIdentity(parentName).anime, parsed.season);
}

/// Called on the directory worker (or an in-memory test store). A WebDAV root
/// listing uses relative paths, so recover its directory name from the source
/// URL without changing file locations, cache keys or navigation paths.
ReleaseName sourceDirectoryIdentity(
  AppStore store,
  String sourceId,
  String path,
) {
  final sources = store.local('sources');
  final source = sources is List
      ? sources
            .whereType<Map>()
            .where((value) => value['id'] == sourceId)
            .firstOrNull
      : null;
  final uri = source?['kind'] == 'webdav'
      ? Uri.tryParse('${source?['url'] ?? ''}')
      : null;
  return directoryIdentity(
    path,
    rootPath: uri == null ? '' : '/${uri.pathSegments.join('/')}',
  );
}

bool subjectMatchesSeason(
  String title,
  String season,
  Map<String, dynamic> subject, {
  bool balanced = false,
}) {
  final expected = normalizedSeries(title);
  if (expected.isEmpty) return false;
  final seasons = <String>{};
  var nameMatches = false;
  for (final name in [
    subject['name'],
    subject['name_cn'],
  ].whereType<String>()) {
    final identity = subjectIdentity(name);
    if (identity.season.isNotEmpty) seasons.add(identity.season);
    final candidate = normalizedSeries(identity.anime);
    if (candidate == expected ||
        normalizedSeries(name) == expected ||
        (balanced &&
            expected.length >= 5 &&
            candidate.length >= 5 &&
            (expected.startsWith(candidate) ||
                candidate.startsWith(expected)) &&
            expected.length / candidate.length > .85 &&
            expected.length / candidate.length < 1.18)) {
      nameMatches = true;
    }
  }
  if (!nameMatches) return false;
  if (season.isEmpty || season == '1') {
    return seasons.isEmpty || seasons.every((s) => s == '1');
  }
  return seasons.length == 1 && seasons.single == season;
}

class DirectoryCollection {
  final String title, season;
  final List<SourceEntry> videos;
  final Map<String, ReleaseName> identities;
  final Map<String, dynamic>? subject;
  final Map<String, String> episodeTitles;

  /// False when a transient catalogue failure left only partial metadata.
  /// The available subject can be shown while the missing stage is retried.
  final bool metadataComplete;
  final int? _preparedEpisodeCount;
  const DirectoryCollection({
    required this.title,
    required this.season,
    required this.videos,
    required this.identities,
    this.subject,
    this.episodeTitles = const {},
    this.metadataComplete = true,
    int? episodeCount,
  }) : _preparedEpisodeCount = episodeCount;
  String get displayName =>
      '${subject?['name_cn']?.toString().isNotEmpty == true ? subject!['name_cn'] : subject?['name'] ?? title}';
  String get poster =>
      '${subject?['images']?['large'] ?? subject?['images']?['common'] ?? ''}';
  String get summary => '${subject?['summary'] ?? ''}';
  int get episodeCount =>
      _preparedEpisodeCount ??
      identities.values
          .map((item) => item.episode)
          .where((episode) => episode.isNotEmpty)
          .toSet()
          .length;
  String get seasonLabel =>
      mediaSeasonLabel(season, totalSeasons: subject?['total_seasons']);
  List<String> get metadataLabels {
    final score = num.tryParse('${subject?['rating']?['score']}');
    final episodes =
        subject?['season_episodes'] ??
        subject?['total_episodes'] ??
        subject?['eps'];
    final date = '${subject?['date'] ?? ''}';
    return [
      if (score != null && score > 0) '评分 ${score.toStringAsFixed(1)}',
      if (seasonLabel.isNotEmpty) seasonLabel,
      if (episodes is num && episodes > 0) '共 $episodes 集',
      if (date.length >= 4) date.substring(0, 4),
    ];
  }

  String episodeTitle(String path) =>
      episodeTitles[identities[path]?.episode] ?? '';
  String episodeLabel(String path) {
    final identity = identities[path];
    final ep = identity?.episode ?? '';
    final label = ep.isEmpty
        ? ''
        : '${seasonLabel.isEmpty ? '' : '$seasonLabel · '}第 $ep 集';
    final name = episodeTitle(path);
    return '$label${name.isEmpty ? '' : ' · $name'}';
  }

  DirectoryCollection withMetadata(
    Map<String, dynamic>? value,
    Map<String, String> names, {
    bool metadataComplete = true,
  }) => DirectoryCollection(
    title: title,
    season: season,
    videos: videos,
    identities: identities,
    subject: value,
    episodeTitles: names,
    metadataComplete: metadataComplete,
    episodeCount: _preparedEpisodeCount,
  );
}

/// Run on the directory worker when checking a production collection. Numeric
/// episode keys, rather than map size, detect gaps and alternate encodes.
bool directoryEpisodeNamesCovered(
  Map<String, ReleaseName> identities,
  Map<String, String> names,
) {
  for (final identity in identities.values) {
    final number = int.tryParse(identity.episode);
    if (number != null && (names['$number'] ?? '').trim().isEmpty) {
      return false;
    }
  }
  return true;
}

/// A short-lived directory preview can be rendered synchronously when a browser
/// is reopened. The real directory is still listed whenever the user enters it.
class DirectoryPreview {
  final DirectoryCollection? collection;
  final String context, fingerprint;
  final int updatedAt, modified, cacheEpoch, sourceEpoch;
  final bool complete;
  const DirectoryPreview({
    required this.collection,
    required this.context,
    required this.fingerprint,
    required this.updatedAt,
    required this.modified,
    this.cacheEpoch = 0,
    this.sourceEpoch = 0,
    this.complete = true,
  });
}

String _directoryPreviewKey(String sourceId, String path) =>
    'directory-preview:${sha256.convert(utf8.encode(jsonEncode([sourceId, p.posix.normalize(path.replaceAll('\\', '/'))])))}';

String _directoryEnvelopeKey(String key) =>
    key.replaceFirst('directory-preview:', 'directory-preview-envelope:');

int _directoryPreviewEpoch(AppStore store) =>
    (store.local('directoryPreviewEpoch') as num?)?.toInt() ?? 0;

int _directorySourceEpoch(AppStore store, String sourceId) =>
    (store.local('directoryPreviewSourceEpoch:$sourceId') as num?)?.toInt() ??
    0;

/// Called by the directory worker so a large cached collection never encodes
/// JSON or waits for the SQLite write lock on the UI isolate.
void persistDirectoryPreview(
  AppStore store,
  String sourceId,
  String path,
  DirectoryPreview preview,
) {
  store.transaction(() {
    // An explicit cache refresh can happen while this write is queued.
    if (preview.cacheEpoch != _directoryPreviewEpoch(store) ||
        preview.sourceEpoch != _directorySourceEpoch(store, sourceId)) {
      return;
    }
    final collection = preview.collection;
    final key = _directoryPreviewKey(sourceId, path);
    final data = <String, dynamic>{
      'sourceId': sourceId,
      'context': preview.context,
      'fingerprint': preview.fingerprint,
      'at': preview.updatedAt,
      'modified': preview.modified,
      'epoch': preview.cacheEpoch,
      'sourceEpoch': preview.sourceEpoch,
      'collection': collection == null
          ? null
          : {
              'title': collection.title,
              'season': collection.season,
              'episodeCount': collection.episodeCount,
              'videos': [
                for (final entry in collection.videos)
                  {
                    'name': entry.name,
                    'path': entry.path,
                    'size': entry.size,
                    'modified': entry.modified,
                    'hidden': entry.hidden,
                  },
              ],
              'identities': {
                for (final entry in collection.identities.entries)
                  entry.key: [
                    entry.value.anime,
                    entry.value.season,
                    entry.value.episode,
                  ],
              },
              'subject': collection.subject,
              'episodeTitles': collection.episodeTitles,
              'metadataComplete': collection.metadataComplete,
            },
    };
    store.setLocal(key, data);
    store.setLocal(_directoryEnvelopeKey(key), {
      ...data,
      'complete': false,
      'collection': collection == null
          ? null
          : {
              ...(data['collection'] as Map),
              'videos': const [],
              'identities': const {},
              'episodeTitles': const {},
            },
    });
  });
}

DirectoryPreview? _decodeDirectoryPreview(dynamic json) {
  if (json is! Map) return null;
  try {
    final raw = json['collection'];
    DirectoryCollection? collection;
    if (raw is Map) {
      collection = DirectoryCollection(
        title: raw['title'],
        season: raw['season'],
        videos: [
          for (final item in raw['videos'] as List)
            SourceEntry(
              name: item['name'],
              path: item['path'],
              size: item['size'],
              modified: item['modified'],
              hidden: item['hidden'] == true,
            ),
        ],
        identities: {
          for (final item in (raw['identities'] as Map).entries)
            item.key: ReleaseName(item.value[0], item.value[1], item.value[2]),
        },
        subject: raw['subject'] == null
            ? null
            : Map<String, dynamic>.from(raw['subject']),
        episodeTitles: Map<String, String>.from(raw['episodeTitles']),
        metadataComplete: raw['metadataComplete'] != false,
        episodeCount:
            (raw['episodeCount'] as num?)?.toInt() ??
            (raw['identities'] as Map).values
                .map((value) => value[2])
                .whereType<String>()
                .where((value) => value.isNotEmpty)
                .toSet()
                .length,
      );
    }
    return DirectoryPreview(
      collection: collection,
      context: json['context'],
      fingerprint: json['fingerprint'],
      updatedAt: json['at'],
      modified: json['modified'],
      cacheEpoch: (json['epoch'] as num?)?.toInt() ?? 0,
      sourceEpoch: (json['sourceEpoch'] as num?)?.toInt() ?? 0,
      complete: json['complete'] != false,
    );
  } catch (_) {
    return null;
  }
}

DirectoryPreview? readDirectoryPreview(
  AppStore store,
  String sourceId,
  String path,
) => _decodeDirectoryPreview(store.local(_directoryPreviewKey(sourceId, path)));

DirectoryCollection? identifyDirectory(
  String path,
  List<SourceEntry> entries, {
  ReleaseName? folderIdentity,
}) {
  final videos = <SourceEntry>[];
  final folder = folderIdentity ?? directoryIdentity(path);
  final identities = <String, ReleaseName>{};
  final parsedVideos = <(SourceEntry, ReleaseName)>[];
  final bareEpisode = RegExp(
    r'^(?:EP?)?(\d{1,4})(?:[ ._-].*)?$',
    caseSensitive: false,
  );
  String? explicitTitle, explicitSeason;
  String? title, season;
  String seasonKey(String value) => value.isEmpty ? '1' : value;
  for (final video in entries) {
    if (video.directory || !isVideo(video.name)) continue;
    var parsed = parseReleaseName(video.name);
    if (parsed.episode.isEmpty) {
      final bare = bareEpisode.firstMatch(
        p.basenameWithoutExtension(video.name),
      );
      // Extras without episode evidence do not prevent the actual series from
      // opening its details. Distinct episodic titles still make it ambiguous.
      if (bare == null) continue;
      parsed = ReleaseName('', parsed.season, '${int.parse(bare[1]!)}');
    }
    if (parsed.anime.isNotEmpty) {
      if (explicitTitle != null &&
          normalizedSeries(explicitTitle) != normalizedSeries(parsed.anime)) {
        return null;
      }
      explicitTitle = parsed.anime;
    }
    if (parsed.season.isNotEmpty) {
      if (explicitSeason != null && explicitSeason != parsed.season) {
        return null;
      }
      explicitSeason = parsed.season;
    }
    parsedVideos.add((video, parsed));
  }
  // Read all explicit filename evidence before resolving numeric siblings.
  // Their title must not depend on listing order or a renamed folder. A folder
  // season still constrains files without a season, so conflicting markers do
  // not silently move numeric episodes into a different season.
  final fallbackTitle = explicitTitle ?? folder.anime;
  final fallbackSeason = folder.season.isNotEmpty
      ? folder.season
      : explicitSeason ?? '';
  for (final (video, parsed) in parsedVideos) {
    final name = parsed.anime.isEmpty ? fallbackTitle : parsed.anime;
    final resolvedSeason = parsed.season.isNotEmpty
        ? parsed.season
        : fallbackSeason;
    if (name.isEmpty || normalizedSeries(name).isEmpty) return null;
    if (title != null && normalizedSeries(title) != normalizedSeries(name)) {
      return null;
    }
    if (season != null && seasonKey(season) != seasonKey(resolvedSeason)) {
      return null;
    }
    title = name;
    if (season == null || resolvedSeason.isNotEmpty) season = resolvedSeason;
    videos.add(video);
    identities[video.path] = ReleaseName(name, resolvedSeason, parsed.episode);
  }
  if (videos.isEmpty) {
    final single = entries
        .where((entry) => !entry.directory && isVideo(entry.name))
        .singleOrNull;
    if (single == null || folder.anime.isEmpty) return null;
    final identity = parseReleaseName(single.name);
    // A folder and its single title-only file agree on the title. Make that
    // file's details available before lookup/playback without inventing an
    // episode number or treating unrelated personal videos as one series.
    if (identity.episode.isNotEmpty ||
        normalizedSeries(identity.anime) != normalizedSeries(folder.anime) ||
        (identity.season.isNotEmpty &&
            folder.season.isNotEmpty &&
            identity.season != folder.season)) {
      return null;
    }
    final singleSeason = identity.season.isEmpty
        ? folder.season
        : identity.season;
    return DirectoryCollection(
      title: folder.anime,
      season: singleSeason,
      videos: [single],
      identities: {single.path: ReleaseName(folder.anime, singleSeason)},
      episodeCount: 0,
    );
  }
  // A single released episode (including alternate encodes) is already a
  // series shortcut. Normalize omitted first-season markers across its files.
  for (final video in videos) {
    final identity = identities[video.path]!;
    identities[video.path] = ReleaseName(
      title!,
      season ?? '',
      identity.episode,
    );
  }
  videos.sort((a, b) {
    final x = double.tryParse(identities[a.path]!.episode),
        y = double.tryParse(identities[b.path]!.episode);
    return x != null && y != null ? x.compareTo(y) : a.name.compareTo(b.name);
  });
  return DirectoryCollection(
    title: title!,
    season: season ?? '',
    videos: videos,
    identities: identities,
    episodeCount: identities.values
        .map((identity) => identity.episode)
        .toSet()
        .length,
  );
}

/// Directory fingerprinting and filename parsing are prepared together on the
/// model's existing directory worker. Only the resulting collection crosses
/// back to the UI; callers already running on a worker use this directly.
class DirectoryInspection {
  final String fingerprint;
  final DirectoryCollection? collection;
  final int preparationIsolate;
  const DirectoryInspection(
    this.fingerprint,
    this.collection,
    this.preparationIsolate,
  );
}

DirectoryInspection prepareDirectoryInspection(
  String sourceId,
  String path,
  String context,
  List<SourceEntry> entries, {
  ReleaseName? folderIdentity,
}) {
  final folder = folderIdentity ?? directoryIdentity(path);
  return DirectoryInspection(
    sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sourceId,
              path,
              context,
              folder.anime,
              folder.season,
              for (final entry in entries)
                [
                  entry.name,
                  entry.path,
                  entry.size,
                  entry.modified,
                  entry.directory,
                  entry.hidden,
                ],
            ]),
          ),
        )
        .toString(),
    identifyDirectory(path, entries, folderIdentity: folder),
    Isolate.current.hashCode,
  );
}

String metadataQuery(String value, {bool preserveSeason = true}) {
  // Never let a pasted source URL or full path become a catalogue query.
  if (value.contains('://') ||
      value.contains('/') ||
      value.contains('\\') ||
      RegExp(r'[\x00-\x1f]').hasMatch(value)) {
    return '';
  }
  final parsed = parseReleaseName(value);
  final clean =
      '${parsed.anime.trim()}${preserveSeason && parsed.season.isNotEmpty ? ' 第${parsed.season}季' : ''}';
  return String.fromCharCodes(clean.runes.take(160));
}

Map<String, dynamic> subjectMediaFields(Map<String, dynamic> subject) {
  final provider = subject['provider'] == 'tmdb' ? 'tmdb' : 'bangumi';
  final name = '${subject['name_cn'] ?? ''}'.trim();
  return {
    'metadataProvider': provider,
    if (provider == 'tmdb') 'tmdbId': '${subject['id']}',
    if (provider == 'bangumi') 'bangumiId': '${subject['id']}',
    'metadataTitle': name.isEmpty ? '${subject['name'] ?? ''}' : name,
    'poster': subject['images']?['large'] ?? subject['images']?['common'] ?? '',
    'summary': subject['summary'] ?? '',
    'rating': subject['rating']?['score'],
    'ratingCount': subject['rating']?['total'],
    'airDate': subject['date'] ?? '',
    'totalEpisodes':
        subject['season_episodes'] ??
        subject['total_episodes'] ??
        subject['eps'],
    'totalSeasons': subject['total_seasons'],
    'genres': subject['genres'] ?? <String>[],
    'metadataType': subject['mediaType'] ?? 'tv',
  };
}

Map<String, dynamic> mediaFieldsSubject(Map<String, dynamic> media) => {
  'id': media['tmdbId'] ?? media['bangumiId'],
  'provider': media['tmdbId'] != null ? 'tmdb' : 'bangumi',
  'name': media['metadataTitle'] ?? media['series'],
  'name_cn': media['metadataTitle'] ?? media['series'],
  'images': {'large': media['poster'] ?? ''},
  'summary': media['summary'] ?? '',
  'rating': {'score': media['rating'], 'total': media['ratingCount']},
  'date': media['airDate'] ?? '',
  'season_episodes': media['totalEpisodes'],
  'total_seasons': media['totalSeasons'],
  'genres': media['genres'] ?? <String>[],
  'mediaType': media['metadataType'] ?? 'tv',
};

class _CatalogSearch {
  final List<Map<String, dynamic>> values;
  final bool complete;
  final Object? error;
  const _CatalogSearch(this.values, {this.complete = true, this.error});
}

class _CatalogMatch {
  final Map<String, dynamic>? subject;
  final bool ambiguous, complete;
  const _CatalogMatch({
    this.subject,
    this.ambiguous = false,
    this.complete = true,
  });
}

class LibraryCatalog {
  final AppStore store;
  final String Function() provider;
  final String Function() strategy;
  final bool Function() tmdbNameAssist;
  late final TmdbCatalog tmdb;
  final Future<String> Function() tmdbCredential;
  final JsonTransport transport;
  final Future<DirectoryCollection?> Function(
    String sourceId,
    String path,
    List<SourceEntry> entries,
    CancelToken? cancel,
  )?
  aiFallback;
  final String Function() aiContext;
  final void Function(String)? onPoster;
  final Future<DirectoryInspection> Function(
    String sourceId,
    String path,
    String context,
    List<SourceEntry> entries,
    CancelToken? cancel,
  )?
  prepareDirectory;
  final Future<void> Function(
    String sourceId,
    String path,
    DirectoryPreview preview,
    CancelToken? cancel,
  )?
  persistDirectory;
  final Future<DirectoryPreview?> Function(
    String sourceId,
    String path,
    CancelToken? cancel,
  )?
  readDirectory;
  final Future<bool> Function(
    Map<String, ReleaseName> identities,
    Map<String, String> names,
    CancelToken? cancel,
  )?
  episodeNamesCovered;
  final _pending = <String, Future<DirectoryCollection?>>{};
  final _directories = <String, DirectoryPreview>{};
  final _directoryStamps = <String, (int, int)>{};
  late final _cache = CatalogCache(store);
  final _episodeRefreshes = CatalogCache(null);
  final _episodeRefreshRetries = <String, ({DateTime after, int failures})>{};
  final DateTime Function() _now;
  int _cacheRevision = 0;
  bool cacheMaintenance = false;
  int _episodeFetchRevision = 0;
  final _episodeFetchRevisions = <String, int>{};
  Object get episodeNamesRevision =>
      (_episodeFetchRevision, tmdb.seasonFetchRevision);

  bool episodeNamesFetchedSince(
    Object revision,
    Map<String, dynamic> subject, {
    String season = '',
  }) {
    if (revision case (final int bangumiRevision, final int tmdbRevision)) {
      if (subject['provider'] == 'tmdb') {
        return tmdb.seasonFetchedSince(tmdbRevision, {
          ...subject,
          if ('${subject['season'] ?? ''}'.isEmpty) 'season': season,
        });
      }
      return (_episodeFetchRevisions['${subject['id']}'] ?? 0) >
          bangumiRevision;
    }
    return false;
  }

  LibraryCatalog(
    this.store, {
    JsonTransport? transport,
    String Function()? provider,
    String Function()? strategy,
    bool Function()? tmdbNameAssist,
    Future<String> Function()? tmdbCredential,
    this.aiFallback,
    this.onPoster,
    this.prepareDirectory,
    this.persistDirectory,
    this.readDirectory,
    this.episodeNamesCovered,
    DateTime Function()? now,
    String Function()? aiContext,
  }) : _now = now ?? DateTime.now,
       transport = transport ?? IoJsonTransport(),
       provider = provider ?? (() => 'bangumi'),
       strategy = strategy ?? (() => 'conservative'),
       tmdbNameAssist = tmdbNameAssist ?? (() => true),
       aiContext = aiContext ?? (() => ''),
       tmdbCredential = tmdbCredential ?? (() async => '') {
    tmdb = TmdbCatalog(this.transport, this.tmdbCredential, store: store);
  }
  static const headers = {
    'User-Agent': 'AIPlayer/0.5.1 (personal anime library)',
  };

  String _directoryKey(String sourceId, String path) =>
      _directoryPreviewKey(sourceId, path);

  /// A compact revision for browser completion checks, independent of file
  /// membership. Reading it does not hash or parse a directory on the UI isolate.
  Object directoryInspectionRevision(String sourceId) => (
    strategy(),
    provider(),
    tmdbNameAssist(),
    aiContext(),
    _cacheRevision,
    _directoryPreviewEpoch(store),
    _directorySourceEpoch(store, sourceId),
  );

  (int, int) _directoryStamp(String key) => (
    store.localKeyRevision(key),
    store.localKeyRevision(_directoryEnvelopeKey(key)),
  );

  String _directoryContext(String sourceId) {
    final sources = (store.local('sources') as List? ?? []).whereType<Map>();
    final source = sources
        .where((value) => value['id'] == sourceId)
        .firstOrNull;
    return sha256
        .convert(
          utf8.encode(
            jsonEncode(['catalog-v5', source, strategy(), aiContext()]),
          ),
        )
        .toString();
  }

  DirectoryPreview? directoryPreview(
    String sourceId,
    String path, {
    int? modified,
    bool allowStale = false,
  }) {
    final key = _directoryKey(sourceId, path);
    final stamp = _directoryStamp(key);
    if (_directoryStamps[key] != stamp) _directories.remove(key);
    var value = _directories[key];
    if (value == null) {
      value = _decodeDirectoryPreview(
        store.local(readDirectory == null ? key : _directoryEnvelopeKey(key)),
      );
      if (value == null) return null;
      _directories[key] = value;
      _directoryStamps[key] = stamp;
    }
    if (!_validDirectoryPreview(sourceId, value, modified)) {
      _directories.remove(key);
      return null;
    }
    return value;
  }

  bool _validDirectoryPreview(
    String sourceId,
    DirectoryPreview value,
    int? modified,
  ) =>
      value.cacheEpoch == _directoryPreviewEpoch(store) &&
      value.sourceEpoch == _directorySourceEpoch(store, sourceId) &&
      value.context == _directoryContext(sourceId) &&
      (modified == null || modified == value.modified);

  /// Full cached membership is decoded on the same bounded worker as listing
  /// preparation. Lazy artwork reads only the compact synchronous envelope.
  Future<DirectoryPreview?> loadDirectoryPreview(
    String sourceId,
    String path, {
    int? modified,
    CancelToken? cancel,
  }) async {
    if (cacheMaintenance) throw const Cancelled();
    while (true) {
      cancel?.check();
      final cached = directoryPreview(sourceId, path, modified: modified);
      if (readDirectory == null || cached?.complete == true) return cached;
      final key = _directoryKey(sourceId, path);
      final stamp = _directoryStamp(key);
      final value = await readDirectory!(sourceId, path, cancel);
      cancel?.check();
      if (value == null || !_validDirectoryPreview(sourceId, value, modified)) {
        return null;
      }
      if (stamp != _directoryStamp(key)) continue;
      _directories[key] = value;
      _directoryStamps[key] = stamp;
      return value;
    }
  }

  /// Stop obsolete requests immediately without scanning persistent caches.
  /// The cache-maintenance worker handles the database transaction separately.
  void invalidateMemoryCaches() {
    _cacheRevision++;
    _pending.clear();
    _cache.invalidate();
    _episodeRefreshes.invalidate();
    _episodeRefreshRetries.clear();
    tmdb.invalidateCache();
    _directories.clear();
    _directoryStamps.clear();
  }

  /// Explicit user refresh only. Ordinary recognition, including force=true,
  /// reuses successful data. In-flight obsolete requests cannot refill it.
  void invalidateMetadataCaches() {
    invalidateMemoryCaches();
    store.setLocal('directoryPreviewEpoch', _directoryPreviewEpoch(store) + 1);
    for (final prefix in [
      'catalog-v1:',
      'subject-v5:',
      'episode-names:',
      if (readDirectory == null) 'directory-preview:',
      'directory-preview-envelope:',
    ]) {
      for (final key in store.localEntries(prefix).keys) {
        if (prefix == 'directory-preview-envelope:') {
          store.removeLocal(
            key.replaceFirst(
              'directory-preview-envelope:',
              'directory-preview:',
            ),
          );
        }
        store.removeLocal(key);
      }
    }
  }

  /// Synchronization can replace persistent directory results while the
  /// current catalogue is alive. Reread them on the next UI refresh.
  void reloadSyncedDirectoryPreviews() {
    _directories.clear();
    _directoryStamps.clear();
  }

  void invalidateDirectoryPreviews(String sourceId) {
    store.setLocal(
      'directoryPreviewSourceEpoch:$sourceId',
      _directorySourceEpoch(store, sourceId) + 1,
    );
    // The source configuration participates in each preview's context; an
    // explicit refresh also drops unchanged-parent previews for this source.
    final prefix = readDirectory == null
        ? 'directory-preview:'
        : 'directory-preview-envelope:';
    for (final entry in store.localEntries(prefix).entries) {
      if (entry.value is Map && entry.value['sourceId'] == sourceId) {
        final key = entry.key.replaceFirst(
          'directory-preview-envelope:',
          'directory-preview:',
        );
        store.removeLocal(key);
        store.removeLocal(_directoryEnvelopeKey(key));
        _directories.remove(key);
        _directoryStamps.remove(key);
      }
    }
  }

  Future<void> _rememberDirectory(
    String sourceId,
    String path,
    String fingerprint,
    int? modified,
    DirectoryCollection? collection,
    CancelToken? cancel,
  ) async {
    final key = _directoryKey(sourceId, path);
    final value = DirectoryPreview(
      collection: collection,
      context: _directoryContext(sourceId),
      fingerprint: fingerprint,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      modified: modified ?? _directories[key]?.modified ?? 0,
      cacheEpoch: _directoryPreviewEpoch(store),
      sourceEpoch: _directorySourceEpoch(store, sourceId),
    );
    if (persistDirectory == null) {
      persistDirectoryPreview(store, sourceId, path, value);
    } else {
      await persistDirectory!(sourceId, path, value, cancel);
    }
    cancel?.check();
    if (value.cacheEpoch != _directoryPreviewEpoch(store) ||
        value.sourceEpoch != _directorySourceEpoch(store, sourceId) ||
        value.context != _directoryContext(sourceId)) {
      return;
    }
    _directories[key] = value;
    _directoryStamps[key] = _directoryStamp(key);
    if (collection != null) onPoster?.call(collection.poster);
  }

  Map<String, dynamic> _bangumiSubject(Map<String, dynamic> subject) {
    final platform = '${subject['platform'] ?? ''}'.toLowerCase();
    final movie =
        subject['mediaType'] == 'movie' ||
        ['剧场版', '电影', 'movie', 'theatrical'].contains(platform);
    final seasons = [subject['name'], subject['name_cn']]
        .whereType<String>()
        .map(subjectIdentity)
        .map((identity) => identity.season)
        .where((season) => season.isNotEmpty)
        .toSet();
    return {
      ...subject,
      'provider': 'bangumi',
      'mediaType': movie ? 'movie' : 'tv',
      if (!movie && seasons.length == 1) 'season': seasons.single,
    };
  }

  Future<List<Map<String, dynamic>>> _searchBangumi(
    String title, {
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final query = metadataQuery(title);
    if (query.isEmpty) return [];
    return _cache.load<List<Map<String, dynamic>>>(
      'catalog-v1:bangumi:search:${sha256.convert(utf8.encode(query))}',
      fetch: (token) async {
        final data = await transport.send(
          Uri.https('api.bgm.tv', '/search/subject/$query', {
            'type': '2',
            'responseGroup': 'large',
            'max_results': '20',
          }),
          headers: headers,
          cancel: token,
        );
        token.check();
        return (data['list'] as List? ?? [])
            .whereType<Map>()
            .where(
              (value) => value['type'] == null || '${value['type']}' == '2',
            )
            .map((value) => _bangumiSubject(Map<String, dynamic>.from(value)))
            .toList();
      },
      decode: (value) => (value as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(),
      keep: (values) => values.isNotEmpty,
      cancel: cancel,
    );
  }

  Future<_CatalogSearch> _collectSearch(
    Future<List<Map<String, dynamic>>> Function() search, {
    CancelToken? cancel,
  }) async {
    try {
      cancel?.check();
      final values = await search();
      cancel?.check();
      return _CatalogSearch(values);
    } on Cancelled {
      rethrow;
    } catch (error) {
      cancel?.check();
      return _CatalogSearch(const [], complete: false, error: error);
    }
  }

  Future<_CatalogSearch> _searchTmdb(
    String title, {
    CancelToken? cancel,
  }) async {
    // A failed TV endpoint must not discard movie candidates, and vice versa.
    final results = await Future.wait([
      _collectSearch(() => tmdb.search(title, cancel: cancel), cancel: cancel),
      _collectSearch(
        () => tmdb.search(title, cancel: cancel, movies: true),
        cancel: cancel,
      ),
    ]);
    cancel?.check();
    return _CatalogSearch(
      [for (final result in results) ...result.values],
      complete: results.every((result) => result.complete),
      error: results
          .map((result) => result.error)
          .whereType<Object>()
          .firstOrNull,
    );
  }

  Future<String> _tmdbContext({CancelToken? cancel}) async {
    final revision = _cacheRevision;
    try {
      final credential = (await tmdbCredential()).trim();
      cancel?.check();
      if (cacheMaintenance || revision != _cacheRevision) {
        throw const Cancelled();
      }
      return credential.isEmpty
          ? ''
          : sha256.convert(utf8.encode(credential)).toString();
    } on Cancelled {
      rethrow;
    } catch (_) {
      cancel?.check();
      if (cacheMaintenance || revision != _cacheRevision) {
        throw const Cancelled();
      }
      return '';
    }
  }

  List<Map<String, dynamic>> _uniqueCandidates(
    Iterable<Map<String, dynamic>> values,
  ) => {
    for (final value in values)
      '${value['provider']}:${value['mediaType']}:${value['id']}': value,
  }.values.toList();

  /// Default searches include Bangumi, TMDB TV and TMDB movies. The optional
  /// source remains available to old callers; saved provider choices no longer
  /// prevent a catalogue from participating.
  Future<List<Map<String, dynamic>>> search(
    String title, {
    String? source,
    CancelToken? cancel,
  }) async {
    if (cacheMaintenance) throw const Cancelled();
    cancel?.check();
    final query = metadataQuery(title);
    if (query.isEmpty) return [];
    if (source == 'bangumi') {
      return _uniqueCandidates(await _searchBangumi(query, cancel: cancel));
    }
    if (source == 'tmdb') {
      final result = await _searchTmdb(query, cancel: cancel);
      if (result.values.isEmpty && result.error != null) throw result.error!;
      return _uniqueCandidates(result.values);
    }
    final context = await _tmdbContext(cancel: cancel);
    var complete = true;
    return _cache.load<List<Map<String, dynamic>>>(
      'catalog-v1:search:${sha256.convert(utf8.encode(jsonEncode([query, context, strategy()])))}',
      fetch: (token) async {
        final result = await _searchAll(
          query,
          context.isNotEmpty,
          cancel: token,
        );
        complete = result.complete;
        return result.values;
      },
      decode: (value) => (value as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(),
      keep: (value) => complete && value.isNotEmpty,
      cancel: cancel,
    );
  }

  Future<_CatalogSearch> _searchAll(
    String query,
    bool configured, {
    CancelToken? cancel,
  }) async {
    final results = await Future.wait([
      _collectSearch(
        () => _searchBangumi(query, cancel: cancel),
        cancel: cancel,
      ),
      if (configured)
        _searchTmdb(query, cancel: cancel)
      else
        Future.value(const _CatalogSearch([], complete: false)),
    ]);
    final bangumi = results[0], tmdbResults = results[1];
    var complete = bangumi.complete && (!configured || tmdbResults.complete);
    final found = [...bangumi.values, ...tmdbResults.values];
    if (tmdbResults.complete && tmdbResults.values.isNotEmpty) {
      // Official translated catalogue names can find the same animation in
      // Bangumi. This is built in and independent of the legacy helper switch.
      final parsed = subjectIdentity(query);
      final localized = await _resolveTmdb(
        parsed.anime,
        parsed.season,
        search: tmdbResults,
        cancel: cancel,
      );
      complete = complete && localized.complete;
      if (localized.subject != null) {
        for (final name in tmdb.names(localized.subject!).take(4)) {
          if (normalizedSeries(name) == normalizedSeries(parsed.anime)) {
            continue;
          }
          final extra = await _collectSearch(
            () => _searchBangumi(
              '$name${parsed.season.isEmpty ? '' : ' 第${parsed.season}季'}',
              cancel: cancel,
            ),
            cancel: cancel,
          );
          found.addAll(extra.values);
          complete = complete && extra.complete;
        }
      }
    }
    cancel?.check();
    if (found.isEmpty && !bangumi.complete && !tmdbResults.complete) {
      throw bangumi.error ?? tmdbResults.error!;
    }
    return _CatalogSearch(_uniqueCandidates(found), complete: complete);
  }

  Future<_CatalogMatch> _resolveTmdb(
    String title,
    String season, {
    _CatalogSearch? search,
    CancelToken? cancel,
  }) async {
    try {
      final result = search ?? await _searchTmdb(title, cancel: cancel);
      // Partial results cannot establish uniqueness for automatic adoption.
      if (!result.complete) return const _CatalogMatch(complete: false);
      final candidates = _uniqueCandidates(result.values)
          .where(
            (candidate) => candidate['mediaType'] != 'movie' || season.isEmpty,
          )
          .toList();
      if (candidates.any((value) => value['searchTruncated'] == true)) {
        return const _CatalogMatch(ambiguous: true);
      }
      final identities = await Future.wait([
        for (final candidate in candidates)
          tmdb.identity(candidate, cancel: cancel),
      ]);
      final found = _uniqueCandidates(
        identities.where(
          (identity) => tmdb.titleMatches(
            title,
            identity,
            balanced: strategy() == 'balanced',
          ),
        ),
      );
      if (found.length > 1) return const _CatalogMatch(ambiguous: true);
      if (found.isEmpty) return const _CatalogMatch();
      // Details validate the requested TV season instead of borrowing S01.
      return _CatalogMatch(
        subject: await tmdb.details(
          found.single,
          season: season,
          cancel: cancel,
        ),
      );
    } on Cancelled {
      rethrow;
    } catch (_) {
      cancel?.check();
      return const _CatalogMatch(complete: false);
    }
  }

  Future<Map<String, Map<String, dynamic>>> _bangumiMatches(
    List<String> names,
    String season, {
    CancelToken? cancel,
  }) async {
    final found = <String, Map<String, dynamic>>{};
    final queried = <String>{};
    for (final name in names) {
      for (final query in [
        if (season.isNotEmpty && season != '1') '$name 第$season季',
        name,
      ]) {
        if (!queried.add(query)) continue;
        for (final subject in await _searchBangumi(query, cancel: cancel)) {
          if (season.isNotEmpty && subject['mediaType'] == 'movie') continue;
          if (names.any(
            (name) => subjectMatchesSeason(
              name,
              season,
              subject,
              balanced: strategy() == 'balanced',
            ),
          )) {
            found['${subject['id']}'] = subject;
          }
        }
      }
    }
    return found;
  }

  Future<Map<String, dynamic>> details(
    Map<String, dynamic> subject, {
    String season = '',
    CancelToken? cancel,
  }) async {
    if (cacheMaintenance) throw const Cancelled();
    cancel?.check();
    if (subject['provider'] == 'tmdb') {
      return tmdb.details(subject, season: season, cancel: cancel);
    }
    final id = '${subject['id']}';
    if (!RegExp(r'^\d+$').hasMatch(id)) throw const AppFailure('作品编号无效。');
    return _cache.load<Map<String, dynamic>>(
      'catalog-v1:bangumi:details:$id',
      fetch: (token) async {
        final raw = await transport.send(
          Uri.https('api.bgm.tv', '/v0/subjects/$id'),
          headers: headers,
          cancel: token,
        );
        token.check();
        if ('${raw['id']}' != id ||
            (raw['type'] != null && '${raw['type']}' != '2')) {
          throw const AppFailure('Bangumi 返回的作品编号或类型不一致。');
        }
        return _bangumiSubject({...subject, ...raw});
      },
      decode: (value) => Map<String, dynamic>.from(value as Map),
      keep: (value) => '${value['id']}' == id,
      cancel: cancel,
    );
  }

  Future<_CatalogMatch> _resolveBangumi(
    List<String> names,
    String season, {
    CancelToken? cancel,
  }) async {
    try {
      final found = await _bangumiMatches(names, season, cancel: cancel);
      if (found.length > 1) return const _CatalogMatch(ambiguous: true);
      if (found.isEmpty) return const _CatalogMatch();
      final subject = await details(
        found.values.single,
        season: season,
        cancel: cancel,
      );
      if ((season.isNotEmpty && subject['mediaType'] == 'movie') ||
          !names.any(
            (name) => subjectMatchesSeason(
              name,
              season,
              subject,
              balanced: strategy() == 'balanced',
            ),
          )) {
        return const _CatalogMatch(ambiguous: true);
      }
      return _CatalogMatch(subject: subject);
    } on Cancelled {
      rethrow;
    } catch (_) {
      cancel?.check();
      return const _CatalogMatch(complete: false);
    }
  }

  bool _sameWork(
    Map<String, dynamic> bangumi,
    Map<String, dynamic> tmdbSubject,
  ) {
    if (bangumi['mediaType'] != tmdbSubject['mediaType'] ||
        tmdbSubject['isAnimation'] == false) {
      return false;
    }
    int? year(Object? value) =>
        int.tryParse(RegExp(r'^\d{4}').firstMatch('$value')?.group(0) ?? '');
    final bangumiYear = year(bangumi['date']),
        tmdbYear = year(tmdbSubject['date']);
    if (bangumiYear != null && tmdbYear != null && bangumiYear != tmdbYear) {
      return false;
    }
    final original = '${bangumi['name'] ?? ''}'.trim();
    if (original.isEmpty) return true;
    final identity = normalizedSeries(subjectIdentity(original).anime);
    return tmdb
        .names(tmdbSubject)
        .any(
          (name) => normalizedSeries(subjectIdentity(name).anime) == identity,
        );
  }

  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    if (cacheMaintenance) throw const Cancelled();
    cancel?.check();
    final selectedStrategy = strategy();
    final revision = _cacheRevision;
    if (!force && selectedStrategy == 'off') return null;
    title = metadataQuery(title, preserveSeason: false);
    if (title.isEmpty) return null;
    final tmdbContext = await _tmdbContext(cancel: cancel);
    final configured = tmdbContext.isNotEmpty;
    final matchStrategy = selectedStrategy == 'off'
        ? 'conservative'
        : selectedStrategy;
    final key =
        'subject-v5:all:$matchStrategy:$tmdbContext:${normalizedSeries(title)}:$season';
    final legacyKey =
        'subject-v5:all:$matchStrategy:$configured:${normalizedSeries(title)}:$season';
    final saved = store.local(key) ?? store.local(legacyKey);
    cancel?.check();
    if (strategy() != selectedStrategy || revision != _cacheRevision) {
      return null;
    }
    if (saved is Map && saved['subject'] is Map) {
      return Map<String, dynamic>.from(saved['subject']);
    }
    final results = await Future.wait([
      _resolveBangumi([title], season, cancel: cancel),
      if (configured)
        _resolveTmdb(title, season, cancel: cancel)
      else
        Future.value(const _CatalogMatch()),
    ]);
    var bangumi = results[0];
    final tmdbMatch = results[1];
    if (bangumi.subject == null &&
        !bangumi.ambiguous &&
        bangumi.complete &&
        tmdbMatch.subject != null) {
      bangumi = await _resolveBangumi(
        tmdb.names(tmdbMatch.subject!).take(4).toList(),
        season,
        cancel: cancel,
      );
    }
    Map<String, dynamic>? selected;
    if (!bangumi.ambiguous && !tmdbMatch.ambiguous) {
      if (bangumi.subject != null && tmdbMatch.subject != null) {
        if (_sameWork(bangumi.subject!, tmdbMatch.subject!)) {
          selected = bangumi.subject;
        }
      } else {
        selected = bangumi.subject ?? tmdbMatch.subject;
      }
    }
    cancel?.check();
    if (strategy() != selectedStrategy || revision != _cacheRevision) {
      return null;
    }
    // Failed, ambiguous and empty matches must remain eligible for retry.
    if (selected != null && bangumi.complete && tmdbMatch.complete) {
      store.setLocal(key, {
        'at': DateTime.now().millisecondsSinceEpoch,
        'subject': selected,
      });
    }
    return selected;
  }

  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async {
    if (cacheMaintenance) throw const Cancelled();
    cancel?.check();
    if (subject?['provider'] == 'tmdb') {
      return tmdb.episodeNames(subject!, cancel: cancel);
    }
    return _bangumiEpisodeNames(subjectId, cancel: cancel);
  }

  Future<Map<String, String>> _bangumiEpisodeNames(
    String subjectId, {
    CancelToken? cancel,
    bool refresh = false,
  }) async {
    final key = 'catalog-v1:bangumi:episodes:$subjectId';
    final legacy = store.local('episode-names:$subjectId');
    if (store.local(key) == null &&
        legacy is Map &&
        legacy['names'] is Map &&
        (legacy['names'] as Map).isNotEmpty) {
      store.setLocal(key, legacy['names']);
    }
    return _cache.load<Map<String, String>>(
      key,
      fetch: (token) async {
        final names = <String, String>{};
        for (var offset = 0; offset < 1000; offset += 100) {
          final page = await transport.send(
            Uri.https('api.bgm.tv', '/v0/episodes', {
              'subject_id': subjectId,
              'type': '0',
              'limit': '100',
              'offset': '$offset',
            }),
            headers: headers,
            cancel: token,
          );
          token.check();
          final entries = page['data'] as List? ?? [];
          for (final item in entries.whereType<Map>()) {
            final number = item['sort'];
            if (number is num && number == number.roundToDouble()) {
              final text =
                  '${item['name_cn']?.toString().isNotEmpty == true ? item['name_cn'] : item['name'] ?? ''}';
              if (text.isNotEmpty) names['${number.toInt()}'] = text;
            }
          }
          if (entries.length < 100) break;
        }
        if (_episodeFetchRevisions.length >= 128 &&
            !_episodeFetchRevisions.containsKey(subjectId)) {
          _episodeFetchRevisions.remove(_episodeFetchRevisions.keys.first);
        }
        _episodeFetchRevisions[subjectId] = ++_episodeFetchRevision;
        return names;
      },
      decode: (value) => Map<String, String>.from(value as Map),
      keep: (value) => value.isNotEmpty,
      cancel: cancel,
      refresh: refresh,
      merge: (previous, refreshed) => previous.length + refreshed.length < 256
          ? {...previous, ...refreshed}
          : Isolate.run(() => <String, String>{...previous, ...refreshed}),
    );
  }

  Future<bool> collectionEpisodeNamesCovered(
    DirectoryCollection collection,
    Map<String, String> names, {
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final result = episodeNamesCovered == null
        ? directoryEpisodeNamesCovered(collection.identities, names)
        : await episodeNamesCovered!(collection.identities, names, cancel);
    cancel?.check();
    return result;
  }

  /// Refresh only an incomplete subject/season cache. The public episodeNames
  /// hook remains the first lookup so custom catalogues retain their behavior.
  Future<Map<String, String>> collectionEpisodeNames(
    DirectoryCollection collection,
    Map<String, dynamic> subject, {
    CancelToken? cancel,
    bool refreshCached = true,
  }) async {
    if (cacheMaintenance) throw const Cancelled();
    if (subject['provider'] == 'tmdb' && '${subject['season'] ?? ''}'.isEmpty) {
      subject = {...subject, 'season': collection.season};
    }
    final key =
        '${subject['provider'] ?? 'bangumi'}:${subject['id']}:'
        '${subject['season'] ?? collection.season}:'
        '${store.local('metadataCredentialsRevision') ?? ''}';
    final retry = _episodeRefreshRetries[key];
    void backoff() {
      final failures = (retry?.failures ?? 0).clamp(0, 4);
      if (_episodeRefreshRetries.length >= 128 &&
          !_episodeRefreshRetries.containsKey(key)) {
        _episodeRefreshRetries.remove(_episodeRefreshRetries.keys.first);
      }
      _episodeRefreshRetries[key] = (
        after: _now().add(
          Duration(minutes: (5 * (1 << failures)).clamp(5, 60)),
        ),
        failures: failures + 1,
      );
    }

    final cached = subject['provider'] == 'tmdb'
        ? await tmdb.cachedEpisodeNames(subject, cancel: cancel)
        : _cache.readCached<Map<String, String>>(
            'catalog-v1:bangumi:episodes:${subject['id']}',
            (value) => Map<String, String>.from(value as Map),
          );
    final coolingDown = retry != null && _now().isBefore(retry.after);
    if (cached == null && coolingDown && !_episodeRefreshes.isPending(key)) {
      return Map.of(collection.episodeTitles);
    }
    final revision = episodeNamesRevision;
    final names = await episodeNames(
      '${subject['id']}',
      subject: subject,
      cancel: cancel,
    );
    cancel?.check();
    if (subject['mediaType'] == 'movie' ||
        await collectionEpisodeNamesCovered(
          collection,
          names,
          cancel: cancel,
        )) {
      return names;
    }
    if (!_episodeRefreshes.isPending(key) && coolingDown) {
      return names;
    }
    if (!refreshCached ||
        episodeNamesFetchedSince(revision, subject) ||
        cached == null ||
        names.isEmpty) {
      // This attempt already fetched the provider, or a custom catalogue
      // supplied names without a provider cache. Do not repeat that request.
      backoff();
      return names;
    }
    return _episodeRefreshes.load<Map<String, String>>(
      key,
      refresh: true,
      cancel: cancel,
      keep: (_) => false,
      decode: (value) => Map<String, String>.from(value as Map),
      fetch: (token) async {
        try {
          final refreshed = subject['provider'] == 'tmdb'
              ? await tmdb.episodeNames(subject, cancel: token, refresh: true)
              : await _bangumiEpisodeNames(
                  '${subject['id']}',
                  cancel: token,
                  refresh: true,
                );
          token.check();
          // Retain previously known titles if the provider temporarily returns
          // fewer names. A still-incomplete response observes the same backoff.
          final result = refreshed.isEmpty ? names : refreshed;
          if (await collectionEpisodeNamesCovered(
            collection,
            result,
            cancel: token,
          )) {
            _episodeRefreshRetries.remove(key);
          } else {
            backoff();
          }
          return result;
        } on Cancelled {
          rethrow;
        } catch (_) {
          backoff();
          rethrow;
        }
      },
    );
  }

  Future<DirectoryCollection?> inspect(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    int? directoryModified,
    CancelToken? cancel,
  }) async {
    if (cacheMaintenance) throw const Cancelled();
    cancel?.check();
    final context = _directoryContext(sourceId);
    final revision = _cacheRevision;
    final sourceEpoch = _directorySourceEpoch(store, sourceId);
    final prepared = prepareDirectory == null
        ? prepareDirectoryInspection(
            sourceId,
            path,
            context,
            entries,
            folderIdentity: sourceDirectoryIdentity(store, sourceId, path),
          )
        : await prepareDirectory!(sourceId, path, context, entries, cancel);
    cancel?.check();
    final key = prepared.fingerprint;
    final cached = await loadDirectoryPreview(
      sourceId,
      path,
      modified: directoryModified,
      cancel: cancel,
    );
    if (cached != null &&
        cached.fingerprint == key &&
        cached.collection?.subject != null &&
        await collectionEpisodeNamesCovered(
          cached.collection!,
          cached.collection!.episodeTitles,
          cancel: cancel,
        )) {
      cancel?.check();
      onPoster?.call(cached.collection!.poster);
      return cached.collection;
    }
    Future<DirectoryCollection?> inspectFresh() async {
      final collection = prepared.collection;
      var result = collection;
      if (collection != null && strategy() != 'off') {
        try {
          final episodeRevision = episodeNamesRevision;
          final subject = await resolve(
            collection.title,
            collection.season,
            cancel: cancel,
          );
          // Keep the resolved work visible if episode-title loading fails.
          result = collection.withMetadata(
            subject,
            const {},
            metadataComplete: subject == null,
          );
          final names = subject == null
              ? <String, String>{}
              : await collectionEpisodeNames(
                  collection,
                  subject,
                  cancel: cancel,
                  refreshCached: !episodeNamesFetchedSince(
                    episodeRevision,
                    subject,
                    season: collection.season,
                  ),
                );
          result = collection.withMetadata(
            subject,
            names,
            metadataComplete:
                subject == null ||
                subject['mediaType'] == 'movie' ||
                await collectionEpisodeNamesCovered(
                  collection,
                  names,
                  cancel: cancel,
                ),
          );
        } on Cancelled {
          rethrow;
        } catch (_) {
          // Optional catalogue metadata must not block directory playback.
        }
      }
      cancel?.check();
      if (context != _directoryContext(sourceId) ||
          revision != _cacheRevision ||
          sourceEpoch != _directorySourceEpoch(store, sourceId)) {
        return collection;
      }
      if (result?.subject == null &&
          strategy() != 'off' &&
          aiFallback != null) {
        try {
          final episodeRevision = episodeNamesRevision;
          result = await aiFallback!(sourceId, path, entries, cancel) ?? result;
          if (result?.subject != null &&
              result!.subject!['mediaType'] != 'movie' &&
              !await collectionEpisodeNamesCovered(
                result,
                result.episodeTitles,
                cancel: cancel,
              )) {
            result = result.withMetadata(
              result.subject,
              result.episodeTitles,
              metadataComplete: false,
            );
            final names = await collectionEpisodeNames(
              result,
              result.subject!,
              cancel: cancel,
              refreshCached: !episodeNamesFetchedSince(
                episodeRevision,
                result.subject!,
                season: result.season,
              ),
            );
            result = result.withMetadata(
              result.subject,
              names,
              metadataComplete: await collectionEpisodeNamesCovered(
                result,
                names,
                cancel: cancel,
              ),
            );
          }
        } on Cancelled {
          rethrow;
        } catch (_) {
          // Keep the local file view when optional AI identification fails.
        }
      }
      cancel?.check();
      if (context != _directoryContext(sourceId) ||
          revision != _cacheRevision ||
          sourceEpoch != _directorySourceEpoch(store, sourceId)) {
        return collection;
      }
      if (result?.subject != null) {
        await _rememberDirectory(
          sourceId,
          path,
          key,
          directoryModified,
          result,
          cancel,
        );
        if (context != _directoryContext(sourceId) ||
            revision != _cacheRevision ||
            sourceEpoch != _directorySourceEpoch(store, sourceId)) {
          return collection;
        }
      }
      return result;
    }

    // A cancelled browser must not cancel another browser's shared lookup.
    if (cancel != null) return inspectFresh();
    final pendingKey = '$key:$sourceEpoch';
    final existing = _pending[pendingKey];
    if (existing != null) return existing;
    late final Future<DirectoryCollection?> request;
    request = inspectFresh().whenComplete(() {
      if (identical(_pending[pendingKey], request)) _pending.remove(pendingKey);
    });
    _pending[pendingKey] = request;
    return request;
  }
}
