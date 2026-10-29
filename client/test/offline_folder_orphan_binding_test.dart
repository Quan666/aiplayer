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

  test(
    'folder downloads all four files with orphaned library bindings',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.start();
        fixture.release();
        await _finished(fixture.model.downloads);
        expect(fixture.model.downloads.completedCount, 4);
        expect(
          fixture.model.downloads.entries.values.map(
            (entry) => entry.remotePath,
          ),
          unorderedEquals(_Fixture.paths),
        );
        expect(fixture.gets, unorderedEquals(_Fixture.paths));
        expect(fixture.store.all('media'), hasLength(4));
        for (final path in _Fixture.paths) {
          final media = fixture.model.sourceMedia('dav', path)!;
          expect(
            fixture.model.downloads.entryFor(media.id)?.isComplete,
            isTrue,
          );
          final local = await fixture.model.playbackLocation(media);
          expect(local?['source'], 'local');
          expect(
            await File(local!['path'] as String).readAsBytes(),
            fixture.bytes,
          );
        }
        expect(
          fixture.model.sourceMedia('dav', _Fixture.paths.first)?.id,
          'known',
        );
        for (var index = 1; index < _Fixture.paths.length; index++) {
          final id = 'orphan-$index';
          final media = fixture.model.sourceMedia(
            'dav',
            _Fixture.paths[index],
          )!;
          expect(media.id, id);
          expect(
            fixture.store.local('location:$id')['previewRevision'],
            'orphan-content-v1',
          );
          // The delayed media payload uses the synchronized binding's ID.
          // Resolving it must update this download's metadata without leaving
          // a second record that could obscure the completed local binding.
          fixture.store.resolve(
            SyncRecord(
              kind: 'media',
              id: id,
              version: 1,
              data: {...media.data, 'metadataTitle': '同步后的片名'},
            ),
            keepLocal: false,
          );
          final updated = fixture.store.get('media', id)!;
          expect(updated.data['metadataTitle'], '同步后的片名');
          expect(
            (await fixture.model.playbackLocation(updated))?['source'],
            'local',
          );
        }
        expect(fixture.store.all('media'), hasLength(4));
        expect(fixture.model.downloads.completedCount, 4);
        final snapshot = await fixture.model.loadLibrarySnapshot();
        expect(snapshot.localRecords, hasLength(4));
      } finally {
        await fixture.close();
      }
    },
  );

  test('folder admits orphan bindings synchronized after discovery', () async {
    final fixture = await _Fixture.create(orphanBindings: false);
    try {
      await fixture.start();
      for (var index = 1; index < _Fixture.paths.length; index++) {
        final id = 'late-orphan-$index';
        fixture.store.setLocal('location:$id', {
          'id': id,
          'source': 'dav',
          'path': _Fixture.paths[index],
          'size': fixture.bytes.length,
          'previewRevision': 'late-content-v1',
        });
      }
      fixture.release();
      await _finished(fixture.model.downloads);
      expect(fixture.model.downloads.completedCount, 4);
      expect(fixture.gets, unorderedEquals(_Fixture.paths));
      expect(fixture.store.all('media'), hasLength(4));
      for (var index = 1; index < _Fixture.paths.length; index++) {
        final id = 'late-orphan-$index';
        final media = fixture.model.sourceMedia('dav', _Fixture.paths[index])!;
        expect(media.id, id);
        expect(
          fixture.store.local('location:$id')['previewRevision'],
          'late-content-v1',
        );
        final download = fixture.model.downloads.entryFor(id)!;
        expect(download.isComplete, isTrue);
        expect(download.bindingRevision, 'late-content-v1');
        final local = await fixture.model.playbackLocation(media);
        expect(local?['source'], 'local');
        expect(
          await File(local!['path'] as String).readAsBytes(),
          fixture.bytes,
        );
      }
    } finally {
      await fixture.close();
    }
  });

  for (final physical in [false, true]) {
    test(
      'orphan recovery respects a ${physical ? 'physical deletion' : 'tombstone'} after discovery',
      () async {
        final fixture = await _Fixture.create();
        try {
          await fixture.start();
          final scan = fixture.model.downloads.entries.values.single;
          await fixture.model.downloads.pause(scan.mediaId);
          if (physical) {
            fixture.store.db.execute(
              'DELETE FROM records WHERE kind=? AND id=?',
              ['media', 'known'],
            );
          } else {
            final record = fixture.store.get('media', 'known')!;
            fixture.store.save('media', record.id, record.data, deleted: true);
          }
          // Keep the binding and avoid an import-exclusion marker: the captured
          // record revision must distinguish this deletion from an old orphan.
          expect(fixture.store.local('location:known'), isNotNull);
          fixture.release();
          await fixture.model.downloads.resume(scan.mediaId);
          await _finished(fixture.model.downloads);
          expect(fixture.model.downloads.completedCount, 3);
          expect(fixture.model.downloads.entryFor('known'), isNull);
          expect(
            fixture.model.sourceMedia('dav', _Fixture.paths.first),
            isNull,
          );
          expect(fixture.gets, unorderedEquals(_Fixture.paths.skip(1)));
          final removed = fixture.store.get('media', 'known');
          if (physical) {
            expect(removed, isNull);
          } else {
            expect(removed?.deleted, isTrue);
          }
        } finally {
          await fixture.close();
        }
      },
    );
  }
}

