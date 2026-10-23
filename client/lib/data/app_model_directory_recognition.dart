part of 'app_model.dart';

extension AppModelDirectoryRecognition on AppModel {
  void cancelDirectoryRecognition() => _directoryRecognitionCancel?.cancel();

  /// Explicit recursive recognition is independent of automatic matching being
  /// enabled. A single bounded worker owns enumeration, matching and writes.
  Future<void> recognizeDirectory(
    String sourceId,
    String root, {
    CancelToken? cancel,
  }) async {
    if (_disposed || recognizingDirectory) return;
    final ownCancel = _directoryRecognitionCancel = CancelToken();
    recognizingDirectory = true;
    directoryRecognitionProgress = const DirectoryRecognitionProgress();
    status = '正在识别文件夹…';
    changed();
    final progressClock = Stopwatch()..start();
    var lastProgressAt = -150;
    unawaited(cancel?.whenCancelled.then((_) => ownCancel.cancel()));
    try {
      cancel?.check();
      if (sourceId == 'local') await AppleFileAccess.remember(root);
      final source = sourceId == 'local'
          ? <String, dynamic>{'kind': 'local'}
          : sources.where((value) => value['id'] == sourceId).firstOrNull ??
                (store.local('externalSource:$sourceId') is Map
                    ? Map<String, dynamic>.from(
                        store.local('externalSource:$sourceId'),
                      )
                    : null);
      if (source == null) throw const AppFailure('来源未配置，请先关联此设备上的视频位置。');
      final password = sourceId == 'local'
          ? ''
          : await secrets.read(key: 'source:$sourceId') ?? '';
      final credential = await secrets.read(key: 'tmdb.apiKey') ?? '';
      ownCancel.check();
      if (_disposed) throw const Cancelled();
      final worker = _directoryMetadataWorker ??= DirectoryMetadataWorker(
        store.path,
      );
      final result = await worker.recognize(
        sourceId,
        root,
        source: source,
        password: password,
        tmdbCredential: credential,
        hideHidden: preferences.hideHiddenFiles,
        strategy: preferences.metadataStrategy,
        cancel: ownCancel,
        onProgress: (value) {
          if (_disposed || ownCancel.cancelled) return;
          final previous = directoryRecognitionProgress;
          if (previous.folders == value.folders &&
              previous.videos == value.videos &&
              previous.matched == value.matched &&
              previous.failed == value.failed) {
            return;
          }
          directoryRecognitionProgress = value;
          status = '已识别 ${value.matched} / ${value.videos} 个视频';
          if (progressClock.elapsedMilliseconds - lastProgressAt < 150) return;
          lastProgressAt = progressClock.elapsedMilliseconds;
          changed();
        },
      );
      if (_disposed) return;
      directoryRecognitionProgress = result;
      status = result.videos == 0
          ? result.failed > 0
                ? '文件夹读取失败，请检查连接后重试。'
                : '此文件夹及子文件夹中没有视频。'
          : '识别完成，${result.matched} / ${result.videos} 个视频'
                '${result.failed > 0 ? '，${result.failed} 项未完成，可重试' : ''}';
      AppLog.instance.info('影视资料', status);
    } on Cancelled {
      if (!_disposed) status = '识别已取消，已完成的资料保留。';
    } catch (error) {
      if (!_disposed) {
        status = '识别未完成：${safeFailure(error).message}';
        AppLog.instance.warning('影视资料', status);
      }
    } finally {
      recognizingDirectory = false;
      if (identical(_directoryRecognitionCancel, ownCancel)) {
        _directoryRecognitionCancel = null;
      }
      if (!_disposed) changed();
    }
  }
}
