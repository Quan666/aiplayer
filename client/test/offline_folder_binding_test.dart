import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final retainBinding in [false, true]) {
    test('explicit folder download restores videos removed before selection '
        'with ${retainBinding ? 'retained' : 'cleared'} bindings', () async {
      final fixture = await _Fixture.create();
      try {
        final location = fixture.store.local('location:known');
        await fixture.model.removeMedia(fixture.store.get('media', 'known')!);
        expect(fixture.store.get('media', 'known')?.deleted, isTrue);
        expect(fixture.store.local('location:known'), isNull);
        if (retainBinding) {
          fixture.store.setLocal('location:known', location);
        }

        await fixture.start();
        fixture.release();
        await _completed(fixture.model.downloads, 2);

        expect(
          fixture.gets,
          unorderedEquals([
            '/share/${_Fixture.knownPath}',
            '/share/${_Fixture.keepPath}',
          ]),
        );
        final restored = fixture.model.sourceMedia('dav', _Fixture.knownPath);
        expect(restored, isNotNull);
        expect(restored!.deleted, isFalse);
        expect(
          fixture.model.downloads.entryFor(restored.id)?.isComplete,
          isTrue,
        );
        expect(fixture.store.all('media'), hasLength(2));
      } finally {
        await fixture.close();
      }
    });
  }

  test(
    'restarted folder scan restores videos removed before selection',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.model.removeMedia(fixture.store.get('media', 'known')!);
        await fixture.start();
        final scan = fixture.model.downloads.entries.values.single;
        await fixture.model.downloads.pause(scan.mediaId);
        expect(fixture.model.sourceMedia('dav', _Fixture.knownPath), isNull);
        await fixture.restart();
        expect(
          fixture.model.downloads.entryFor(scan.mediaId)?.userPaused,
          isTrue,
        );
        await fixture.model.downloads.resume(scan.mediaId);
        fixture.release();
        await _completed(fixture.model.downloads, 2);

        expect(
          fixture.gets,
          unorderedEquals([
            '/share/${_Fixture.knownPath}',
            '/share/${_Fixture.keepPath}',
          ]),
        );
        final restored = fixture.model.sourceMedia('dav', _Fixture.knownPath);
        expect(restored, isNotNull);
        expect(
          fixture.model.downloads.entryFor(restored!.id)?.isComplete,
          isTrue,
        );
        expect(fixture.store.all('media'), hasLength(2));
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'queued folder scan respects a deletion made before discovery',
    () async {
      final fixture = await _Fixture.create();
      try {
        fixture.model.downloads.setActive(false);
        await fixture.enqueue();
        expect(fixture.model.downloads.pausedCount, 1);
        expect(fixture.heldStarted.isCompleted, isFalse);
        await fixture.model.removeMedia(fixture.store.get('media', 'known')!);
        fixture.model.downloads.setActive(true);
        await fixture.heldStarted.future.timeout(const Duration(seconds: 10));
        fixture.release();
        await _completed(fixture.model.downloads, 1);

        expect(fixture.gets, ['/share/${_Fixture.keepPath}']);
        expect(fixture.model.sourceMedia('dav', _Fixture.knownPath), isNull);
        expect(fixture.store.get('media', 'known')?.deleted, isTrue);
        expect(fixture.store.all('media'), hasLength(1));
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'restarted scan does not restore a historically removed video deleted again',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.model.removeMedia(fixture.store.get('media', 'known')!);
        await fixture.start();
        final scan = fixture.model.downloads.entries.values.single;
        await fixture.model.downloads.pause(scan.mediaId);
        final restoredId = fixture.model.addMedia(
          'dav',
          const SourceEntry(
            name: 'Show S01E01.mkv',
            path: _Fixture.knownPath,
            size: 4096,
          ),
        );
        expect(fixture.store.get('media', restoredId)?.deleted, isFalse);
        await fixture.model.removeMedia(
          fixture.store.get('media', restoredId)!,
        );
        await fixture.restart();
        await fixture.model.downloads.resume(scan.mediaId);
        fixture.release();
        await _completed(fixture.model.downloads, 1);

        expect(fixture.gets, ['/share/${_Fixture.keepPath}']);
        expect(fixture.model.sourceMedia('dav', _Fixture.knownPath), isNull);
        expect(fixture.store.get('media', restoredId)?.deleted, isTrue);
        expect(fixture.model.downloads.entryFor(restoredId), isNull);
        expect(fixture.store.all('media'), hasLength(1));
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'restored folder scan never revives a video deleted after discovery',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.start();
        final scan = fixture.model.downloads.entries.values.single;
        expect(scan.isDirectory, isTrue);
        await fixture.model.downloads.pause(scan.mediaId);
        await fixture.model.removeMedia(fixture.store.get('media', 'known')!);
        await fixture.restart();
        expect(
          fixture.model.downloads.entryFor(scan.mediaId)?.userPaused,
          isTrue,
        );
        await fixture.model.downloads.resume(scan.mediaId);
        fixture.release();
        await _completed(fixture.model.downloads, 1);

        expect(fixture.store.get('media', 'known')?.deleted, isTrue);
        expect(fixture.model.sourceMedia('dav', _Fixture.knownPath), isNull);
        expect(fixture.store.all('media'), hasLength(1));
        expect(fixture.gets, ['/share/${_Fixture.keepPath}']);
        expect(fixture.model.downloads.entryFor('known'), isNull);
        expect(fixture.model.downloads.completedLocations, hasLength(1));
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'folder scan does not recreate an old path after its media is rebound',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.start();
        fixture.model.addMedia(
          'dav',
          const SourceEntry(
            name: 'replacement.mkv',
            path: 'replacement.mkv',
            size: 4096,
          ),
          associateId: 'known',
        );
        fixture.release();
        await _completed(fixture.model.downloads, 1);

        expect(
          fixture.store.local('location:known')['path'],
          'replacement.mkv',
        );
        expect(fixture.model.sourceMedia('dav', _Fixture.knownPath), isNull);
        expect(fixture.store.all('media'), hasLength(2));
        expect(fixture.gets, ['/share/${_Fixture.keepPath}']);
        expect(fixture.model.downloads.entryFor('known'), isNull);
      } finally {
        await fixture.close();
      }
    },
  );

  test('folder scan preserves metadata edited after discovery', () async {
    final fixture = await _Fixture.create();
    try {
      await fixture.start();
      final before = fixture.store.get('media', 'known')!;
      fixture.store.save('media', before.id, {
        ...before.data,
        'metadataTitle': '人工修正的片名',
        'episodeTitle': '人工修正的集名',
        'episode': '8',
        'bangumiId': '9876',
      });
      fixture.release();
      await _completed(fixture.model.downloads, 2);

      final after = fixture.store.get('media', 'known')!;
      expect(after.data['metadataTitle'], '人工修正的片名');
      expect(after.data['episodeTitle'], '人工修正的集名');
      expect(after.data['episode'], '8');
      expect(after.data['bangumiId'], '9876');
      expect(fixture.model.sourceMedia('dav', _Fixture.knownPath)?.id, 'known');
      expect(
        fixture.gets,
        unorderedEquals([
          '/share/${_Fixture.knownPath}',
          '/share/${_Fixture.keepPath}',
        ]),
      );
      final snapshot = await fixture.model.loadLibrarySnapshot();
      expect(snapshot.localRecords['known']?.data['metadataTitle'], '人工修正的片名');
    } finally {
      await fixture.close();
    }
  });
}

