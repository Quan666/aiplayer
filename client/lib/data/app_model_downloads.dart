part of 'app_model.dart';

extension AppModelDownloads on AppModel {
  Future<void> _restoreDownloads() =>
      _downloadsRestoreWork ??= _initializeDownloads();

  Future<void> _initializeDownloads() async {
    try {
      await downloads.initialize();
    } catch (error) {
      if (!_disposed) {
        AppLog.instance.warning('离线下载', safeFailure(error).message);
      }
    }
  }

  OfflineDownloads _getDownloads() => _downloads ??= (OfflineDownloads(
    directory: Directory(p.join(documents.path, 'offline')),
    storePath: store.path,
    sourceConfiguration: _downloadSourceConfiguration,
    active: _foreground && !_disposed,
  )..addListener(_downloadsChanged));

  Future<Map<String, dynamic>?> _downloadSourceConfiguration(String id) async {
    if (_disposed) return null;
    final source =
        sources.where((value) => value['id'] == id).firstOrNull ??
        (store.local('externalSource:$id') is Map
            ? Map<String, dynamic>.from(store.local('externalSource:$id'))
            : null);
    if (source == null) return null;
    final password = await secrets.read(key: 'source:$id') ?? '';
    if (_disposed) return null;
    final latest =
        sources.where((value) => value['id'] == id).firstOrNull ??
        (store.local('externalSource:$id') is Map
            ? Map<String, dynamic>.from(store.local('externalSource:$id'))
            : null);
    if (!mapEquals(source, latest)) return null;
    AppLog.instance.rememberSecret(password);
    return {...source, 'password': password};
  }

  void _downloadsChanged() {
    if (_disposed) return;
    final revision = _downloads?.completedRevision ?? 0;
    final libraryRevision = _downloads?.libraryRevision ?? 0;
    if (_downloadCompletedRevision == revision &&
        _downloadLibraryRevision == libraryRevision) {
      return;
    }
    _downloadCompletedRevision = revision;
    _downloadLibraryRevision = libraryRevision;
    // Only completed-file membership or newly registered folder media refresh
    // the library. Transfer progress has its own listenable.
    _notifyDownloadsChanged();
  }

  bool _canDownload(SyncRecord media) {
    if (_disposed || media.deleted) return false;
    final location = store.local('location:${media.id}');
    return location is Map &&
        location['source'] is String &&
        location['source'] != 'local' &&
        location['path'] is String;
  }

  Future<void> _downloadMedia(Iterable<SyncRecord> records) async {
    if (_disposed) throw const Cancelled();
    final ids = records.map((record) => record.id).take(2001).toList();
    if (ids.length > 2000) throw const AppFailure('单次最多选择 2000 个视频。');
    await _prepareAndDownload(ids: ids);
  }

  Future<void> _downloadSourceEntries(
    String sourceId,
    Iterable<SourceEntry> entries,
  ) async {
    if (_disposed) throw const Cancelled();
    if (sourceId == 'local') return;
    final selected = entries.take(2001).toList();
    if (selected.length > 2000) throw const AppFailure('单次最多选择 2000 个项目。');
    final files = selected.where((entry) => !entry.directory).toList();
    final folders = selected.where((entry) => entry.directory).toList();
    if (files.isNotEmpty) {
      await _prepareAndDownload(
        sourceId: sourceId,
        entries: files,
        allowEmpty: folders.isNotEmpty,
      );
    }
    for (final folder in folders) {
      if (_disposed) throw const Cancelled();
      await downloads.enqueueFolder(sourceId: sourceId, entry: folder);
    }
    if (selected.isEmpty) throw const AppFailure('没有可下载的视频或文件夹。');
  }

  Future<void> _prepareAndDownload({
    List<String> ids = const [],
    String? sourceId,
    List<SourceEntry> entries = const [],
    bool allowEmpty = false,
  }) async {
    final bindings = store.path == ':memory:'
        ? prepareOfflineMediaBindings(
            store,
            ids: ids,
            sourceId: sourceId,
            entries: entries,
          )
        : await (_directoryMetadataWorker ??= DirectoryMetadataWorker(
            store.path,
          )).prepareDownloads(
            ids: ids,
            sourceId: sourceId,
            entries: entries,
            cancel: _metadataCancel,
          );
    if (_disposed) throw const Cancelled();
    if (bindings.isEmpty) {
      if (allowEmpty) return;
      throw const AppFailure('没有可下载的视频位置。');
    }
    if (entries.isNotEmpty) _notifyDownloadsChanged();
    for (final (media, location) in bindings) {
      if (_disposed) throw const Cancelled();
      await downloads.enqueue(media: media, location: location);
    }
  }

  /// Resolving the local copy precedes credentials, network stat and bridges.
  /// The remote binding stays intact for fallback and shared progress keys.
  Future<Map<String, dynamic>?> _playbackLocation(SyncRecord media) async {
    if (_disposed) throw const Cancelled();
    final manager = downloads;
    if (store.path != ':memory:' && !manager.initialized) {
      await _restoreDownloads();
    }
    if (_disposed) throw const Cancelled();
    if (store.get('media', media.id)?.deleted == true) return null;
    final location = store.local('location:${media.id}');
    final downloaded = manager.entryFor(media.id);
    final matching =
        downloaded != null &&
        (location == null ||
            (location['source'] == downloaded.sourceId &&
                location['path'] == downloaded.remotePath &&
                (location['previewRevision'] ?? '') ==
                    downloaded.bindingRevision));
    String? path;
    if (matching) {
      try {
        path = await manager.localPath(media.id);
      } catch (error) {
        if (!_disposed) {
          AppLog.instance.warning('离线下载', safeFailure(error).message);
        }
      }
    }
    if (_disposed) throw const Cancelled();
    if (store.get('media', media.id)?.deleted == true) return null;
    final latest = store.local('location:${media.id}');
    if (latest?['source'] != location?['source'] ||
        latest?['path'] != location?['path'] ||
        latest?['previewRevision'] != location?['previewRevision']) {
      return latest is Map ? Map<String, dynamic>.from(latest) : null;
    }
    final entry = manager.entryFor(media.id);
    if (path != null && entry?.isComplete == true && entry?.localPath == path) {
      return {
        'id': media.id,
        'source': 'local',
        'path': path,
        'size': entry!.total,
        'offline': true,
      };
    }
    return location is Map ? Map<String, dynamic>.from(location) : null;
  }
}
