import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final change in [
    'rebind',
    'delete',
    'remove-location',
    'delete-download',
    'source-endpoint',
  ]) {
    test('local validation does not return stale data after $change', () async {
      final directory = await Directory.systemTemp.createTemp(
        'offline-resolution-',
      );
      final store = AppStore(':memory:');
      final manager = _Downloads();
      final model = _Model(store, directory, manager);
      final media = _seed(store);
      try {
        final resolving = model.playbackLocation(media);
        await manager.validationStarted.future;
        switch (change) {
          case 'rebind':
            store.setLocal('location:episode', {
              'id': 'episode',
              'source': 'new-source',
              'path': '/new/video.mkv',
              'size': 200,
            });
          case 'delete':
            store.save('media', media.id, media.data, deleted: true);
          case 'remove-location':
            store.removeLocal('location:episode');
          case 'delete-download':
            manager.downloaded = null;
          case 'source-endpoint':
            store.setLocal('location:episode', {
              ...store.local('location:episode') as Map,
              'previewRevision': 'changed-server',
            });
        }
        manager.validation.complete('/offline/video.mkv');
        final resolved = await resolving;
        if (change == 'rebind') {
          expect(resolved?['source'], 'new-source');
          expect(resolved?['path'], '/new/video.mkv');
        } else if (change == 'delete-download' || change == 'source-endpoint') {
          expect(resolved?['source'], 'dav');
          expect(resolved?['path'], '/share/video.mkv');
          expect(resolved?['offline'], isNot(true));
        } else {
          expect(resolved, isNull);
        }
        expect(manager.validationCalls, 1);
      } finally {
        model.dispose();
        manager.dispose();
        store.dispose();
        await directory.delete(recursive: true);
      }
    });
  }

  test(
    'failed local validation falls back to the current remote binding',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'offline-validation-error-',
      );
      final store = AppStore(':memory:');
      final manager = _Downloads();
      final model = _Model(store, directory, manager);
      final media = _seed(store);
      try {
        final resolving = model.playbackLocation(media);
        await manager.validationStarted.future;
        manager.validation.completeError(const AppFailure('下载服务已停止。'));
        final location = await resolving;
        expect(location?['source'], 'dav');
        expect(location?['path'], '/share/video.mkv');
        expect(location?['offline'], isNot(true));
      } finally {
        model.dispose();
        manager.dispose();
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('location is read again after delayed download restoration', () async {
    final directory = await Directory.systemTemp.createTemp(
      'offline-restoration-',
    );
    final store = await AppStore.open('${directory.path}/library.db');
    final manager = _Downloads()..initialization = Completer<void>();
    final model = _Model(store, directory, manager);
    final media = _seed(store);
    try {
      final resolving = model.playbackLocation(media);
      await manager.initializationStarted.future;
      store.setLocal('location:episode', {
        'source': 'replacement',
        'path': '/replacement.mkv',
      });
      manager.initialization!.complete();
      final location = await resolving;
      expect(location?['source'], 'replacement');
      expect(location?['path'], '/replacement.mkv');
      expect(manager.validationCalls, 0);
    } finally {
      model.dispose();
      manager.dispose();
      store.dispose();
      await directory.delete(recursive: true);
    }
  });

  test(
    'unavailable download catalog does not block original source playback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'offline-unavailable-',
      );
      final store = await AppStore.open('${directory.path}/library.db');
      final manager = _Downloads()
        ..initialization = Completer<void>()
        ..downloaded = null;
      final model = _Model(store, directory, manager);
      final media = _seed(store);
      try {
        final resolving = model.playbackLocation(media);
        await manager.initializationStarted.future;
        manager.initialization!.completeError(const AppFailure('下载目录不可用。'));
        final location = await resolving;
        expect(location?['source'], 'dav');
        expect(location?['path'], '/share/video.mkv');
        expect(manager.validationCalls, 0);
      } finally {
        model.dispose();
        manager.dispose();
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

SyncRecord _seed(AppStore store) {
  store.save('media', 'episode', {'title': 'video.mkv', 'size': 100});
  store.setLocal('location:episode', {
    'id': 'episode',
    'source': 'dav',
    'path': '/share/video.mkv',
    'size': 100,
  });
  return store.get('media', 'episode')!;
}

class _Model extends AppModel {
  _Model(super.store, super.documents, this.downloads)
    : super(backgroundWork: false);
  @override
  final OfflineDownloads downloads;
}

class _Downloads extends ChangeNotifier implements OfflineDownloads {
  OfflineDownload? downloaded = const OfflineDownload(
    mediaId: 'episode',
    sourceId: 'dav',
    remotePath: '/share/video.mkv',
    localPath: '/offline/video.mkv',
    name: 'video.mkv',
    status: OfflineDownloadStatus.completed,
    received: 100,
    total: 100,
  );
  final validationStarted = Completer<void>();
  final validation = Completer<String?>();
  final initializationStarted = Completer<void>();
  Completer<void>? initialization;
  int validationCalls = 0;
  @override
  bool get initialized => initialization == null;
  @override
  Future<void> initialize() async {
    if (!initializationStarted.isCompleted) initializationStarted.complete();
    await initialization?.future;
  }

  @override
  Future<String?> localPath(String mediaId) {
    validationCalls++;
    if (!validationStarted.isCompleted) validationStarted.complete();
    return validation.future;
  }

  @override
  OfflineDownload? entryFor(String mediaId) => downloaded;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
