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
      final payload = request.uri.path.endsWith('/empty.txt') ? <int>[] : bytes;
      request.response.headers.set('accept-ranges', 'bytes');
      if (request.method == 'HEAD') {
        request.response.contentLength = payload.length;
      } else if (payload.isEmpty) {
        request.response.contentLength = 0;
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

  test('download is locally playable with shared details and original binding; delete falls back', () async {
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
    expect(store.local('location:episode')['path'], '2026-10/Show S01E01.mp4');
    store.save('progress', model.progressKey(media), {
      'position': 15,
      'duration': 30,
    });
    await model.deleteLocalVideo(media);
    expect(await File(path).exists(), isFalse);
    expect((await model.loadLibrarySnapshot()).localEntries, isEmpty);
    expect((await model.playbackLocation(media))?['source'], 'dav');
    expect(store.get('media', media.id)?.deleted, isFalse);
    expect(store.get('progress', model.progressKey(media))?.deleted, isFalse);
    expect(
      store.get('progress', model.progressKey(media))?.data['position'],
      15,
    );
  });

  test('missing local data invalidates membership and source rebind never uses old file', () async {
    final media = store.get('media', 'episode')!;
    await model.downloadMedia([media]);
    await completed(model.downloads, media.id);
    final path = model.downloads.entryFor(media.id)!.localPath;
    final original = Map<String, dynamic>.from(store.local('location:episode'));
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
  });

  test('all source file extensions and empty files download without importing films', () async {
    final names = [
      '001.JPG',
      '001.ARW',
      '001.xmp',
      'song.FLAC',
      'notes.txt',
      'LICENSE',
      'empty.txt',
    ];
    final entries = [
      for (final name in names)
        SourceEntry(
          name: name,
          path: 'Album/$name',
          size: name == 'empty.txt' ? 0 : bytes.length,
        ),
    ];
    model.setForeground(false);
    await model.downloadSourceEntries('dav', entries);
    expect(store.all('media').map((record) => record.id), ['episode']);
    expect(model.downloads.entries, hasLength(entries.length));
    expect(requests, 0);
    await model.downloadSourceEntries('dav', entries);
    expect(model.downloads.entries, hasLength(entries.length));
    model.setForeground(true);
    for (final entry in entries) {
      final task = model.downloads.entryForSource('dav', entry.path)!;
      expect(task.downloadOnly, isTrue);
      await completed(model.downloads, task.mediaId);
      final path = (await model.downloads.localPath(task.mediaId))!;
      expect(path, endsWith(p.join('Album', entry.name)));
      expect(
        await File(path).readAsBytes(),
        entry.name == 'empty.txt' ? isEmpty : bytes,
      );
      expect(model.sourceMedia('dav', entry.path), isNull);
    }
    expect((await model.loadLibrarySnapshot()).localEntries, isEmpty);
    expect(store.all('media').map((record) => record.id), ['episode']);
    final count = requests;
    await model.downloads.close();
    model.dispose();
    model = AppModel(
      store,
      directory,
      secrets: const FlutterSecureStorage(),
      backgroundWork: false,
    );
    model.setForeground(false);
    await model.downloads.initialize();
    expect(model.downloads.completedCount, names.length);
    final restored = model.downloads.entryForSource('dav', entries.first.path)!;
    expect(restored.downloadOnly, isTrue);
    expect(await File(restored.localPath).readAsBytes(), bytes);
    await model.deleteDownload(restored.mediaId);
    expect(await File(restored.localPath).exists(), isFalse);
    expect(model.downloads.entryForSource('dav', entries.first.path), isNull);
    expect(requests, count);
    expect(store.all('media').map((record) => record.id), ['episode']);
  });

  test('personal video download reuses bytes after first playback without converting known films', () async {
    const personal = SourceEntry(
      name: 'Family.mp4',
      path: 'Album/Family.mp4',
      size: 8192,
    );
    await model.downloadSourceEntries('dav', [personal], personalMedia: true);
    final task = model.downloads.entryForSource('dav', personal.path)!;
    await completed(model.downloads, task.mediaId);
    expect(store.all('media').map((record) => record.id), ['episode']);
    final record = await model.preparePersonalMediaForPlayback('dav', personal);
    final count = requests;
    await model.downloadSourceEntries('dav', [personal], personalMedia: true);
    expect(model.downloads.entries, hasLength(1));
    expect(
      (await model.playbackLocation(record))?['path'],
      model.downloads.entryFor(task.mediaId)!.localPath,
    );
    expect(requests, count);
    final known = store.get('media', 'episode')!;
    await model.downloadSourceEntries('dav', [
      const SourceEntry(
        name: 'Show S01E01.mp4',
        path: '2026-10/Show S01E01.mp4',
        size: 8192,
      ),
    ], personalMedia: true);
    await completed(model.downloads, known.id);
    expect(store.get('media', known.id)!.data, known.data);
    expect(store.get('media', known.id)!.data['personalMedia'], isNull);
  });

  test('manual source download registers only selected entries in worker and reuses known metadata', () async {
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
  });

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
    'HTTP RAW direct links preserve their extension without film registration',
    () async {
      store.setLocal('sources', [
        {
          'id': 'direct',
          'kind': 'http',
          'label': '001.ARW',
          'url': 'http://127.0.0.1:${server.port}/photos/001.ARW?token=secret',
        },
      ]);
      const entry = SourceEntry(name: '001.ARW', path: '', size: 8192);
      await model.downloadSourceEntries('direct', [entry]);
      final task = model.downloads.entryForSource('direct', '')!;
      await completed(model.downloads, task.mediaId);
      final path = (await model.downloads.localPath(task.mediaId))!;
      expect(path, endsWith(p.join('photos', '001.ARW')));
      expect(path, isNot(contains('secret')));
      expect(await File(path).readAsBytes(), bytes);
      expect(model.sourceMedia('direct', ''), isNull);
      expect(store.all('media').map((record) => record.id), ['episode']);
    },
  );

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