Future<void> _finished(OfflineDownloads downloads) async {
  final done = Completer<void>();
  void changed() {
    if (done.isCompleted) return;
    final failed = downloads.entries.values
        .where((entry) => entry.status == OfflineDownloadStatus.failed)
        .firstOrNull;
    if (failed != null) {
      done.completeError(StateError(failed.error));
    } else if (downloads.entries.isNotEmpty &&
        downloads.entries.values.every((entry) => entry.isComplete)) {
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

class _Fixture {
  static final paths = [
    for (var episode = 1; episode <= 4; episode++)
      'folder/Show S01E0$episode.mkv',
  ];
  final Directory directory;
  final AppStore store;
  final HttpServer server;
  final held = Completer<void>();
  final heldStarted = Completer<void>();
  final handlers = <Future<void>>{};
  final gets = <String>[];
  final bytes = List<int>.generate(512, (index) => index % 251);
  late final AppModel model;

  _Fixture(this.directory, this.store, this.server) {
    model = AppModel(store, directory, backgroundWork: false);
    server.listen((request) {
      late Future<void> handler;
      handler = _handle(request).whenComplete(() => handlers.remove(handler));
      handlers.add(handler);
    });
  }

  static Future<_Fixture> create({bool orphanBindings = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('folder-orphan-');
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
      'title': p.posix.basename(paths.first),
      'fileName': p.posix.basename(paths.first),
      'series': 'Show',
      'season': '1',
      'episode': '1',
      'size': 512,
    });
    for (var index = 0; index < paths.length; index++) {
      if (index > 0 && !orphanBindings) continue;
      final id = index == 0 ? 'known' : 'orphan-$index';
      store.setLocal('location:$id', {
        'id': id,
        'source': 'dav',
        'path': paths[index],
        'size': 512,
        if (index > 0) 'previewRevision': 'orphan-content-v1',
      });
    }
    return _Fixture(directory, store, server);
  }

  Future<void> start() async {
    await model.downloadSourceEntries('dav', [
      const SourceEntry(name: 'folder', path: 'folder/', directory: true),
    ]);
    await heldStarted.future.timeout(const Duration(seconds: 10));
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
            for (final file in paths) '/share/$file',
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
      } else if (path.startsWith('/share/') &&
          paths.contains(path.substring('/share/'.length))) {
        request.response.headers.set('accept-ranges', 'bytes');
        request.response.headers.set('etag', '"orphan-video-v1"');
        request.response.contentLength = bytes.length;
        if (request.method == 'GET') {
          gets.add(path.substring('/share/'.length));
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
      // Pausing a scan may cancel the held request before it is released.
    } on SocketException {
      // The previous attempt's response is intentionally discarded.
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
