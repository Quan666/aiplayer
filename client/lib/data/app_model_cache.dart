part of 'app_model.dart';

extension _CacheMaintenance on AppModel {
  Future<void> _clearCaches() async {
    final previews = _previews;
    final watchingSync = _syncWatch != null;
    try {
      // Stop old producers before deleting their outputs. This state change is
      // synchronous, including for retained pages that will not draw a frame.
      catalog.cacheMaintenance = true;
      catalog.invalidateMemoryCaches();
      mediaAi.invalidate();
      _directoryEnrichmentCancel.cancel();
      _directoryEnrichmentCancel = CancelToken();
      _directoryRecognitionCancel?.cancel();
      _metadataTimer?.cancel();
      _pauseAutomaticMetadataTasks();
      for (final task in _metadataTasks) {
        if (task.manual && task.running) cancelMetadataTask(task);
      }
      _syncTimer?.cancel();
      _syncResumeTimer?.cancel();
      _syncDebounce?.cancel();
      _syncWatch?.cancel();
      _syncWatch = null;
      realtimeConnected = false;
      _activeSync?.cancel();
      final worker = _directoryMetadataWorker;
      _directoryMetadataWorker = null;
      final previewPause = previews?.pause();
      _posterCache?.setActive(false);
      changed();
      await _syncWork;
      await worker?.close();
      await previewPause;
      await flushPlaybackPreviews();
      _metadataCancel.check();
      previews?.clearPending();
      // A reused cache owns its in-flight requests and drains their writes.
      // The database and remaining cache directory are cleared in a worker.
      await posterCache.clear();
      _metadataCancel.check();
      await clearStoredCaches(store, documents);
      _metadataCancel.check();
      catalog.invalidateMemoryCaches();
      mediaAi.invalidate();
      _seriesRefreshFailures.clear();
      _previewDiagnostics.clear();
      _previewFileChecks.clear();
      _librarySnapshotRevision = null;
      _continueWatchingRevision = null;
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      AppLog.instance.info('缓存', '已清除识别、目录、图片、弹幕与文件探测缓存。');
    } finally {
      catalog.cacheMaintenance = false;
      _clearingCaches = false;
      _clearCacheWork = null;
      cacheRevision++;
      if (!_disposed) {
        _posterCache?.setActive(_foreground);
        previews?.resume();
        _releaseAutomaticWork();
        if (_metadataPending.isNotEmpty) unawaited(_identifyPending());
        if (_syncAgain || watchingSync) {
          unawaited(synchronize(quiet: true));
        } else {
          _scheduleSyncMaintenance(full: true);
        }
        changed();
      }
    }
  }
}
