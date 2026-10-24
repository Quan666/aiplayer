part of 'app_model.dart';

extension _LibrarySourceRefresh on AppModel {
  Future<void> _refreshLibrarySources(CancelToken? caller) async {
    final token = _librarySourceRefreshCancel = CancelToken();
    final subscription = caller?.whenCancelled.asStream().listen(
      (_) => token.cancel(),
    );
    final configuredSources = sources;
    var sourceRevision = store.localKeyRevision('sources');
    var externalRevision = store.localPrefixRevision('externalSource:');
    String? activeSource;
    Object? externalConfiguration;
    final configuration = (preferences.hideHiddenFiles, cacheRevision);
    void checkCurrent() {
      caller?.check();
      token.check();
      if (_disposed ||
          !_foreground ||
          _clearingCaches ||
          configuration != (preferences.hideHiddenFiles, cacheRevision)) {
        token.cancel();
        throw const Cancelled();
      }
      // Other database connections invalidate broad revision scopes. Recheck
      // the small source configuration instead of mistaking our own media
      // commits for a source edit and stopping after the first directory.
      final nextSourceRevision = store.localKeyRevision('sources');
      if (nextSourceRevision != sourceRevision) {
        sourceRevision = nextSourceRevision;
        if (!_equalMetadata(configuredSources, sources)) {
          token.cancel();
          throw const Cancelled();
        }
      }
      final nextExternalRevision = store.localPrefixRevision('externalSource:');
      if (nextExternalRevision != externalRevision) {
        externalRevision = nextExternalRevision;
        if (activeSource != null &&
            !_equalMetadata(
              externalConfiguration,
              store.local('externalSource:$activeSource'),
            )) {
          token.cancel();
          throw const Cancelled();
        }
      }
    }

    void changed() {
      try {
        checkCurrent();
      } on Cancelled {
        token.cancel();
      }
    }

    addListener(changed);
    var failures = 0;
    try {
      checkCurrent();
      final snapshot = await loadLibrarySnapshot(cancel: token);
      checkCurrent();
      // A single connection/request is active at a time. Iterate the immutable
      // index directly instead of copying records or queueing one job per file.
      for (final folder in snapshot.folders.values) {
        checkCurrent();
        if (folder.records.isEmpty) continue;
        final anchor = folder.records.first;
        final location = snapshot.locations[anchor.id];
        if (location == null) continue;
        final sourceId = '${location['source']}';
        activeSource = sourceId;
        externalConfiguration = store.local('externalSource:$sourceId');
        final file = '${location['path']}'.replaceAll('\\', '/');
        // Direct links have no browsable parent directory.
        if (Uri.tryParse(file)?.hasScheme == true && sourceId != 'local') {
          continue;
        }
        final path = p.posix.dirname(file);
        SourceAdapter? connection;
        try {
          connection = await adapter(sourceId);
          checkCurrent();
          final entries = await _listSourceDirectory(connection, path, {
            token,
            _metadataCancel,
          });
          checkCurrent();
          final before = _directoryContentRevision;
          final guard = DirectoryListingGuard(
            anchor.id,
            sourceId,
            '${location['path']}',
          );
          try {
            final anchorId = folder.seriesKey == null ? null : anchor.id;
            if (store.path == ':memory:') {
              await synchronizeDirectoryListing(
                store,
                sourceId,
                path,
                entries,
                hideHidden: preferences.hideHiddenFiles,
                anchorId: anchorId,
                guard: guard,
                cancel: token,
              );
            } else {
              await (_directoryMetadataWorker ??= DirectoryMetadataWorker(
                store.path,
              )).synchronizeListing(
                sourceId,
                path,
                entries,
                hideHidden: preferences.hideHiddenFiles,
                anchorId: anchorId,
                guard: guard,
                cancel: token,
              );
            }
          } finally {
            if (!_disposed && before != _directoryContentRevision) {
              this.changed();
            }
          }
          checkCurrent();
        } on Cancelled {
          rethrow;
        } catch (error) {
          checkCurrent();
          failures++;
          AppLog.instance.warning('影视库刷新', safeFailure(error).message);
        } finally {
          try {
            await connection?.close();
          } catch (_) {
            // Keep the original listing outcome; another pull can reconnect.
          }
        }
      }
      checkCurrent();
      if (failures > 0) {
        throw AppFailure('$failures 个目录刷新失败，请检查来源连接后重试。');
      }
    } finally {
      removeListener(changed);
      unawaited(subscription?.cancel());
      if (identical(_librarySourceRefreshCancel, token)) {
        _librarySourceRefreshCancel = null;
      }
    }
  }
}
