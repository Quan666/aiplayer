import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<void> completed(OfflineDownloads downloads, String id) async {
  final done = Completer<void>();
  void changed() {
    final entry = downloads.entryFor(id);
    if (done.isCompleted) return;
    if (entry?.isComplete == true) done.complete();
    if (entry?.status == OfflineDownloadStatus.failed) {
      done.completeError(StateError(entry!.error));
    }
  }

  downloads.addListener(changed);
  changed();
  try {
    await done.future.timeout(const Duration(seconds: 15));
  } finally {
    downloads.removeListener(changed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late AppModel model;
  late HttpServer server;
  var requests = 0;
  final bytes = List<int>.generate(8192, (i) => i % 251);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('offline-integration-');
    store = await AppStore.open(p.join(directory.path, 'app.sqlite'));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = 0;
    server.listen((request) async {
      requests++;
      request.response.headers.set('accept-ranges', 'bytes');
      if (request.method == 'HEAD') {
        request.response.contentLength = bytes.length;
      } else {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'content-range',
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        );
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    });
    store.setLocal('settings', {'metadataStrategy': 'off'});
    store.setLocal('sources', [
      {
        'id': 'dav',
        'kind': 'webdav',
        'label': 'Media',
        'url': 'http://127.0.0.1:${server.port}/share/',
      },
    ]);
    model = AppModel(
      store,
      directory,
      secrets: const FlutterSecureStorage(),
      backgroundWork: false,
    );
    store.save('media', 'episode', {
      'title': 'Show S01E01.mp4',
      'fileName': 'Show S01E01.mp4',
      'series': 'Show',
      'episode': '1',
      'season': '1',
      'bangumiId': '42',
      'metadataTitle': '作品详情',
      'size': bytes.length,
    });
    store.setLocal('location:episode', {
      'id': 'episode',
      'source': 'dav',
      'path': '2026-10/Show S01E01.mp4',
      'size': bytes.length,
    });
  });

  tearDown(() async {
    await model.downloads.close();
    model.dispose();
    store.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'download is locally playable with shared details and original binding; delete falls back',
    () async {
      final media = store.get('media', 'episode')!;
      final initial = await model.loadLibrarySnapshot();
      expect(initial.localEntries, isEmpty);
      await model.downloadMedia([media]);
      await completed(model.downloads, media.id);
      final path = model.downloads.entryFor(media.id)!.localPath;
      expect(path, endsWith(p.join('share', '2026-10', 'Show S01E01.mp4')));
      expect(await File(path).readAsBytes(), bytes);
      final count = requests;
      final resolved = await model.playbackLocation(media);
      expect(resolved?['source'], 'local');
      expect(resolved?['path'], path);
      expect(requests, count);
      final snapshot = await model.loadLibrarySnapshot();
      expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
      expect(snapshot.localEntries.single.path, media.id);
      expect(snapshot.localRecords[media.id]?.data['bangumiId'], '42');
      expect(snapshot.locations[media.id]?['source'], 'dav');
      expect(
        store.local('location:episode')['path'],
        '2026-10/Show S01E01.mp4',
      );
      await model.deleteDownload(media.id);
      expect(await File(path).exists(), isFalse);
      expect((await model.loadLibrarySnapshot()).localEntries, isEmpty);
      expect((await model.playbackLocation(media))?['source'], 'dav');
      expect(store.get('media', media.id)?.deleted, isFalse);
    },
  );

  test(
    'missing local data invalidates membership and source rebind never uses old file',
    () async {
      final media = store.get('media', 'episode')!;
      await model.downloadMedia([media]);
      await completed(model.downloads, media.id);
      final path = model.downloads.entryFor(media.id)!.localPath;
      final original = Map<String, dynamic>.from(
        store.local('location:episode'),
      );
      store.setLocal('location:episode', {
        ...original,
        'path': 'replacement.mp4',
      });
      expect((await model.playbackLocation(media))?['path'], 'replacement.mp4');
      expect((await model.loadLibrarySnapshot()).localEntries, isEmpty);
      store.setLocal('location:episode', original);
      await File(path).delete();
      expect((await model.playbackLocation(media))?['source'], 'dav');
      expect(
        model.downloads.entryFor(media.id)?.status,
        OfflineDownloadStatus.failed,
      );
      expect((await model.loadLibrarySnapshot()).localEntries, isEmpty);
    },
  );

  test(
    'manual source download registers only selected entries in worker and reuses known metadata',
    () async {
      const selected = SourceEntry(
        name: 'Show S01E02.mp4',
        path: '2026-10/Show S01E02.mp4',
        size: 8192,
      );
      model.setForeground(false);
      await model.downloadSourceEntries('dav', [selected]);
      final record = model.sourceMedia('dav', selected.path)!;
      expect(record.data['episode'], '2');
      expect(store.all('media').length, 2);
      expect(
        model.downloads.entryFor(record.id)?.status,
        OfflineDownloadStatus.paused,
      );
      expect(requests, 0);
      await model.downloadSourceEntries('dav', [selected]);
      expect(store.all('media').length, 2);
      expect(model.sourceMedia('dav', selected.path)?.id, record.id);
      model.setForeground(true);
      await completed(model.downloads, record.id);
      final snapshot = await model.loadLibrarySnapshot();
      expect(snapshot.localRecords.keys, [record.id]);
    },
  );

  test(
    'removing library media deletes its offline copy without an orphan',
    () async {
      final media = store.get('media', 'episode')!;
      await model.downloadMedia([media]);
      await completed(model.downloads, media.id);
      final path = model.downloads.entryFor(media.id)!.localPath;
      await model.removeMedia(media);
      expect(await File(path).exists(), isFalse);
      expect(model.downloads.entryFor(media.id), isNull);
      expect(store.get('media', media.id)?.deleted, isTrue);
    },
  );

  test('opaque HTTP direct links can be selected for download', () async {
    store.setLocal('sources', [
      {
        'id': 'direct',
        'kind': 'http',
        'label': '我的视频',
        'url': 'http://127.0.0.1:${server.port}/stream?id=secret',
      },
    ]);
    const entry = SourceEntry(name: '我的视频', path: '', size: 8192);
    await model.downloadSourceEntries('direct', [entry]);
    final media = model.sourceMedia('direct', '')!;
    await completed(model.downloads, media.id);
    expect((await model.playbackLocation(media))?['source'], 'local');
    expect(
      model.downloads.entryFor(media.id)!.localPath,
      isNot(contains('secret')),
    );
  });

  test(
    'manual pause survives model lifecycle and explicit resume transfers',
    () async {
      final media = store.get('media', 'episode')!;
      model.setForeground(false);
      await model.downloadMedia([media]);
      expect(
        model.downloads.entryFor(media.id)?.status,
        OfflineDownloadStatus.paused,
      );
      expect(model.downloads.entryFor(media.id)?.userPaused, false);
      await model.downloads.pause(media.id);
      expect(model.downloads.entryFor(media.id)?.userPaused, true);
      model.setForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, 0);
      expect(
        model.downloads.entryFor(media.id)?.status,
        OfflineDownloadStatus.paused,
      );
      model.setForeground(false);
      await model.downloads.resume(media.id);
      expect(model.downloads.entryFor(media.id)?.userPaused, false);
      expect(
        model.downloads.entryFor(media.id)?.status,
        OfflineDownloadStatus.paused,
      );
      expect(requests, 0);
      model.setForeground(true);
      await completed(model.downloads, media.id);
      expect((await model.playbackLocation(media))?['source'], 'local');
    },
  );
}