Future<void> _completed(OfflineDownloads downloads, int count) async {
  final done = Completer<void>();
  void changed() {
    if (done.isCompleted) return;
    final failed = downloads.entries.values
        .where((entry) => entry.status == OfflineDownloadStatus.failed)
        .firstOrNull;
    if (failed != null) {
      done.completeError(StateError(failed.error));
    } else if (downloads.completedCount > count) {
      done.completeError(
        StateError('Unexpected download: ${downloads.entries.keys}'),
      );
    } else if (downloads.completedCount > 0 &&
        downloads.activeCount == 0 &&
        downloads.pausedCount == 0) {
      if (downloads.completedCount == count) {
        done.complete();
      } else {
        done.completeError(
          StateError(
            'Expected $count completed downloads, got '
            '${downloads.completedCount}: '
            '${downloads.entries.values.map((entry) => entry.remotePath).toList()}',
          ),
        );
      }
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

class _Fixture {
  static const knownPath = 'folder/Show S01E01.mkv';
  static const keepPath = 'folder/Show S01E02.mkv';
  final Directory directory;
  final AppStore store;
  final HttpServer server;
  final held = Completer<void>();
  final heldStarted = Completer<void>();
  final gets = <String>[];
  final handlers = <Future<void>>{};
  final bytes = List<int>.generate(4096, (i) => i % 251);
  late AppModel model;

  _Fixture(this.directory, this.store, this.server) {
    model = AppModel(store, directory, backgroundWork: false);
    server.listen((request) {
      late Future<void> handler;
      handler = _handle(request).whenComplete(() => handlers.remove(handler));
      handlers.add(handler);
    });
  }

  static Future<_Fixture> create() async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'offline-folder-binding-',
    );
    final store = await AppStore.open(p.join(directory.path, 'app.sqlite'));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.setLocal('sources', [
      {
        'id': 'dav',
        'kind': 'webdav',
        'label': 'DAV',
        'url': 'http://127.0.0.1:${server.port}/share/',
      },
    ]);
    store.save('media', 'known', {
      'title': 'Show S01E01.mkv',
      'fileName': 'Show S01E01.mkv',
      'series': 'Show',
      'season': '1',
      'episode': '1',
      'metadataTitle': 'Original Show',
      'size': 4096,
    });
    store.setLocal('location:known', {
      'id': 'known',
      'source': 'dav',
      'path': knownPath,
      'size': 4096,
    });
    return _Fixture(directory, store, server);
  }

  Future<void> enqueue() => model.downloadSourceEntries('dav', [
    const SourceEntry(name: 'folder', path: 'folder/', directory: true),
  ]);

  Future<void> start() async {
    await enqueue();
    await heldStarted.future.timeout(const Duration(seconds: 10));
  }

  Future<void> restart() async {
    await model.downloads.close();
    model.dispose();
    model = AppModel(store, directory, backgroundWork: false);
    await model.downloads.initialize();
  }

  void release() {
    if (!held.isCompleted) held.complete();
  }

  Future<void> _handle(HttpRequest request) async {
    final path = Uri.decodeComponent(request.uri.path);
    try {
      if (request.method == 'PROPFIND') {
        if (path == '/share/folder/hold/') {
          if (!heldStarted.isCompleted) heldStarted.complete();
          await held.future;
        }
        final children = switch (path) {
          '/share/folder/' => [
            '/share/$knownPath',
            '/share/$keepPath',
            '/share/folder/hold/',
          ],
          '/share/folder/hold/' => <String>[],
          _ => null,
        };
        if (children == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.statusCode = HttpStatus.multiStatus;
          final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
          for (final child in [path, ...children]) {
            xml.write(
              '<d:response><d:href>${Uri(path: child)}</d:href>'
              '<d:propstat><d:prop><d:resourcetype>'
              '${child.endsWith('/') ? '<d:collection/>' : ''}'
              '</d:resourcetype><d:getcontentlength>${bytes.length}</d:getcontentlength>'
              '</d:prop></d:propstat></d:response>',
            );
          }
          request.response.write('$xml</d:multistatus>');
        }
      } else if (path == '/share/$knownPath' || path == '/share/$keepPath') {
        request.response.headers.set('accept-ranges', 'bytes');
        request.response.headers.set('etag', '"binding-video-v1"');
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
      // A paused attempt may close its pending PROPFIND before release.
    } on SocketException {
      // A late response to the previous attempt is intentionally discarded.
    }
  }

  Future<void> close() async {
    release();
    await model.downloads.close();
    model.dispose();
    await server.close(force: true);
    await Future.wait(List<Future<void>>.of(handlers));
    store.dispose();
    await directory.delete(recursive: true);
  }
}
