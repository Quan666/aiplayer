import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<void> _waitFor(OfflineDownloads downloads, bool Function() ready) async {
  final done = Completer<void>();
  void changed() {
    if (done.isCompleted) return;
    final failure = downloads.entries.values
        .where((entry) => entry.status == OfflineDownloadStatus.failed)
        .firstOrNull;
    if (failure != null) {
      done.completeError(StateError(failure.error));
    } else if (ready()) {
      done.complete();
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

Future<void> _quiet() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => overrideSystemProxyPlatformForTesting('test'));

  for (final all in [false, true]) {
    test(
      '${all ? 'pauseAll' : 'manual pause'} survives foreground and restart, then scans only unfinished folders',
      () async {
        final fixture = await _DavFolderFixture.create();
        var downloads = fixture.manager();
        try {
          await downloads.enqueueFolder(sourceId: 'dav', entry: fixture.root);
          final id = downloads.entries.values
              .singleWhere((entry) => entry.isDirectory)
              .mediaId;
          await fixture.heldStarted.future.timeout(const Duration(seconds: 10));
          if (all) {
            await downloads.pauseAll().timeout(const Duration(seconds: 5));
          } else {
            await downloads.pause(id).timeout(const Duration(seconds: 5));
          }
          final paused = downloads.entryFor(id)!;
          expect(paused.status, OfflineDownloadStatus.paused);
          expect(paused.userPaused, isTrue);
          expect(paused.scannedFolders, 2);
          expect(paused.discoveredFiles, 2);
          expect(downloads.taskIds, [id]);
          expect(fixture.gets, isEmpty);
          expect(fixture.store.all('media'), isEmpty);

          downloads.setActive(false);
          downloads.setActive(true);
          fixture.releaseHeld();
          await _quiet();
          expect(fixture.listed, [
            fixture.basePath,
            fixture.seenPath,
            fixture.heldPath,
          ]);
          expect(downloads.entryFor(id)?.userPaused, isTrue);
          expect(downloads.taskIds, [id]);
          expect(fixture.gets, isEmpty);

          await downloads.close();
          downloads.dispose();
          downloads = fixture.manager();
          await downloads.initialize();
          final restored = downloads.entryFor(id)!;
          expect(restored.status, OfflineDownloadStatus.paused);
          expect(restored.userPaused, isTrue);
          expect(restored.scannedFolders, paused.scannedFolders);
          expect(restored.discoveredFiles, paused.discoveredFiles);
          downloads.setActive(false);
          if (all) {
            await downloads.resumeAll();
          } else {
            await downloads.resume(id);
          }
          expect(downloads.entryFor(id)?.status, OfflineDownloadStatus.paused);
          expect(downloads.entryFor(id)?.userPaused, isFalse);
          await _quiet();
          expect(fixture.listed, [
            fixture.basePath,
            fixture.seenPath,
            fixture.heldPath,
          ]);
          expect(fixture.gets, isEmpty);

          downloads.setActive(true);
          await _waitFor(
            downloads,
            () =>
                downloads.completedCount == 4 &&
                !downloads.entries.values.any((entry) => entry.isDirectory),
          );
          expect(fixture.listed, [
            fixture.basePath,
            fixture.seenPath,
            fixture.heldPath,
            fixture.heldPath,
            fixture.lastPath,
          ]);
          expect(fixture.gets, unorderedEquals(fixture.videos));
          expect(fixture.store.all('media'), hasLength(4));
          expect(downloads.entryFor(id), isNull);
          expect(
            downloads.activeCount +
                downloads.pausedCount +
                downloads.failedCount,
            0,
          );
        } finally {
          fixture.releaseHeld();
          await downloads.close();
          downloads.dispose();
          await fixture.close();
        }
      },
    );
  }

  test(
    'cancelled folder ignores its late DAV response and stays cancelled after restart',
    () async {
      final fixture = await _DavFolderFixture.create();
      var downloads = fixture.manager();
      try {
        await downloads.enqueueFolder(sourceId: 'dav', entry: fixture.root);
        final id = downloads.entries.values
            .singleWhere((entry) => entry.isDirectory)
            .mediaId;
        await fixture.heldStarted.future.timeout(const Duration(seconds: 10));
        await downloads.cancel(id).timeout(const Duration(seconds: 5));
        expect(downloads.taskIds, isEmpty);
        fixture.releaseHeld();
        downloads.setActive(false);
        downloads.setActive(true);
        await _quiet();
        expect(downloads.taskIds, isEmpty);
        expect(fixture.listed, [
          fixture.basePath,
          fixture.seenPath,
          fixture.heldPath,
        ]);
        expect(fixture.gets, isEmpty);
        expect(fixture.store.all('media'), isEmpty);
        await downloads.close();
        downloads.dispose();
        downloads = fixture.manager();
        await downloads.initialize();
        await _quiet();
        expect(downloads.entries, isEmpty);
        expect(fixture.listed, [
          fixture.basePath,
          fixture.seenPath,
          fixture.heldPath,
        ]);
        expect(fixture.gets, isEmpty);
        expect(fixture.store.all('media'), isEmpty);
      } finally {
        fixture.releaseHeld();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'inactive folder queue and paused scan admit no requests or child tasks without frames',
    () async {
      final fixture = await _DavFolderFixture.create();
      final downloads = fixture.manager(active: false);
      try {
        await downloads.enqueueFolder(sourceId: 'dav', entry: fixture.root);
        final id = downloads.entries.values
            .singleWhere((entry) => entry.isDirectory)
            .mediaId;
        await _quiet();
        expect(fixture.listed, isEmpty);
        expect(downloads.entryFor(id)?.status, OfflineDownloadStatus.paused);
        downloads.setActive(true);
        await fixture.heldStarted.future.timeout(const Duration(seconds: 10));
        downloads.setActive(false);
        await _waitFor(
          downloads,
          () => downloads.entryFor(id)?.status == OfflineDownloadStatus.paused,
        );
        expect(downloads.entryFor(id)?.userPaused, isFalse);
        final requests = List<String>.of(fixture.listed);
        fixture.releaseHeld();
        // These are ordinary Dart async waits, not widget pumps or rendered frames.
        await _quiet();
        await _quiet();
        expect(fixture.listed, requests);
        expect(fixture.gets, isEmpty);
        expect(downloads.taskIds, [id]);
        expect(fixture.store.all('media'), isEmpty);
        downloads.setActive(true);
        await _waitFor(downloads, () => downloads.completedCount == 4);
        expect(
          fixture.listed.where((path) => path == fixture.basePath),
          hasLength(1),
        );
        expect(
          fixture.listed.where((path) => path == fixture.seenPath),
          hasLength(1),
        );
        expect(
          fixture.listed.where((path) => path == fixture.heldPath),
          hasLength(2),
        );
        expect(
          downloads.entries.values.any((entry) => entry.isDirectory),
          isFalse,
        );
        expect(fixture.gets, unorderedEquals(fixture.videos));
      } finally {
        fixture.releaseHeld();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );
}

class _DavFolderFixture {
  final Directory directory;
  final AppStore store;
  final HttpServer server;
  final heldStarted = Completer<void>();
  Completer<void>? _held = Completer<void>();
  final listed = <String>[];
  final gets = <String>[];
  final _handlers = <Future<void>>{};
  final bytes = List<int>.generate(4096, (index) => index % 251);
  final basePath = '/share/folder/';
  final seenPath = '/share/folder/seen/';
  final heldPath = '/share/folder/seen/held/';
  final lastPath = '/share/folder/seen/held/last/';
  final root = const SourceEntry(
    name: 'folder',
    path: 'folder/',
    directory: true,
  );
  late final videos = [
    '$basePath/root.mkv'.replaceAll('//', '/'),
    '${seenPath}seen.mkv',
    '${heldPath}held.mkv',
    '${lastPath}last.mkv',
  ];
  late final Map<String, dynamic> configuration = {
    'id': 'dav',
    'kind': 'webdav',
    'label': 'DAV',
    'url': 'http://127.0.0.1:${server.port}/share/',
  };

  _DavFolderFixture(this.directory, this.store, this.server) {
    store.setLocal('settings', {'metadataStrategy': 'off'});
    store.setLocal('sources', [configuration]);
    server.listen((request) {
      late Future<void> handler;
      handler = _handle(request).whenComplete(() => _handlers.remove(handler));
      _handlers.add(handler);
    });
  }

  static Future<_DavFolderFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'offline-folder-lifecycle-',
    );
    final store = await AppStore.open(p.join(directory.path, 'app.sqlite'));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _DavFolderFixture(directory, store, server);
  }

  OfflineDownloads manager({bool active = true}) => OfflineDownloads(
    directory: Directory(p.join(directory.path, 'offline')),
    storePath: store.path,
    active: active,
    sourceConfiguration: (_) async => {...configuration, 'password': ''},
  );

  void releaseHeld() {
    final held = _held;
    _held = null;
    if (held != null && !held.isCompleted) held.complete();
  }

  Future<void> _handle(HttpRequest request) async {
    final path = Uri.decodeComponent(request.uri.path);
    try {
      if (request.method == 'PROPFIND') {
        listed.add(path);
        if (path == heldPath && _held != null) {
          final held = _held!;
          if (!heldStarted.isCompleted) heldStarted.complete();
          await held.future;
        }
        final children = <String, List<String>>{
          basePath: [videos[0], seenPath],
          seenPath: [videos[1], heldPath],
          heldPath: [videos[2], lastPath],
          lastPath: [videos[3]],
        }[path];
        if (children == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.statusCode = HttpStatus.multiStatus;
          final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
          for (final child in [path, ...children]) {
            xml.write(
              '<d:response><d:href>${Uri(path: child)}</d:href><d:propstat><d:prop><d:resourcetype>${child.endsWith('/') ? '<d:collection/>' : ''}</d:resourcetype><d:getcontentlength>${bytes.length}</d:getcontentlength></d:prop></d:propstat></d:response>',
            );
          }
          request.response.write('$xml</d:multistatus>');
        }
      } else if (videos.contains(path)) {
        request.response.headers.set('accept-ranges', 'bytes');
        request.response.headers.set('etag', '"folder-video-v1"');
        request.response.contentLength = bytes.length;
        if (request.method == 'GET') {
          gets.add(path);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'content-range',
            'bytes 0-${bytes.length - 1}/${bytes.length}',
          );
          request.response.add(bytes);
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } on HttpException {
      // Cancellation intentionally closes an in-flight PROPFIND connection.
    } on SocketException {
      // A response released after pause/cancel is intentionally ignored.
    }
  }

  Future<void> close() async {
    releaseHeld();
    await server.close(force: true);
    await Future.wait(List<Future<void>>.of(_handlers));
    store.dispose();
    await directory.delete(recursive: true);
  }
}
