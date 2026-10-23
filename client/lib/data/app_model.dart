import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../core/network.dart';
import '../core/logger.dart';
import '../danmaku/api.dart';
import '../danmaku/release_name.dart';
import '../sources/source.dart';
import '../sources/configuration.dart';
import '../sources/apple_access.dart';
import '../sources/directory_sort.dart';
import 'store.dart';
import 'record_keys.dart';
import 'credential_storage.dart';
import 'preferences.dart';
import 'sync.dart';
import 'sync_profile.dart';
import 'sync_artwork.dart';
import 'media_previews.dart';
import 'library_catalog.dart';
import 'library_snapshot.dart';
import 'directory_metadata_worker.dart';
import 'media_presentation.dart';
import 'media_title_translation.dart';
import 'poster_cache.dart';
import 'source_preview.dart';
import 'media_ai_recognition.dart';
import '../subtitles/ai.dart';

part 'app_model_metadata_ai.dart';
part 'app_model_metadata_tasks.dart';
part 'app_model_directory_recognition.dart';

dynamic _copyJson(dynamic value) => switch (value) {
  Map() => <String, dynamic>{
    for (final entry in value.entries)
      entry.key as String: _copyJson(entry.value),
  },
  List() => [for (final entry in value) _copyJson(entry)],
  _ => value,
};

dynamic _immutableJson(dynamic value) => switch (value) {
  Map() => Map<String, dynamic>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _immutableJson(entry.value),
  }),
  List() => List<dynamic>.unmodifiable(value.map(_immutableJson)),
  _ => value,
};

Future<List<SourceEntry>> _listSourceDirectory(
  SourceAdapter connection,
  String path,
  Set<CancelToken> cancellation,
) async {
  for (final token in cancellation) {
    token.check();
  }
  final stopped = Completer<List<SourceEntry>>();
  final subscriptions = [
    for (final token in cancellation)
      token.whenCancelled.asStream().listen((_) {
        if (!stopped.isCompleted) stopped.completeError(const Cancelled());
      }),
  ];
  try {
    // The caller's finally closes the adapter as soon as cancellation wins,
    // even when a network listing has not answered. This top-level helper and
    // removable subscriptions never retain AppModel through a long-lived token.
    return await Future.any([connection.list(path), stopped.future]);
  } finally {
    for (final subscription in subscriptions) {
      // Future.asStream has no asynchronous resource to release. Cancelling
      // synchronously detaches the callback; it must not delay source cleanup.
      unawaited(subscription.cancel());
    }
  }
}

class AppModel extends ChangeNotifier {
  final AppStore store;
  final Directory documents;
  final bool backgroundWork;
  final FlutterSecureStorage secrets;
  PosterCache? _posterCache;
  PosterCache get posterCache => _posterCache ??= PosterCache(
    directory: Directory(p.join(documents.path, 'poster-cache-v1')),
  );

  void _prefetchPoster(String url) {
    if (_disposed || url.isEmpty) return;
    // Persist confirmed artwork as part of identification, including records
    // with no visible card. Image failures must not delay metadata success.
    unawaited(posterCache.load(url));
  }

  int directorySortRevision = 0;
  DirectorySort directorySorting(String key) => DirectorySort.fromJson(
    store.local(key) ?? store.local('directorySort:default'),
  );

  void setDirectorySorting(String key, DirectorySort value) {
    store.setLocal(key, value.toJson());
    directorySortRevision++;
    changed();
  }

  void applyDirectorySortingToAll(DirectorySort value) {
    for (final entry in store.localEntries('directorySort:').entries) {
      if (entry.key == 'directorySort:default') continue;
      final current = DirectorySort.fromJson(entry.value);
      store.setLocal(
        entry.key,
        current
            .copyWith(field: value.field, descending: value.descending)
            .toJson(),
      );
    }
    store.setLocal('directorySort:default', {
      'field': value.field,
      'descending': value.descending,
    });
    directorySortRevision++;
    changed();
  }

  late final titleTranslations = MediaTitleTranslations(
    store,
    settings: () => settings,
  );
  late final MediaAiRecognition mediaAi = MediaAiRecognition(store);
  late final SyncProfile syncProfile = SyncProfile(
    store,
    secrets,
    recoverMissingCredentials: secrets is LocalCredentialStorage,
    watchedKey: mediaWatchedKey,
    artwork: SyncArtwork(store, documents, posterCache),
  );
  late final SyncClient sync = SyncClient(store, profile: syncProfile);
  String? _activePlaybackMediaId;
  String? get activePlaybackMediaId => _activePlaybackMediaId;
  set activePlaybackMediaId(String? id) {
    if (_disposed || _activePlaybackMediaId == id) return;
    final wasPlaying = _activePlaybackMediaId != null;
    _activePlaybackMediaId = id;
    _syncResumeTimer?.cancel();
    if (id != null) {
      _syncWatch?.cancel();
      _syncWatch = null;
      realtimeConnected = false;
      _syncNeedsFull = false;
      if (_syncWork != null && _activeSyncAppliesProfile) {
        _activeSync?.cancel();
      }
      if (!wasPlaying) unawaited(pausePreviews());
    } else {
      resumePreviews();
      _releaseAutomaticWork();
      if (backgroundWork && _foreground) {
        // Wait until decoder cleanup and the final screenshot have finished.
        _syncResumeTimer = Timer(const Duration(seconds: 1), () {
          if (_disposed || !_foreground || activePlaybackMediaId != null) {
            return;
          }
          unawaited(synchronize(quiet: true));
          unawaited(_identifyPending());
        });
      }
    }
  }

  late final LibraryCatalog catalog = LibraryCatalog(
    store,
    provider: () => settings['metadataProvider'] as String? ?? 'bangumi',
    strategy: () => settings['metadataStrategy'] as String? ?? 'conservative',
    tmdbNameAssist: () => preferences.tmdbNameAssist,
    aiFallback: _identifyDirectoryWithAi,
    aiContext: () => _metadataAiContext,
    onPoster: _prefetchPoster,
    tmdbCredential: () async {
      final key = await secrets.read(key: 'tmdb.apiKey') ?? '';
      AppLog.instance.rememberSecret(key);
      return key;
    },
  );
  final _metadataCancel = CancelToken();
  DirectoryMetadataWorker? _directoryMetadataWorker;
  CancelToken? _directoryRecognitionCancel;
  bool recognizingDirectory = false;
  DirectoryRecognitionProgress directoryRecognitionProgress =
      const DirectoryRecognitionProgress();
  final _metadataPending = <String>{};
  Map<String, List<SyncRecord>>? _batchMetadataDonors;
  Map<String, bool>? _batchMediaBindings;
  Timer? _metadataTimer;
  bool _identifying = false;
  final List<MetadataTask> _metadataTasks = [];
  final _metadataLookups = _MetadataLimiter(3);
  bool _metadataWorkerRunning = false;
  bool _metadataTasksRestored = false;
  Timer? _syncTimer;
  Timer? _syncDebounce;
  Timer? _syncResumeTimer;
  CancelToken? _syncWatch;
  CancelToken? _activeSync;
  bool _activeSyncAppliesProfile = false;
  final _syncArtworkIds = <String>{};
  int _syncConnectionRevision = 0;
  String _syncWatchIdentity = '';
  bool realtimeConnected = false;
  Future<void>? _syncWork;
  bool _syncAgain = false, _syncNeedsFull = false, _syncVisible = false;
  int _catalogProfileRevision = -1;
  DateTime? _nextSyncAttempt;
  MediaPreviewQueue? _previews;
  final _previewDiagnostics = <String>{};
  final _previewFileChecks = <String, Future<bool>>{};
  final _pendingPreviewChecks = <String>{};
  final _playbackPreviewWork = <Future<void>>{};
  bool _disposed = false;
  String status = '';
  bool scanning = false;
  AppModel(
    this.store,
    this.documents, {
    FlutterSecureStorage? secrets,
    bool enableThumbnails = false,
    PreviewCapture? previewCapture,
    this.backgroundWork = true,
    bool deferBackgroundWork = false,
  }) : secrets = secrets ?? createCredentialStorage(documents) {
    if (backgroundWork && !deferBackgroundWork) {
      scheduleMicrotask(() => unawaited(startBackgroundWork()));
    }
    if (enableThumbnails) {
      _previews = MediaPreviewQueue(
        directory: Directory(p.join(documents.path, 'previews')),
        openSource: adapter,
        capture: previewCapture,
        isCurrent: (request) => _currentPreviewId(request) != null,
        onReady: (request, path, preview) {
          final id = _currentPreviewId(request);
          if (id == null) return;
          final oldPath = (store.local('preview:$id') as Map?)?['path'];
          if (oldPath is String &&
              oldPath != path &&
              p.isWithin(p.join(documents.path, 'previews'), oldPath)) {
            unawaited(
              File(oldPath).delete().catchError((Object _) => File(oldPath)),
            );
          }
          store.setLocal('preview:$id', {
            'path': path,
            'fingerprint': request.fingerprint,
            'contentFingerprint': request.contentFingerprint,
            'requestedPosition': request.position,
            'capturedPosition': preview.capturedPosition,
            'formatVersion': MediaPreview.formatVersion,
          });
          recordMediaMetadata(
            id,
            duration: preview.duration,
            width: preview.width,
            height: preview.height,
          );
          AppLog.instance.info(
            '封面',
            '视频封面已生成（${preview.width ?? 0} × ${preview.height ?? 0}）。',
          );
          if (!_disposed) notifyListeners();
        },
        onError: (error) => AppLog.instance.warning(
          '封面',
          '${safeFailure(error).message} 视频仍可正常播放。',
        ),
      );
    }
  }
  Future<void>? _backgroundStart;
  bool _foreground = true;
  Completer<void>? _automaticReady;

  /// The app starts this after its first frame, keeping library repair and
  /// task restoration out of the launch path. Other hosts can await readiness.
  Future<void> startBackgroundWork() {
    if (_disposed || !backgroundWork) return Future.value();
    return _backgroundStart ??= _startBackgroundWork();
  }

  Future<void> _startBackgroundWork() async {
    try {
      await _restoreMetadataGaps();
      if (_disposed) return;
      _restoreMetadataTasks();
      _metadataPending.addAll(
        (store.local('metadata:automatic-pending') as List? ?? const [])
            .whereType<String>(),
      );
      unawaited(_identifyPending());
      unawaited(synchronize(quiet: true));
      _syncTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (_foreground && activePlaybackMediaId == null) {
          unawaited(synchronize(quiet: true));
        }
      });
    } catch (error) {
      if (!_disposed) {
        AppLog.instance.warning('后台任务', safeFailure(error).message);
      }
    }
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      _syncResumeTimer?.cancel();
      _syncDebounce?.cancel();
      _syncWatch?.cancel();
      _syncWatch = null;
      realtimeConnected = false;
      if (_activeSyncAppliesProfile) _activeSync?.cancel();
    } else {
      _releaseAutomaticWork();
      if (backgroundWork) {
        unawaited(synchronize(quiet: true));
        unawaited(_identifyPending());
      }
    }
  }

  void _releaseAutomaticWork() {
    if (!_foreground || activePlaybackMediaId != null) return;
    _automaticReady?.complete();
    _automaticReady = null;
    unawaited(_drainMetadataTasks());
  }

  Future<void> _waitForAutomaticWork(CancelToken cancel) async {
    while (!_disposed && (!_foreground || activePlaybackMediaId != null)) {
      final ready = _automaticReady ??= Completer<void>();
      await Future.any([ready.future, cancel.whenCancelled]);
      cancel.check();
    }
    if (_disposed) throw const Cancelled();
    cancel.check();
  }

  int _settingsRevision = -1,
      _sourcesRevision = -1,
      _mediaSnapshotRevision = -1;
  Map<String, dynamic> _settingsSnapshot = const {};
  List<Map<String, dynamic>> _sourcesSnapshot = const [];
  List<SyncRecord> _mediaSnapshot = const [];
  LibrarySnapshotReader? _librarySnapshotReader;
  LibrarySnapshot? _librarySnapshot;
  (int, int, int)? _librarySnapshotRevision;
  Future<void>? _librarySnapshotWork;

  (int, int, int) get _libraryReadRevision => (
    store.recordsRevision('media'),
    store.recordsRevision('progress'),
    store.locationRevision,
  );

  /// Prepare all library reads, history sorting and search grouping away from
  /// the UI isolate. Keep a single worker request even if multiple tabs ask.
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    final search = query.toLowerCase();
    while (true) {
      cancel?.check();
      if (_disposed) throw const Cancelled();
      final revision = _libraryReadRevision;
      final cached = _librarySnapshot;
      if (_librarySnapshotRevision == revision && cached?.query == search) {
        return cached!;
      }
      final work = _librarySnapshotWork ??= _prepareLibrarySnapshot(
        search,
        revision,
      ).whenComplete(() => _librarySnapshotWork = null);
      await Future.any<void>([
        work,
        if (cancel != null)
          cancel.whenCancelled.then((_) => throw const Cancelled()),
      ]);
    }
  }

  Future<void> _prepareLibrarySnapshot(
    String query,
    (int, int, int) revision,
  ) async {
    final reader = _librarySnapshotReader ??= LibrarySnapshotReader(store);
    final snapshot = await reader.read(query: query, revision: revision);
    if (_disposed || revision != _libraryReadRevision) return;
    _librarySnapshot = snapshot;
    _librarySnapshotRevision = revision;
    // Business readers can reuse the worker's immutable media snapshot too.
    _mediaSnapshot = snapshot.media;
    _mediaSnapshotRevision = revision.$1;
  }

  Map<String, dynamic> get settings {
    final revision = store.localKeyRevision('settings');
    if (_settingsRevision != revision) {
      _settingsSnapshot = Map<String, dynamic>.from(
        store.local('settings') ?? {},
      );
      _settingsRevision = revision;
    }
    // Callers edit a detached draft before saving, including nested shortcuts.
    return _copyJson(_settingsSnapshot) as Map<String, dynamic>;
  }

  int _preferencesRevision = -1;
  AppPreferences? _preferences;
  AppPreferences get preferences {
    final revision = store.localKeyRevision('settings');
    if (_preferences == null || revision != _preferencesRevision) {
      _preferences = AppPreferences(settings);
      _preferencesRevision = revision;
    }
    return _preferences!;
  }

  Future<void> updatePreferences(Map<String, dynamic> patch) async {
    final checked = preferences.checkedPatch(patch);
    final current = settings;
    checked.removeWhere((key, value) => current[key] == value);
    if (checked.isEmpty) return;
    final revision = store.localKeyRevision('settings');
    store.setLocal('settings', {...current, ...checked});
    if (store.localKeyRevision('settings') != revision) notifyListeners();
  }

  Future<void> resetPreferences() async {
    final next = settings;
    for (final key in [...AppPreferences.defaults.keys, 'shortcuts']) {
      next.remove(key);
    }
    final revision = store.localKeyRevision('settings');
    store.setLocal('settings', next);
    if (store.localKeyRevision('settings') != revision) notifyListeners();
  }

  ThemeMode get themeMode => store.local('appearance:theme') == 'dark'
      ? ThemeMode.dark
      : ThemeMode.light;
  void setThemeMode(ThemeMode mode) {
    final next = mode == ThemeMode.dark ? ThemeMode.dark : ThemeMode.light;
    if (next == themeMode) return;
    store.setLocal(
      'appearance:theme',
      next == ThemeMode.dark ? 'dark' : 'light',
    );
    notifyListeners();
  }

  List<Map<String, dynamic>> get sources {
    final revision = store.localKeyRevision('sources');
    if (_sourcesRevision != revision) {
      _sourcesSnapshot = (store.local('sources') as List? ?? [])
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      _sourcesRevision = revision;
    }
    return [
      for (final source in _sourcesSnapshot)
        _copyJson(source) as Map<String, dynamic>,
    ];
  }

  /// Shared read-only snapshot; only a media revision requires SQL/JSON work.
  List<SyncRecord> get media {
    final revision = store.recordsRevision('media');
    if (_mediaSnapshotRevision != revision) {
      _mediaSnapshot = List.unmodifiable([
        for (final record in store.all('media'))
          SyncRecord(
            id: record.id,
            kind: record.kind,
            data: _immutableJson(record.data) as Map<String, dynamic>,
            modifiedAt: record.modifiedAt,
            deviceId: record.deviceId,
            deviceName: record.deviceName,
            version: record.version,
            revision: record.revision,
            deleted: record.deleted,
            dirty: record.dirty,
          ),
      ]);
      _mediaSnapshotRevision = revision;
    }
    return _mediaSnapshot;
  }

  Map<String, dynamic>? progressFor(SyncRecord record) {
    final value = store.get('progress', progressKey(record));
    return value?.deleted == false ? value!.data : null;
  }

  /// Remove this file's current history entry, preserving other episodes even
  /// when the history UI groups them into one series card.
  void removePlaybackHistory(SyncRecord record) {
    final progress = store.get('progress', progressKey(record));
    if (progress == null || progress.deleted) return;
    // Keep a sync tombstone, without stale resume data for direct store readers.
    store.save('progress', progress.id, {}, deleted: true);
    notifyListeners();
  }

  String originalEpisodeTitle(SyncRecord record) =>
      (store.local('episodeTitle:${record.id}') as String?) ??
      '${record.data['episodeTitle'] ?? ''}';

  String seriesTitle(SyncRecord record) {
    final current = store.get('media', record.id) ?? record;
    return titleTranslations.display(
      mediaSeriesKey(current),
      mediaSeriesName(current),
    );
  }

  String displayTitle(SyncRecord record) {
    final name = seriesTitle(record), episode = episodeLabel(record);
    return episode.isEmpty ? name : '$name · $episode';
  }

  String episodeLabel(SyncRecord record) {
    final current = store.get('media', record.id) ?? record;
    return mediaEpisodeLabel(
      current,
      episodeTitle: titleTranslations.display(
        mediaSeriesKey(current),
        originalEpisodeTitle(current),
      ),
    );
  }

  List<SyncRecord> recentMedia({
    bool groupSeries = true,
    Iterable<SyncRecord>? items,
  }) {
    // Read two snapshots instead of doing location and progress SQL queries for
    // every video. A large library refresh must not block the scroll UI.
    final progressById = {
      for (final record in store.records('progress'))
        if (!record.deleted) record.id: record.data,
    };
    final locations = store.localEntries('location:');
    final candidates = <({SyncRecord media, String updatedAt})>[];
    for (final item in items ?? media) {
      // Match progressKey's device-local size precedence and fallback exactly.
      final size =
          locations['location:${item.id}']?['size'] ?? item.data['size'] ?? 0;
      final progress = progressById['${item.id}:$size'];
      if (((progress?['position'] as num?) ?? 0) > 0) {
        candidates.add((
          media: item,
          updatedAt: '${progress?['updatedAt'] ?? ''}',
        ));
      }
    }
    candidates.sort((a, b) {
      final order = b.updatedAt.compareTo(a.updatedAt);
      return order == 0 ? a.media.id.compareTo(b.media.id) : order;
    });
    final recent = candidates.map((item) => item.media).toList();
    if (!groupSeries) return recent;
    final seen = <String>{};
    return recent.where((item) => seen.add(mediaSeriesKey(item))).toList();
  }

  void changed() => notifyListeners();
  Future<void> setSettings(
    Map<String, dynamic> value, {
    String? danmuToken,
    String? syncToken,
  }) async {
    if (danmuToken != null) {
      AppLog.instance.rememberSecret(danmuToken);
      await secrets.write(key: 'danmuToken', value: danmuToken);
      store.markLocalModified('secret:danmuToken');
    }
    if (syncToken != null) {
      AppLog.instance.rememberSecret(syncToken);
      await secrets.write(key: 'syncToken', value: syncToken);
    }
    // Secure storage is asynchronous; preserve preferences changed while the
    // connection credentials were being saved.
    store.setLocal('settings', {...settings, ...value});
    AppLog.instance.info('设置', '连接配置已保存。');
    notifyListeners();
    if (value.containsKey('syncOrigin') || syncToken != null) {
      _syncConnectionRevision++;
      _activeSync?.cancel();
      _syncWatch?.cancel();
      _syncWatch = null;
      realtimeConnected = false;
      unawaited(synchronize(quiet: true));
    }
  }

  Future<DanmuApiClient?> danmu() async {
    final token = await secrets.read(key: 'danmuToken');
    if (token == null || token.isEmpty) return null;
    AppLog.instance.rememberSecret(token);
    return DanmuApiClient(
      settings['danmuOrigin'] ?? DanmuApiClient.defaultOrigin,
      token,
    );
  }

  Future<void> saveSource(Map<String, dynamic> source, String password) async {
    _directoryRecognitionCancel?.cancel();
    final persisted = Map<String, dynamic>.from(source)..remove('password');
    AppLog.instance.rememberSecret(password);
    await secrets.write(key: 'source:${source['id']}', value: password);
    store.markLocalModified('source:${source['id']}');
    final list = sources;
    final index = list.indexWhere((s) => s['id'] == source['id']);
    final previous = index < 0 ? null : list[index];
    final locationChanged =
        previous != null &&
        [
          'kind',
          'host',
          'port',
          'share',
          'url',
        ].any((key) => previous[key] != persisted[key]);
    if (index < 0) {
      list.add(persisted);
    } else {
      list[index] = persisted;
    }
    store.setLocal('sources', list);
    for (final location in store.locations.where(
      (v) => v['source'] == source['id'],
    )) {
      if (locationChanged) {
        store.setLocal('location:${location['id']}', {
          ...location,
          'previewRevision': const Uuid().v4(),
        });
      }
      _previews?.forget(location['id']);
    }
    AppLog.instance.info('来源', index < 0 ? '已添加来源。' : '来源设置已更新。');
    notifyListeners();
  }

  void reorderSources(List<String> ids) {
    final current = sources;
    if (ids.length != current.length ||
        ids.toSet().length != ids.length ||
        !ids.toSet().containsAll(current.map((v) => v['id'] as String))) {
      throw const AppFailure('来源顺序无效，请重试。');
    }
    if (listEquals(ids, current.map((value) => value['id']).toList())) return;
    final byId = {for (final value in current) value['id']: value};
    store.setLocal('sources', [for (final id in ids) byId[id]]);
    notifyListeners();
  }

  String _sourceExclusionKey(String sourceId, String path) =>
      'automatic-import-excluded:${sha256.convert(utf8.encode(jsonEncode([sourceId, path])))}';

  SyncRecord? sourceMedia(String sourceId, String path) {
    final location = store.locationFor(sourceId, path);
    if (location == null) return null;
    final record = store.get('media', location['id']);
    return record?.deleted == false ? record : null;
  }

  Future<void> removeSource(String id) async {
    if (id == 'local') throw const AppFailure('本地视频入口不能删除。');
    _directoryRecognitionCancel?.cancel();
    await secrets.delete(key: 'source:$id');
    store.setLocal(
      'sources',
      sources..removeWhere((source) => source['id'] == id),
    );
    for (final location in store.locations.where((v) => v['source'] == id)) {
      _previews?.forget(location['id']);
    }
    AppLog.instance.info('来源', '已删除来源配置，影视库中的视频记录保留。');
    notifyListeners();
  }

  Future<SourceAdapter> adapter(String id) async {
    if (id == 'local') return LocalSource();
    final source =
        sources.where((s) => s['id'] == id).firstOrNull ??
        (store.local('externalSource:$id') is Map
            ? Map<String, dynamic>.from(store.local('externalSource:$id'))
            : null);
    if (source == null) throw const AppFailure('来源未配置，请先关联此设备上的视频位置。');
    final password = await secrets.read(key: 'source:$id') ?? '';
    AppLog.instance.rememberSecret(password);
    return connectSource(source, password: password);
  }

  ReleaseName mediaIdentity(SourceEntry entry) {
    var guess = parseReleaseName(entry.name);
    final folder = subjectIdentity(
      p.posix.basename(p.posix.dirname(entry.path.replaceAll('\\', '/'))),
    );
    if (guess.episode.isEmpty && folder.anime.isNotEmpty) {
      final number = RegExp(
        r'^(?:EP?)?(\d{1,4})(?:[ ._-].*)?$',
        caseSensitive: false,
      ).firstMatch(p.basenameWithoutExtension(entry.name));
      if (number != null) {
        guess = ReleaseName(
          folder.anime,
          folder.season,
          '${int.parse(number[1]!)}',
        );
      }
    }
    final name = guess.anime.isEmpty ? folder.anime : guess.anime;
    final compatible =
        guess.anime.isEmpty ||
        normalizedSeries(guess.anime) == normalizedSeries(folder.anime);
    return ReleaseName(
      name,
      guess.season.isNotEmpty
          ? guess.season
          : compatible
          ? folder.season
          : '',
      guess.episode,
    );
  }

  bool applyCollectionMetadata(
    String id,
    DirectoryCollection collection,
    SourceEntry entry, {
    bool notify = true,
  }) {
    if (store.local('manualMetadata:$id') == true) return false;
    final record = store.get('media', id);
    final identity = collection.identities[entry.path];
    if (record == null || record.deleted || identity == null) return false;
    final data = {...record.data};
    if (collection.subject != null) {
      final existingId = record.data['tmdbId'] ?? record.data['bangumiId'];
      final incoming = subjectMediaFields(collection.subject!);
      if (existingId != null &&
          (existingId.toString() != '${collection.subject!['id']}' ||
              record.data['tmdbId'] != incoming['tmdbId'] ||
              record.data['bangumiId'] != incoming['bangumiId'] ||
              (record.data['tmdbId'] != null &&
                  (record.data['metadataType'] ?? 'tv') !=
                      incoming['metadataType']))) {
        return false;
      }
      data.remove('bangumiId');
      data.remove('tmdbId');
    }
    final title = collection.episodeTitle(entry.path);
    final updated = {
      ...data,
      'series': identity.anime,
      'season': identity.season,
      'episode': identity.episode,
      if (collection.subject != null)
        ...subjectMediaFields(collection.subject!),
      if (title.isNotEmpty) 'episodeTitle': title,
    };
    final dataChanged = !_equalMetadata(updated, record.data);
    final titleChanged =
        title.isNotEmpty && store.local('episodeTitle:$id') != title;
    if (dataChanged) store.save('media', id, updated);
    if (titleChanged) store.setLocal('episodeTitle:$id', title);
    if (collection.subject != null) _prefetchPoster(collection.poster);
    if (notify && (dataChanged || titleChanged)) notifyListeners();
    return dataChanged || titleChanged;
  }

  DirectoryCollection? collectionFromEntries(
    String sourceId,
    String path,
    List<SourceEntry> entries,
  ) {
    final identified = identifyDirectory(path, entries);
    if (identified != null) return identified;
    final videos = entries
        .where((entry) => !entry.directory && isVideo(entry.name))
        .toList();
    if (videos.isEmpty) return null;
    final records = [
      for (final entry in videos) ?sourceMedia(sourceId, entry.path),
    ];
    if (records.length != videos.length ||
        records.map(mediaSeriesKey).toSet().length != 1 ||
        (records.first.data['bangumiId'] == null &&
            records.first.data['tmdbId'] == null)) {
      return null;
    }
    final first = records.first;
    return DirectoryCollection(
      title: '${first.data['series']}',
      season: '${first.data['season'] ?? ''}',
      videos: videos,
      identities: {
        for (final entry in videos)
          entry.path: ReleaseName(
            '${first.data['series']}',
            '${first.data['season'] ?? ''}',
            '${sourceMedia(sourceId, entry.path)?.data['episode'] ?? ''}',
          ),
      },
      subject: mediaFieldsSubject(first.data),
      episodeTitles: {
        for (final item in records)
          '${item.data['episode']}':
              '${store.local('episodeTitle:${item.id}') ?? ''}',
      },
    );
  }

  /// Catalogue and source browsing share the same records, including episodes
  /// that have not been played yet. Recognized collections import missing
  /// episodes by default; explicit false keeps update-only callers unchanged.
  /// Manual selections always win over lookup.
  DirectoryCollection synchronizeCollection(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
  }) {
    final known = [
      for (final entry in value.videos) ?sourceMedia(sourceId, entry.path),
    ];
    final verified = known
        .where(
          (item) =>
              item.data['tmdbId'] != null || item.data['bangumiId'] != null,
        )
        .toList();
    final manual = verified
        .where((item) => store.local('manualMetadata:${item.id}') == true)
        .toList();
    final donors = manual.isEmpty ? verified : manual;
    final keys = donors.map(mediaSeriesKey).toSet();
    var resolved = value;
    if (keys.length == 1) {
      final donor = donors.first;
      final sameSubject =
          value.subject != null &&
          '${value.subject!['id']}' ==
              '${donor.data['tmdbId'] ?? donor.data['bangumiId']}' &&
          (value.subject!['provider'] == 'tmdb') ==
              (donor.data['tmdbId'] != null) &&
          (donor.data['tmdbId'] == null ||
              (value.subject!['mediaType'] ?? 'tv') ==
                  (donor.data['metadataType'] ?? 'tv')) &&
          (value.season.isEmpty ? '1' : value.season) ==
              ('${donor.data['season'] ?? ''}'.isEmpty
                  ? '1'
                  : '${donor.data['season']}');
      final names = <String, String>{if (sameSubject) ...value.episodeTitles};
      for (final item in known) {
        if (mediaSeriesKey(item) != mediaSeriesKey(donor)) continue;
        final name =
            store.local('episodeTitle:${item.id}') ?? item.data['episodeTitle'];
        if (name is String && name.isNotEmpty) {
          names['${item.data['episode']}'] = name;
        }
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
        subject: manual.isEmpty && sameSubject
            ? {...mediaFieldsSubject(donor.data), ...value.subject!}
            : mediaFieldsSubject(donor.data),
        episodeTitles: names,
      );
    }
    if (keys.length > 1) resolved = value.withMetadata(null, {});
    var changed = false;
    for (final entry in resolved.videos) {
      final existing = sourceMedia(sourceId, entry.path);
      if (existing == null &&
          (!(importMissing ?? resolved.subject != null) ||
              store.local(_sourceExclusionKey(sourceId, entry.path)) == true)) {
        continue;
      }
      final id = existing?.id ?? addMedia(sourceId, entry, notify: false);
      if (existing == null) changed = true;
      if (applyCollectionMetadata(id, resolved, entry, notify: false)) {
        changed = true;
      }
    }
    if (changed) notifyListeners();
    return resolved;
  }

  List<SyncRecord> collectionRecords(
    String sourceId,
    DirectoryCollection value,
  ) =>
      [for (final entry in value.videos) ?sourceMedia(sourceId, entry.path)]
        ..sort(compareMediaEpisodes);

  Object get _directoryContentRevision => (
    store.recordsRevision('media'),
    store.locationRevision,
    store.localPrefixRevision('preview:'),
    store.localPrefixRevision('mediaMetadata:'),
    store.localPrefixRevision('episodeTitle:'),
  );

  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (_disposed) throw const Cancelled();
    final before = _directoryContentRevision;
    try {
      final result = store.path == ':memory:'
          ? synchronizeDirectoryCollection(
              store,
              sourceId,
              value,
              importMissing: importMissing,
              anchorId: anchorId,
            )
          : await (_directoryMetadataWorker ??= DirectoryMetadataWorker(
              store.path,
            )).synchronize(
              sourceId,
              value,
              importMissing: importMissing,
              anchorId: anchorId,
              cancel: cancel ?? _metadataCancel,
            );
      cancel?.check();
      if (_disposed) throw const Cancelled();
      if (result.changed) _prefetchPoster(result.collection.poster);
      return result.collection;
    } finally {
      // Cancelling the requesting page cannot hide an atomic commit from the
      // library that has just become visible. Keep the cancellation exception.
      if (!_disposed && before != _directoryContentRevision) notifyListeners();
    }
  }

  /// Directory parsing, large episode lists and record writes share the
  /// bounded metadata worker. Browsers and library details use this entry point
  /// after asynchronously obtaining a source listing.
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    if (_disposed) throw const Cancelled();
    final before = _directoryContentRevision;
    try {
      final result = store.path == ':memory:'
          ? await synchronizeDirectoryListing(
              store,
              sourceId,
              path,
              entries,
              hideHidden: preferences.hideHiddenFiles,
              anchorId: anchorId,
              cancel: cancel ?? _metadataCancel,
            )
          : await (_directoryMetadataWorker ??= DirectoryMetadataWorker(
              store.path,
            )).synchronizeListing(
              sourceId,
              path,
              entries,
              hideHidden: preferences.hideHiddenFiles,
              anchorId: anchorId,
              cancel: cancel ?? _metadataCancel,
            );
      cancel?.check();
      if (_disposed) throw const Cancelled();
      if (result?.changed == true) _prefetchPoster(result!.collection.poster);
      return result?.collection;
    } finally {
      if (!_disposed && before != _directoryContentRevision) notifyListeners();
    }
  }

  List<SyncRecord> seriesRecords(SyncRecord record) =>
      media
          .where((item) => mediaSeriesKey(item) == mediaSeriesKey(record))
          .toList()
        ..sort(compareMediaEpisodes);

  /// Older libraries only stored played files. Complete their source directory
  /// before showing details so the two entry points expose the same episodes.
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final snapshot = await loadLibrarySnapshot(cancel: cancel);
    final current = snapshot.byId[record.id];
    if (current == null) return const [];
    final existing = snapshot.series[mediaSeriesKey(current)] ?? [current];
    final directories = <String>{};
    for (final item in existing) {
      cancel?.check();
      final location = snapshot.locations[item.id];
      if (location == null || item.data['metadataType'] == 'movie') continue;
      final sourceId = '${location['source']}';
      final path = p.posix.dirname('${location['path']}'.replaceAll('\\', '/'));
      if (!directories.add('$sourceId:$path')) continue;
      SourceAdapter? connection;
      try {
        // An already recognized folder is usable even while its source is
        // offline. Import its complete cached series before optional listing.
        final cached = catalog.directoryPreview(sourceId, path)?.collection;
        if (cached?.subject != null) {
          await synchronizeCollectionInBackground(
            sourceId,
            cached!,
            importMissing: true,
            anchorId: item.id,
            cancel: cancel,
          );
        }
        connection = await adapter(sourceId);
        cancel?.check();
        final entries = await _listSourceDirectory(connection, path, {
          _metadataCancel,
          ?cancel,
        });
        cancel?.check();
        if (_disposed) break;
        await synchronizeDirectoryEntriesInBackground(
          sourceId,
          path,
          entries,
          anchorId: item.id,
          cancel: cancel,
        );
      } on Cancelled {
        rethrow;
      } catch (_) {
        // Offline sources retain their complete last-known library records.
      } finally {
        try {
          await connection?.close();
        } catch (_) {
          /* optional listing */
        }
      }
    }
    final updated = await loadLibrarySnapshot(cancel: cancel);
    return updated.series[mediaSeriesKey(updated.byId[record.id] ?? record)] ??
        const [];
  }

  Future<bool> identifyMediaRecords(
    List<SyncRecord> records, {
    CancelToken? cancel,
  }) async {
    final task = startMetadataTask(records);
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (!_disposed) cancelMetadataTask(task);
        }),
      );
    }
    await task.done;
    cancel?.check();
    return task.matched == task.total && task.error.isEmpty;
  }

  String addMedia(
    String sourceId,
    SourceEntry entry, {
    String? associateId,
    bool notify = true,
  }) {
    // Explicit playback/import can restore a file previously removed from the
    // library; passive directory completion must respect that removal.
    store.removeLocal(_sourceExclusionKey(sourceId, entry.path));
    final existing = store.locationFor(sourceId, entry.path);
    final id = associateId ?? existing?['id'] ?? const Uuid().v4();
    final previous = store.get('media', id);
    if (previous == null || previous.deleted) {
      final guess = mediaIdentity(entry);
      store.save('media', id, {
        'title': entry.name,
        'fileName': entry.name,
        'series': guess.anime.isEmpty ? '未分类' : guess.anime,
        'season': guess.season,
        'episode': guess.episode,
        'size': entry.size,
        'duration': 0,
        if (sourceId == 'local') 'localOnly': true,
      });
    }
    store.setLocal('location:$id', {
      'id': id,
      'source': sourceId,
      'path': entry.path,
      'size': entry.size,
      'modified': entry.modified,
      if (existing?['previewRevision'] != null)
        'previewRevision': existing?['previewRevision'],
    });
    adoptBrowsingMediaPreview(store, sourceId, entry.path, id);
    if (_batchMediaBindings != null) {
      _batchMediaBindings![id] = sourceId == 'local';
    } else if (sourceId != 'local') {
      syncProfile.rememberRemoteMedia(id);
    } else {
      syncProfile.rememberLocalMedia(id);
    }
    _reuseVerifiedMetadata(id);
    _scheduleIdentification(id);
    if (notify) notifyListeners();
    return id;
  }

  Future<void> _restoreMetadataGaps() async {
    await _waitForAutomaticWork(_metadataCancel);
    final groups = <String, List<SyncRecord>>{};
    for (final item in media) {
      if ('${item.data['episode'] ?? ''}'.isNotEmpty) {
        (groups[_identityKey(item)] ??= []).add(item);
      }
    }
    var expectedRevision = store.recordsRevision('media');
    for (final group in groups.values) {
      await _waitForAutomaticWork(_metadataCancel);
      if (store.recordsRevision('media') != expectedRevision) return;
      final verified = group
          .where(
            (item) =>
                item.data['bangumiId'] != null || item.data['tmdbId'] != null,
          )
          .toList();
      final ids = verified
          .map(
            (item) =>
                '${item.data['tmdbId'] != null ? 'tmdb:${item.data['metadataType'] ?? 'tv'}' : 'bangumi'}:${item.data['tmdbId'] ?? item.data['bangumiId']}',
          )
          .toSet();
      if (ids.length != 1) continue;
      final missing = group
          .where(
            (item) =>
                item.data['bangumiId'] == null && item.data['tmdbId'] == null,
          )
          .toList();
      for (var offset = 0; offset < missing.length; offset += 24) {
        await _waitForAutomaticWork(_metadataCancel);
        if (store.recordsRevision('media') != expectedRevision) return;
        final donor = store.get('media', verified.first.id);
        if (donor == null ||
            donor.deleted ||
            donor.revision != verified.first.revision) {
          break;
        }
        var repaired = false;
        store.transaction(() {
          for (final item in missing.skip(offset).take(24)) {
            final current = store.get('media', item.id);
            if (current == null ||
                current.deleted ||
                current.revision != item.revision) {
              continue;
            }
            if (current.data['bangumiId'] == null &&
                current.data['tmdbId'] == null &&
                store.local('manualMetadata:${item.id}') != true) {
              _copyVerifiedMetadata(current, donor);
              repaired = true;
            }
          }
        });
        expectedRevision = store.recordsRevision('media');
        if (!_disposed && repaired) changed();
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  String _identityKey(SyncRecord record) =>
      '${normalizedSeries('${record.data['series'] ?? ''}')}:${record.data['season']?.toString().isNotEmpty == true ? record.data['season'] : '1'}';

  void _reuseVerifiedMetadata(String id) {
    final record = store.get('media', id);
    if (record == null ||
        record.deleted ||
        store.local('manualMetadata:$id') == true ||
        record.data['bangumiId'] != null ||
        record.data['tmdbId'] != null) {
      return;
    }
    if ('${record.data['episode'] ?? ''}'.isEmpty) return;
    final key = _identityKey(record);
    final candidates = _batchMetadataDonors == null
        ? media
        : _batchMetadataDonors![key] ?? const <SyncRecord>[];
    final matches = candidates
        .where(
          (item) =>
              item.id != id &&
              _identityKey(item) == key &&
              (item.data['bangumiId'] != null || item.data['tmdbId'] != null),
        )
        .toList();
    final identities = matches
        .map(
          (item) =>
              '${item.data['tmdbId'] != null ? 'tmdb:${item.data['metadataType'] ?? 'tv'}' : 'bangumi'}:${item.data['tmdbId'] ?? item.data['bangumiId']}',
        )
        .toSet();
    if (identities.length != 1) return;
    final donor = matches.first;
    _copyVerifiedMetadata(record, donor);
  }

  void _copyVerifiedMetadata(SyncRecord record, SyncRecord donor) {
    final id = record.id;
    store.save('media', id, {
      ...record.data,
      for (final key in _metadataFields)
        if (donor.data.containsKey(key)) key: donor.data[key],
    });
    _prefetchPoster('${donor.data['poster'] ?? ''}');
    final names = store.local('metadataEpisodeNames:${_identityKey(record)}');
    final episodeName = names is Map
        ? names['${record.data['episode']}']
        : null;
    if (episodeName is String && episodeName.isNotEmpty) {
      store.setLocal('episodeTitle:$id', episodeName);
    }
  }

  static const _metadataFields = [
    'bangumiId',
    'tmdbId',
    'metadataProvider',
    'metadataTitle',
    'poster',
    'summary',
    'rating',
    'ratingCount',
    'airDate',
    'totalEpisodes',
    'totalSeasons',
    'genres',
    'metadataType',
  ];

  void _scheduleIdentification(String id) {
    if (_disposed || preferences.metadataStrategy == 'off') return;
    _metadataPending.add(id);
    if (_batchMediaBindings != null) return;
    store.setLocal('metadata:automatic-pending', _metadataPending.toList());
    _metadataTimer?.cancel();
    _metadataTimer = Timer(const Duration(milliseconds: 350), _identifyPending);
  }

  Future<void> _identifyPending() async {
    if (_disposed ||
        _identifying ||
        !_foreground ||
        activePlaybackMediaId != null ||
        preferences.metadataStrategy == 'off') {
      return;
    }
    _identifying = true;
    try {
      while (_metadataPending.isNotEmpty &&
          !_disposed &&
          _foreground &&
          activePlaybackMediaId == null &&
          preferences.metadataStrategy != 'off') {
        final ids = _metadataPending.toList();
        _metadataPending.clear();
        store.setLocal('metadata:automatic-pending', <String>[]);
        final records = [for (final id in ids) store.get('media', id)]
            .whereType<SyncRecord>()
            .where(
              (record) =>
                  !record.deleted &&
                  store.local('manualMetadata:${record.id}') != true &&
                  record.data['bangumiId'] == null &&
                  record.data['tmdbId'] == null,
            )
            .toList();
        if (records.isNotEmpty) {
          await startMetadataTask(records, manual: false, label: '自动识别').done;
        }
      }
    } finally {
      _identifying = false;
    }
  }

  Iterable<SyncRecord> _metadataRecords(Set<String>? mediaIds) {
    if (mediaIds == null) return media;
    final ids = mediaIds.toList()..sort();
    return [
      for (final id in ids) ?store.get('media', id),
    ].where((record) => !record.deleted && record.data['transient'] != true);
  }

  Future<void> _applyEpisodeNames(
    SyncRecord record,
    Map<String, dynamic> subject, {
    CancelToken? cancel,
    Set<String>? mediaIds,
  }) async {
    final names = await catalog.episodeNames(
      '${subject['id']}',
      subject: subject,
      cancel: cancel,
    );
    cancel?.check();
    if (_disposed) return;
    final changed = store.path == ':memory:'
        ? persistDirectoryEpisodeNames(
            store,
            record,
            subject,
            names,
            mediaIds: mediaIds,
          )
        : await (_directoryMetadataWorker ??= DirectoryMetadataWorker(
            store.path,
          )).persistEpisodeNames(
            record,
            subject,
            names,
            mediaIds: mediaIds,
            cancel: cancel ?? _metadataCancel,
          );
    cancel?.check();
    if (!_disposed && changed) notifyListeners();
  }

  Future<void> fillEpisodeNames(
    String series,
    Map<String, dynamic> subject, {
    String? season,
    CancelToken? cancel,
    Set<String>? mediaIds,
  }) async {
    final record = _metadataRecords(mediaIds)
        .where(
          (item) =>
              mediaIds != null ||
              (normalizedSeries('${item.data['series']}') ==
                      normalizedSeries(series) &&
                  (season == null || '${item.data['season'] ?? ''}' == season)),
        )
        .firstOrNull;
    if (record != null) {
      await _applyEpisodeNames(
        record,
        subject,
        cancel: cancel ?? _metadataCancel,
        mediaIds: mediaIds,
      );
    }
  }

  Future<void> refreshMetadata() async {
    await _restoreMetadataGaps();
    for (final item in media) {
      if (store.local('manualMetadata:${item.id}') != true) {
        _metadataPending.add(item.id);
      }
    }
    await _identifyPending();
  }

  Future<String> importExternalFile(
    String path,
    String name, {
    bool temporary = false,
  }) async {
    if (!temporary) {
      await AppleFileAccess.remember(path);
      final entry = await LocalSource().stat(path);
      return _addExternalMedia(
        'local',
        SourceEntry(
          name: name,
          path: path,
          size: entry.size,
          modified: entry.modified,
        ),
      );
    }
    final displayName = p.basename(name.replaceAll('\\', '/'));
    final extension = p.extension(displayName);
    final stem = p.basenameWithoutExtension(displayName);
    final safeStem = String.fromCharCodes(
      stem.runes.take(60),
    ).replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
    final directory = Directory(
      p.join(documents.path, 'media', const Uuid().v4()),
    );
    await directory.create(recursive: true);
    final target = p.join(
      directory.path,
      '${safeStem.isEmpty ? '视频' : safeStem}$extension',
    );
    try {
      // Native incoming files are owned temporary copies. Moving within the
      // application filesystem avoids a second full copy for large videos.
      try {
        await File(path).rename(target);
      } on FileSystemException {
        await File(path).copy(target);
      }
      final entry = await LocalSource().stat(target);
      return _addExternalMedia(
        'local',
        SourceEntry(
          name: displayName,
          path: target,
          size: entry.size,
          modified: entry.modified,
        ),
        ownsFile: true,
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<String> importExternalLink(String url, String name) async {
    final id = 'external-${const Uuid().v4()}';
    final source = {
      'id': id,
      'kind': 'http',
      'url': url,
      'label': name,
      'transient': true,
    };
    final adapter = await connectSource(source);
    try {
      final entry = await adapter.stat('');
      store.setLocal('externalSource:$id', source);
      return _addExternalMedia(
        id,
        SourceEntry(name: name, path: entry.path, size: entry.size),
      );
    } finally {
      await adapter.close();
    }
  }

  String _addExternalMedia(
    String sourceId,
    SourceEntry entry, {
    bool ownsFile = false,
  }) {
    final id = 'temporary-${const Uuid().v4()}';
    final guess = mediaIdentity(entry);
    store.transaction(() {
      store.save('media', id, {
        'title': entry.name,
        'fileName': entry.name,
        'series': guess.anime.isEmpty ? entry.name : guess.anime,
        'season': guess.season,
        'episode': guess.episode,
        'size': entry.size,
        'duration': 0,
        'localOnly': true,
        'transient': true,
        if (ownsFile) 'transientFileOwned': true,
      });
      store.setLocal('location:$id', {
        'id': id,
        'source': sourceId,
        'path': entry.path,
        'size': entry.size,
        'modified': entry.modified,
      });
    });
    return id;
  }

  /// External open is a temporary playback session, never a library import.
  Future<void> disposeExternalMedia(String id) async {
    final record = store.get('media', id);
    if (record?.data['transient'] != true) return;
    final owned = record!.data['transientFileOwned'] == true
        ? await _managedImportFile(record)
        : null;
    final sourceId = (store.local('location:$id') as Map?)?['source'];
    if (owned != null) {
      try {
        await owned.delete();
        await owned.parent.delete();
      } on FileSystemException {
        // Never remove an unrelated sibling or prevent closing the player.
      }
    }
    store.transaction(() {
      store.db.execute(
        'DELETE FROM records WHERE id=? OR (kind=? AND substr(id,1,?)=?)',
        [id, 'progress', id.length + 1, '$id:'],
      );
      store.db.execute('DELETE FROM conflicts WHERE id=?', [id]);
      for (final key in [
        'location',
        'preview',
        'mediaMetadata',
        'technical',
        'episodeTitle',
      ]) {
        store.removeLocal('$key:$id');
        store.removeLocal('syncModified:$key:$id');
      }
      if (sourceId is String && sourceId.startsWith('external-')) {
        store.removeLocal('externalSource:$sourceId');
        store.removeLocal('syncModified:externalSource:$sourceId');
      }
    });
    if (!_disposed) notifyListeners();
  }

  Future<String> importFile(String path, {String? associateId}) async {
    await AppleFileAccess.remember(path);
    var actual = path;
    if (Platform.isAndroid || Platform.isIOS) {
      final directory = Directory(
        p.join(documents.path, 'media', const Uuid().v4()),
      );
      await directory.create(recursive: true);
      actual = p.join(directory.path, p.basename(path));
      try {
        await File(path).copy(actual);
      } catch (_) {
        await directory.delete(recursive: true);
        rethrow;
      }
    }
    return addMedia(
      'local',
      await LocalSource().stat(actual),
      associateId: associateId,
    );
  }

  MediaPreviewRequest? _previewRequest(String id) {
    if (store.get('media', id)?.data['transient'] == true) return null;
    final location = store.local('location:$id') ?? store.local('browse:$id');
    if (location is! Map ||
        location['source'] is! String ||
        location['path'] is! String) {
      return null;
    }
    return MediaPreviewRequest(
      id,
      location['source'],
      location['path'],
      (location['size'] as num?)?.toInt() ?? 0,
      revision: location['previewRevision'] as String? ?? '',
      position: _previewPosition(id),
    );
  }

  String? _currentPreviewId(MediaPreviewRequest request) {
    if (_disposed) return null;
    // A browse capture may finish after recognition has imported the video.
    // Publish directly to its library ID, while rejecting a newer playback
    // position, replaced source content or a record removed in the meantime.
    final id = request.id.startsWith('browse-')
        ? sourceMedia(request.source, request.path)?.id ?? request.id
        : request.id;
    if (store.get('media', id)?.deleted != false &&
        (store.local('browse:$id') == null ||
            store.local(_sourceExclusionKey(request.source, request.path)) ==
                true)) {
      return null;
    }
    return _previewRequest(id)?.fingerprint == request.fingerprint ? id : null;
  }

  double? _previewPosition(String id) {
    final record = store.get('media', id);
    if (record == null) return null;
    final value = store.get('progress', progressKey(record))?.data['position'];
    return value is num && value.isFinite && value > 0
        ? value.toDouble()
        : null;
  }

  String sourcePreviewId(String sourceId, String path) =>
      sourceMedia(sourceId, path)?.id ?? browsingMediaId(sourceId, path);

  String ensureSourceMediaPreview(String sourceId, SourceEntry entry) {
    final id = sourcePreviewId(sourceId, entry.path);
    if (sourceMedia(sourceId, entry.path) == null) {
      store.setLocal('browse:$id', {
        'source': sourceId,
        'path': entry.path,
        'size': entry.size,
      });
      final index = List<String>.from(
        store.local('browse:index') ?? <String>[],
      );
      index.remove(id);
      index.add(id);
      store.setLocal('browse:index', index);
    }
    ensureMediaPreview(id);
    return id;
  }

  String? thumbnailPath(String id) {
    final saved = store.local('preview:$id');
    if (saved is! Map || saved['path'] is! String) return null;
    if (saved['formatVersion'] != MediaPreview.formatVersion) return null;
    final current = _previewRequest(id)?.fingerprint;
    if (saved['fingerprint'] != current &&
        saved['contentFingerprint'] !=
            _previewRequest(id)?.contentFingerprint) {
      final key = 'mismatch:$id:${saved['fingerprint']}:$current';
      if (_previewDiagnostics.add(key)) {
        String short(Object? value) {
          if (value == null) return '无';
          final text = '$value';
          return text.length > 8 ? text.substring(0, 8) : text;
        }

        AppLog.instance.warning(
          '封面',
          '封面缓存与视频位置不匹配（缓存 ${short(saved['fingerprint'])}，当前 ${short(current)}），将重新生成。',
        );
      }
      return null;
    }
    if (_previewDiagnostics.add('cached:$id:${saved['fingerprint']}')) {
      AppLog.instance.info('封面', '已找到本机封面缓存。');
    }
    return saved['path'] as String;
  }

  /// Progress changes do not invalidate an existing frame. Players refresh it
  /// explicitly on pause/close; browsing only repairs absent or changed files.
  Future<bool> needsMediaPreview(String id) async {
    final request = _previewRequest(id);
    if (request == null) return true;
    final saved = store.local('preview:$id');
    if (saved is! Map ||
        saved['formatVersion'] != MediaPreview.formatVersion ||
        (saved['fingerprint'] != request.fingerprint &&
            saved['contentFingerprint'] != request.contentFingerprint) ||
        saved['path'] is! String) {
      return true;
    }
    final path = saved['path'] as String;
    final pending = _previewFileChecks[path];
    if (pending != null) return !await pending;
    late final Future<bool> check;
    check = File(path)
        .exists()
        .catchError((Object error) {
          if (error is FileSystemException) return false;
          throw error;
        })
        .whenComplete(() {
          if (identical(_previewFileChecks[path], check)) {
            _previewFileChecks.remove(path);
          }
        });
    _previewFileChecks[path] = check;
    return !await check;
  }

  void ensureMediaPreview(String id) {
    if (_disposed || _previews == null || activePlaybackMediaId != null) return;
    if (!_pendingPreviewChecks.add(id)) return;
    unawaited(
      _ensureMediaPreview(id)
          .catchError((Object error) {
            if (!_disposed) {
              AppLog.instance.warning('封面', safeFailure(error).message);
            }
          })
          .whenComplete(() => _pendingPreviewChecks.remove(id)),
    );
  }

  Future<void> _ensureMediaPreview(String id) async {
    while (!_disposed && _previews != null && activePlaybackMediaId == null) {
      final record = store.get('media', id);
      final request = _previewRequest(id);
      if (request == null ||
          (record?.deleted != false && store.local('browse:$id') == null)) {
        return;
      }
      final saved = store.local('preview:$id');
      final needed = await needsMediaPreview(id);
      if (_disposed || activePlaybackMediaId != null) return;
      // A newer playback frame, source edit or progress update can arrive
      // while the filesystem responds. Only schedule the current snapshot.
      final current = store.local('preview:$id');
      if (_previewRequest(id)?.fingerprint != request.fingerprint ||
          (saved is Map && current is Map
              ? !mapEquals(saved, current)
              : saved != current)) {
        continue;
      }
      if (needed) {
        _previews!.schedule(request, priority: request.position != null);
      }
      return;
    }
  }

  /// Includes a player's queued captures, so a secondary engine can save its
  /// final local cover before shutting down its model and SQLite connection.
  void trackPlaybackPreviewWork(Future<void> work) {
    _playbackPreviewWork.add(work);
    unawaited(
      work.then<void>(
        (_) {
          _playbackPreviewWork.remove(work);
        },
        onError: (Object _, StackTrace _) {
          _playbackPreviewWork.remove(work);
        },
      ),
    );
  }

  Future<void> flushPlaybackPreviews() async {
    while (_playbackPreviewWork.isNotEmpty) {
      await Future.wait(
        _playbackPreviewWork.map(
          (work) => work.catchError((Object _) {
            // The capture's owner reports errors; shutdown must still finish.
          }),
        ),
      );
    }
  }

  /// Store the frame already decoded by the foreground player. This avoids
  /// reconnecting a network video and makes the latest resume cover available
  /// as soon as the player closes, even while a background cover queue is full.
  Future<void> savePlaybackPreview(
    String id,
    Uint8List bytes, {
    required double position,
  }) {
    final work = _savePlaybackPreview(id, bytes, position: position);
    trackPlaybackPreviewWork(work);
    return work;
  }

  Future<void> _savePlaybackPreview(
    String id,
    Uint8List bytes, {
    required double position,
  }) async {
    if (_disposed || bytes.isEmpty) return;
    final request = _previewRequest(id);
    if (request == null ||
        request.position == null ||
        (request.position! - position).abs() > 1.5) {
      return;
    }
    final image = await encodeUsablePreviewImage(bytes);
    if (image == null) {
      // Retain a useful cover across fades. The next visible card can request
      // another capture without starting a decoder while closing the player.
      if (!_disposed &&
          _previewRequest(id)?.fingerprint == request.fingerprint) {
        _previews?.forget(id);
      }
      return;
    }
    if (_disposed || _previewRequest(id)?.fingerprint != request.fingerprint) {
      return;
    }
    final directory = Directory(p.join(documents.path, 'previews'));
    await directory.create(recursive: true);
    final name = sha256.convert(utf8.encode(id)).toString();
    final destination = p.join(
      directory.path,
      '$name-${request.fingerprint.substring(0, 12)}-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    final file = File(destination);
    await file.writeAsBytes(image, flush: true);
    if (_disposed || _previewRequest(id)?.fingerprint != request.fingerprint) {
      await file.delete();
      return;
    }
    _previews?.forget(id);
    final previous = (store.local('preview:$id') as Map?)?['path'];
    store.setLocal('preview:$id', {
      'path': destination,
      'fingerprint': request.fingerprint,
      'contentFingerprint': request.contentFingerprint,
      'requestedPosition': request.position,
      'capturedPosition': position,
      'formatVersion': MediaPreview.formatVersion,
    });
    if (previous is String &&
        previous != destination &&
        p.isWithin(directory.path, previous)) {
      try {
        await File(previous).delete();
      } on FileSystemException {
        /* optional cache */
      }
    }
    if (!_disposed) {
      requestArtworkSync(id);
      notifyListeners();
    }
  }

  Future<void> pausePreviews() async => _previews?.pause();
  void resumePreviews() => _previews?.resume();

  void recordMediaMetadata(
    String id, {
    required double duration,
    int? width,
    int? height,
  }) {
    if (_disposed ||
        (store.get('media', id)?.deleted != false &&
            store.local('browse:$id') == null)) {
      return;
    }
    final request = _previewRequest(id);
    if (request == null) return;
    final current = store.local('mediaMetadata:$id');
    final previous =
        current is Map && current['fingerprint'] == request.contentFingerprint
        ? Map<String, dynamic>.from(current)
        : <String, dynamic>{};
    final next = <String, dynamic>{
      ...previous,
      'fingerprint': request.contentFingerprint,
      if (duration.isFinite && duration > 0) 'duration': duration,
      if (width != null && width > 0) 'width': width,
      if (height != null && height > 0) 'height': height,
    };
    if (!mapEquals(previous, next)) store.setLocal('mediaMetadata:$id', next);
  }

  ({int width, int height})? mediaDimensions(SyncRecord record) {
    final metadata = store.local('mediaMetadata:${record.id}');
    if (metadata is! Map ||
        metadata['fingerprint'] !=
            _previewRequest(record.id)?.contentFingerprint) {
      return null;
    }
    final width = (metadata['width'] as num?)?.toInt() ?? 0;
    final height = (metadata['height'] as num?)?.toInt() ?? 0;
    return width > 0 && height > 0 ? (width: width, height: height) : null;
  }

  double mediaDuration(SyncRecord record) {
    final metadata = store.local('mediaMetadata:${record.id}');
    final localDuration =
        metadata is Map &&
            metadata['fingerprint'] ==
                _previewRequest(record.id)?.contentFingerprint
        ? (metadata['duration'] as num?)?.toDouble()
        : null;
    final progress = store.get('progress', progressKey(record));
    for (final value in [
      localDuration,
      (progress?.data['duration'] as num?)?.toDouble(),
      (record.data['duration'] as num?)?.toDouble(),
    ]) {
      if (value != null && value.isFinite && value > 0) return value;
    }
    return 0;
  }

  /// Only the app's UUID import folders are owned files. A linked local file,
  /// a remote file, or a symlink under this directory is never a deletion target.
  Future<File?> _managedImportFile(SyncRecord record) async {
    final location = store.local('location:${record.id}');
    if (location is! Map ||
        location['source'] != 'local' ||
        location['path'] is! String) {
      return null;
    }
    try {
      final root = Directory(p.join(documents.path, 'media'));
      final file = File(location['path']);
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(file.parent.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        return null;
      }
      final ownedRoot = await root.resolveSymbolicLinks();
      final appRoot = await documents.resolveSymbolicLinks();
      final actual = await file.resolveSymbolicLinks();
      if (!p.isWithin(appRoot, ownedRoot) || !p.isWithin(ownedRoot, actual)) {
        return null;
      }
      final parts = p.split(p.relative(actual, from: ownedRoot));
      if (parts.length != 2 ||
          !RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
          ).hasMatch(parts.first)) {
        return null;
      }
      return File(actual);
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> isManagedImport(SyncRecord record) async =>
      await _managedImportFile(record) != null;

  Future<void> removeMedia(SyncRecord record) async {
    final current = store.get('media', record.id);
    if (current == null || current.deleted) return;
    _previews?.forget(record.id);
    final owned = await _managedImportFile(current);
    if (owned != null) {
      try {
        await owned.delete();
      } on FileSystemException catch (error) {
        AppLog.instance.error('影视库', '导入视频删除失败。');
        throw AppFailure('无法删除导入的视频文件：${error.osError?.message ?? '请检查存储权限'}');
      }
      // Never recursively remove a folder: it may contain another imported file.
      try {
        await owned.parent.delete();
      } on FileSystemException {
        // Keep nonempty directories and any unrelated files.
      }
    }
    final previewPath = (store.local('preview:${record.id}') as Map?)?['path'];
    if (previewPath is String &&
        p.isWithin(p.join(documents.path, 'previews'), previewPath)) {
      try {
        await File(previewPath).delete();
      } on FileSystemException {
        /* optional cache */
      }
    }
    store.transaction(() {
      final location = store.local('location:${record.id}');
      if (location is Map &&
          location['source'] is String &&
          location['path'] is String) {
        store.setLocal(
          _sourceExclusionKey(location['source'], location['path']),
          true,
        );
      }
      store.save('media', record.id, current.data, deleted: true);
      final progress = store.get('progress', progressKey(current));
      if (progress != null && !progress.deleted) {
        store.save('progress', progress.id, progress.data, deleted: true);
      }
      final match = store.get('match', record.id);
      if (match != null && !match.deleted) {
        store.save('match', match.id, match.data, deleted: true);
      }
      store.removeLocal('location:${record.id}');
      store.removeLocal('preview:${record.id}');
      store.removeLocal('mediaMetadata:${record.id}');
      store.removeLocal('technical:${record.id}');
    });
    for (final extension in ['png', 'jpg']) {
      final cover = File(
        p.join(
          documents.path,
          'previews',
          '${sha256.convert(utf8.encode(record.id))}.$extension',
        ),
      );
      try {
        if (await cover.exists()) await cover.delete();
      } on FileSystemException {
        AppLog.instance.warning('封面', '旧封面缓存未能清理。');
      }
    }
    AppLog.instance.info(
      '影视库',
      owned == null ? '视频已从影视库移除，原文件保留。' : '已删除导入的视频副本。',
    );
    notifyListeners();
  }

  Future<void> scan(String sourceId, String root, {CancelToken? cancel}) async {
    if (scanning) return;
    scanning = true;
    status = '正在扫描…';
    AppLog.instance.info('影视库', '开始扫描视频目录。');
    notifyListeners();
    SourceAdapter? source;
    try {
      if (sourceId == 'local') await AppleFileAccess.remember(root);
      source = await adapter(sourceId);
      final queue = <String>[root], visited = <String>{};
      var count = 0, donorRevision = -1;
      var donors = <String, List<SyncRecord>>{};
      while (queue.isNotEmpty) {
        cancel?.check();
        final directory = queue.removeLast();
        if (!visited.add(directory)) continue;
        final entries = await source.list(directory);
        // Bounded transactions avoid a durable SQLite commit and a full
        // library notification for every discovered file. Yield after each
        // batch so input, frames and WebDAV playback forwarding can run.
        for (var offset = 0; offset < entries.length; offset += 24) {
          cancel?.check();
          final hideHidden = preferences.hideHiddenFiles;
          if (store.recordsRevision('media') != donorRevision) {
            donors = {};
            for (final item in media) {
              if (item.data['bangumiId'] != null ||
                  item.data['tmdbId'] != null) {
                (donors[_identityKey(item)] ??= []).add(item);
              }
            }
          }
          var imported = 0;
          final bindings = <String, bool>{};
          final pendingBefore = Set<String>.of(_metadataPending);
          _batchMetadataDonors = donors;
          _batchMediaBindings = bindings;
          try {
            store.transaction(() {
              final end = (offset + 24).clamp(0, entries.length);
              for (var index = offset; index < end; index++) {
                final entry = entries[index];
                if (hideHidden && isHiddenEntry(entry)) continue;
                if (entry.directory) {
                  queue.add(entry.path);
                } else if (isVideo(entry.name)) {
                  addMedia(sourceId, entry, notify: false);
                  imported++;
                }
              }
              syncProfile.rememberMediaBindings(
                localIds: bindings.keys.where((id) => bindings[id]!),
                remoteIds: bindings.keys.where((id) => !bindings[id]!),
              );
              if (!setEquals(pendingBefore, _metadataPending)) {
                store.setLocal(
                  'metadata:automatic-pending',
                  _metadataPending.toList(),
                );
              }
            });
            // Imports only inherit the captured donors. Own writes need no
            // rescan, but edits/sync between batches must rebuild the index.
            donorRevision = store.recordsRevision('media');
          } catch (_) {
            _metadataPending
              ..clear()
              ..addAll(pendingBefore);
            rethrow;
          } finally {
            _batchMetadataDonors = null;
            _batchMediaBindings = null;
          }
          count += imported;
          status = '已发现 $count 个视频';
          notifyListeners();
          await Future<void>.delayed(Duration.zero);
        }
      }
      status = '扫描完成，共 $count 个视频';
      AppLog.instance.info('影视库', status);
    } on Cancelled {
      status = '扫描已取消，已导入的视频保留。';
      AppLog.instance.info('影视库', status);
    } catch (e) {
      status = '扫描未完成：${safeFailure(e).message}';
      AppLog.instance.error('影视库', status);
    } finally {
      try {
        await source?.close();
      } catch (_) {
        AppLog.instance.warning('来源', '扫描连接未能正常关闭。');
      }
      scanning = false;
      notifyListeners();
      // Process committed batches even after cancellation or a later failure.
      unawaited(_identifyPending());
    }
  }

  Future<List<Map<String, dynamic>>> searchBangumi(
    String title, {
    String? source,
    CancelToken? cancel,
  }) => catalog.search(title, source: source, cancel: cancel);

  void applyBangumi(
    String series,
    Map<String, dynamic> subject, {
    String? season,
    bool manual = true,
    String? targetSeason,
    Set<String>? mediaIds,
  }) {
    var applied = false;
    final fields = subjectMediaFields(subject);
    for (final item in _metadataRecords(mediaIds).where(
      (m) =>
          mediaIds != null ||
          (normalizedSeries('${m.data['series']}') ==
                  normalizedSeries(series) &&
              (season == null || '${m.data['season'] ?? ''}' == season)),
    )) {
      if (!manual &&
          (store.local('manualMetadata:${item.id}') == true ||
              item.data['bangumiId'] != null ||
              item.data['tmdbId'] != null)) {
        continue;
      }
      final data = {...item.data}
        ..remove('bangumiId')
        ..remove('tmdbId');
      store.save('media', item.id, {
        ...data,
        ...fields,
        if (manual && targetSeason != null) 'season': targetSeason,
        if (subject['mediaType'] == 'movie') ...{
          'season': '',
          'episode': '',
          'episodeTitle': '',
        },
      });
      store.removeLocal('episodeTitle:${item.id}');
      if (manual) store.setLocal('manualMetadata:${item.id}', true);
      applied = true;
    }
    if (applied) _prefetchPoster('${fields['poster']}');
    notifyListeners();
  }

  String progressKey(SyncRecord media) =>
      '${media.id}:${(store.local('location:${media.id}')?['size'] ?? media.data['size'] ?? 0)}';
  String watchedKey(SyncRecord media) => mediaWatchedKey(media);
  void requestArtworkSync(String mediaId) {
    if (_disposed) return;
    _syncArtworkIds.add(mediaId);
    requestProgressSync();
  }

  void requestProgressSync() {
    if (_disposed || !_foreground) return;
    _syncDebounce?.cancel();
    final remaining =
        _nextSyncAttempt?.difference(DateTime.now()).inMilliseconds ?? 0;
    _syncDebounce = Timer(
      Duration(milliseconds: remaining > 150 ? remaining + 1 : 150),
      () {
        if (!_disposed) unawaited(synchronize(quiet: true, sharedOnly: true));
      },
    );
  }

  void _watchSync(String address, String token) {
    final identity = '$address\u0000$token';
    if (!_foreground || activePlaybackMediaId != null) return;
    if (_syncWatchIdentity == identity && _syncWatch != null) return;
    _syncWatch?.cancel();
    _syncWatchIdentity = identity;
    final cancel = _syncWatch = CancelToken();
    Future<void> pause(Duration duration) async {
      if (cancel.cancelled) return;
      final elapsed = Completer<void>();
      final timer = Timer(duration, elapsed.complete);
      try {
        await Future.any([elapsed.future, cancel.whenCancelled]);
      } finally {
        // Winning the cancellation race must also release its delayed timer.
        timer.cancel();
      }
    }

    unawaited(() async {
      while (!_disposed && !cancel.cancelled) {
        final started = DateTime.now();
        try {
          final changed = await sync.waitForChanges(
            address,
            token,
            cancel: cancel,
          );
          if (cancel.cancelled || _disposed) return;
          realtimeConnected = true;
          if (changed) await synchronize(quiet: true, sharedOnly: true);
          if (DateTime.now().difference(started).inMilliseconds < 1000) {
            await pause(const Duration(seconds: 1));
          }
        } on Cancelled {
          return;
        } catch (_) {
          if (_disposed || cancel.cancelled) return;
          realtimeConnected = false;
          if (!_disposed) notifyListeners();
          await pause(const Duration(seconds: 3));
        }
      }
    }());
  }

  Future<void> synchronize({bool quiet = false, bool sharedOnly = false}) {
    if (_disposed || (quiet && !_foreground)) return Future.value();
    if (quiet && !sharedOnly && activePlaybackMediaId != null) {
      sharedOnly = true;
    }
    if (quiet &&
        sharedOnly &&
        (_nextSyncAttempt?.isAfter(DateTime.now()) ?? false)) {
      return Future.value();
    }
    _syncAgain = true;
    _syncNeedsFull |= !sharedOnly;
    _syncVisible |= !quiet;
    return _syncWork ??= _drainSync().whenComplete(() {
      _syncWork = null;
      if (_syncAgain && !_disposed) requestProgressSync();
    });
  }

  Future<void> _drainSync() async {
    for (
      var pass = 0;
      pass < 2 && _syncAgain && !_disposed && (_foreground || _syncVisible);
      pass++
    ) {
      final connectionRevision = _syncConnectionRevision;
      final full = _syncNeedsFull, visible = _syncVisible;
      // Compression/encryption and source snapshots can wait until playback
      // ends. Keep their IDs queued while only progress is being uploaded.
      final deferArtwork = !visible && activePlaybackMediaId != null;
      final artworkIds = deferArtwork
          ? <String>{}
          : Set<String>.of(_syncArtworkIds);
      if (!deferArtwork) _syncArtworkIds.clear();
      _syncAgain = false;
      _syncNeedsFull = false;
      _syncVisible = false;
      final succeeded = await _synchronize(
        quiet: !visible,
        sharedOnly: !full,
        artworkIds: artworkIds,
      );
      // Keep dirty records for the next retry instead of building an unbounded
      // queue from every playback tick while a network request is failing.
      if (!succeeded) {
        _syncArtworkIds.addAll(artworkIds);
        if (!_foreground) break;
        if (activePlaybackMediaId != null &&
            (full ||
                (_activeSyncAppliesProfile &&
                    _activeSync?.cancelled == true))) {
          // Opening playback deliberately stopped idle profile work. The next
          // checkpoint supplies fresh progress without a network-failure retry.
          break;
        }
        _syncNeedsFull |= full;
        if (!_disposed && connectionRevision != _syncConnectionRevision) {
          _nextSyncAttempt = null;
          continue;
        }
        if (!_disposed &&
            (settings['syncOrigin'] as String? ?? '').isNotEmpty) {
          _syncAgain = true;
          _nextSyncAttempt ??= DateTime.now().add(const Duration(seconds: 3));
        }
        break;
      }
    }
  }

  Future<bool> _synchronize({
    bool quiet = false,
    bool sharedOnly = false,
    Set<String> artworkIds = const {},
  }) async {
    final revision = _syncConnectionRevision;
    final cancel = _activeSync = CancelToken();
    final deferProfile = activePlaybackMediaId != null;
    _activeSyncAppliesProfile = !sharedOnly || !deferProfile;
    final address = settings['syncOrigin'] as String? ?? '';
    if (address.isEmpty) {
      _syncWatch?.cancel();
      _syncWatch = null;
      return false;
    }
    try {
      final token = await secrets.read(key: 'syncToken') ?? '';
      AppLog.instance.rememberSecret(token);
      if (_disposed ||
          cancel.cancelled ||
          revision != _syncConnectionRevision) {
        return false;
      }
      await sync.synchronize(
        address,
        token,
        sharedOnly: sharedOnly,
        artworkIds: artworkIds,
        deferProfile: deferProfile,
        playbackOnly: quiet && sharedOnly && deferProfile,
        cancel: cancel,
      );
      if (_disposed ||
          cancel.cancelled ||
          revision != _syncConnectionRevision) {
        return false;
      }
      _nextSyncAttempt = null;
      if (!deferProfile && _catalogProfileRevision != sync.profileRevision) {
        catalog.reloadSyncedDirectoryPreviews();
        _catalogProfileRevision = sync.profileRevision;
      }
      if (backgroundWork) {
        _watchSync(address, token);
      }
      status = '同步完成';
      if (!quiet) AppLog.instance.info('同步', status);
    } on Cancelled {
      return false;
    } catch (e) {
      if (_disposed ||
          cancel.cancelled ||
          revision != _syncConnectionRevision) {
        return false;
      }
      _nextSyncAttempt = DateTime.now().add(const Duration(seconds: 3));
      final message = '同步失败：${safeFailure(e).message}';
      if (!quiet) status = message;
      AppLog.instance.warning('同步', message);
      if (!_disposed && (!quiet || activePlaybackMediaId == null)) {
        notifyListeners();
      }
      return false;
    }
    if (!_disposed && (!quiet || activePlaybackMediaId == null)) {
      notifyListeners();
    }
    return true;
  }

  Future<void> resolveSyncConflict(
    SyncRecord remote, {
    required bool keepLocal,
  }) async {
    final token = await secrets.read(key: 'syncToken') ?? '';
    await sync.resolve(
      remote,
      keepLocal: keepLocal,
      address: settings['syncOrigin'] as String? ?? '',
      token: token,
    );
    catalog.reloadSyncedDirectoryPreviews();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (backgroundWork && _metadataTasksRestored) _persistMetadataTasks();
    _disposed = true;
    for (final task in _metadataTasks) {
      task._progressTimer?.cancel();
      task._cancel.cancel();
      if (!task._done.isCompleted) task._done.complete();
    }
    _posterCache?.close();
    _syncTimer?.cancel();
    _syncDebounce?.cancel();
    _syncResumeTimer?.cancel();
    _syncWatch?.cancel();
    _activeSync?.cancel();
    unawaited(sync.dispose());
    _librarySnapshotReader?.dispose();
    unawaited(_directoryMetadataWorker?.close());
    _directoryRecognitionCancel?.cancel();
    _metadataTimer?.cancel();
    _metadataCancel.cancel();
    _automaticReady?.complete();
    _automaticReady = null;
    unawaited(_previews?.close());
    if (secrets is LocalCredentialStorage) {
      unawaited((secrets as LocalCredentialStorage).close());
    }
    super.dispose();
  }
}

// Metadata contains small JSON maps/lists. Compare values rather than map/list
// identity so re-entering a recognized folder does not dirty every episode.
bool _equalMetadata(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (key) => b.containsKey(key) && _equalMetadata(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => i,
        ).every((i) => _equalMetadata(a[i], b[i]));
  }
  return a == b;
}
