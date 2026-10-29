import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => overrideSystemProxyPlatformForTesting('test'));

  test(
    'folder scanning rejects sibling aliases and filters non-video files',
    () async {
      final fixture = await _Folders.create({
        'allowed': [
          ('allowed', true),
          ('', true),
          ('outside.mp4', false),
          ('allowed-other/outside.mp4', false),
          ('allowed/child/deep-unlisted.mp4', false),
          ('allowed/readme.nfo', false),
          ('allowed/good.mp4', false),
          ('allowed/child', true),
        ],
        'allowed/child': [
          ('allowed', true),
          ('outside.mp4', false),
          ('allowed/child/extra.mkv', false),
        ],
      });
      final manager = fixture.manager();
      try {
        await manager.enqueueFolder(
          sourceId: 'dav',
          entry: _folder('allowed/'),
        );
        await _until(
          () => manager.completedCount == 2 || manager.failedCount > 0,
        );
        expect(manager.failedCount, 0);
        expect(manager.entries.values.any((entry) => entry.isDirectory), false);
        expect(fixture.gets.toSet(), {
          'allowed/good.mp4',
          'allowed/child/extra.mkv',
        });
        expect(fixture.listed, ['allowed', 'allowed/child']);
        expect(fixture.store.records('media'), hasLength(2));
        expect(manager.completedLocations, hasLength(2));
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'equivalent folder selection is one persistent scan and traversal is rejected',
    () async {
      final fixture = await _Folders.create({
        'allowed': [('allowed/one.mp4', false)],
      });
      final manager = fixture.manager(active: false);
      try {
        await manager.enqueueFolder(
          sourceId: 'dav',
          entry: _folder('allowed/'),
        );
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('allowed'));
        expect(manager.taskIds, hasLength(1));
        expect(manager.pausedCount, 1);
        await expectLater(
          manager.enqueueFolder(sourceId: 'dav', entry: _folder('../escape')),
          throwsA(anything),
        );
        expect(manager.taskIds, hasLength(1));
        expect(fixture.listed, isEmpty);
        manager.setActive(true);
        await _until(() => manager.completedCount == 1);
        expect(fixture.listed, ['allowed']);
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'more than 2000 discovered videos fail before registration or child admission',
    () async {
      final fixture = await _Folders.create({
        'large': [
          for (var i = 0; i < 2001; i++) ('large/episode-$i.mp4', false),
        ],
      });
      final manager = fixture.manager();
      try {
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('large'));
        await _until(() => manager.failedCount == 1);
        expect(manager.taskIds, hasLength(1));
        expect(manager.entries.values.single.isDirectory, true);
        expect(manager.entries.values.single.error, contains('2000'));
        expect(
          manager.entries.values.single.discoveredFiles,
          lessThanOrEqualTo(2000),
        );
        expect(fixture.store.records('media'), isEmpty);
        expect(fixture.gets, isEmpty);
        expect(manager.completedLocations, isEmpty);
        await manager.cancel(manager.taskIds.single);
        expect(manager.entries, isEmpty);
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'directory frontier is bounded and does not recurse indefinitely',
    () async {
      final fixture = await _Folders.create({
        'wide': [for (var i = 0; i < 4096; i++) ('wide/folder-$i', true)],
      });
      final manager = fixture.manager();
      try {
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('wide'));
        await _until(() => manager.failedCount == 1);
        expect(manager.entries.values.single.error, contains('4096'));
        expect(fixture.listed, ['wide']);
        expect(fixture.gets, isEmpty);
        expect(fixture.store.records('media'), isEmpty);
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'empty folder remains an actionable failed scan and retry rescans it',
    () async {
      final fixture = await _Folders.create({
        'empty': [('empty/readme.txt', false)],
      });
      final manager = fixture.manager();
      try {
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('empty'));
        await _until(() => manager.failedCount == 1);
        final task = manager.entries.values.single;
        expect(task.isDirectory, true);
        expect(task.error, '文件夹中没有可下载的视频。');
        fixture.listings['empty'] = [('empty/new.mp4', false)];
        await manager.retry(task.mediaId);
        await _until(() => manager.completedCount == 1);
        expect(fixture.listed, ['empty', 'empty']);
        expect(manager.entryFor(task.mediaId), null);
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'admission rechecks global queue capacity before modifying the library',
    () async {
      final fixture = await _Folders.create({
        'folder': [('folder/one.mp4', false), ('folder/two.mp4', false)],
      });
      await fixture.directory.create();
      final db = sqlite3.open(
        p.join(fixture.directory.path, 'downloads.sqlite'),
      );
      db.execute(
        'CREATE TABLE downloads(id TEXT PRIMARY KEY,value TEXT NOT NULL)',
      );
      db.execute('BEGIN');
      for (var i = 0; i < 1999; i++) {
        final id = 'queued-$i';
        db.execute('INSERT INTO downloads VALUES(?,?)', [
          id,
          jsonEncode({
            'mediaId': id,
            'sourceId': 'dav',
            'remotePath': 'older/$i.mp4',
            'name': '$i.mp4',
            'status': 'failed',
            'localPath': '',
            'received': 0,
            'total': 32,
            'createdOrder': i + 1,
          }),
        ]);
      }
      db.execute('COMMIT');
      db.dispose();
      final manager = fixture.manager();
      try {
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('folder'));
        await _until(
          () => manager.entries.values.any(
            (entry) =>
                entry.isDirectory &&
                entry.status == OfflineDownloadStatus.failed,
          ),
        );
        expect(manager.taskIds, hasLength(2000));
        expect(
          manager.entries.values
              .singleWhere((entry) => entry.isDirectory)
              .error,
          contains('队列不足'),
        );
        expect(fixture.store.records('media'), isEmpty);
        expect(fixture.gets, isEmpty);
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'folder admission never overwrites an old completed task after media rebinding',
    () async {
      final fixture = await _Folders.create({
        'new': [('new/one.mp4', false)],
      });
      fixture.store.save('media', 'one', {
        'title': 'One',
        'fileName': 'one.mp4',
      });
      final original = {
        'id': 'one',
        'source': 'dav',
        'path': 'old.mp4',
        'size': 32,
      };
      fixture.store.setLocal('location:one', original);
      final manager = fixture.manager();
      try {
        await manager.enqueue(
          media: fixture.store.get('media', 'one')!,
          location: original,
        );
        await _until(() => manager.completedCount == 1);
        final completed = manager.entryFor('one')!;
        final revision = manager.completedRevision;
        fixture.store.setLocal('location:one', {
          ...original,
          'path': 'new/one.mp4',
          'previewRevision': 'new-binding',
        });
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('new'));
        await _until(() => manager.failedCount == 1);
        expect(manager.entryFor('one')!.isComplete, true);
        expect(manager.entryFor('one')!.remotePath, 'old.mp4');
        expect(manager.entryFor('one')!.localPath, completed.localPath);
        expect(manager.completedRevision, revision);
        expect(await File(completed.localPath).exists(), true);
        expect(fixture.gets, ['old.mp4']);
        expect(
          manager.entries.values
              .singleWhere((entry) => entry.isDirectory)
              .error,
          contains('旧视频位置'),
        );
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'reselecting a folder retries its failed files and keeps completed files',
    () async {
      final paths = [for (var i = 1; i <= 4; i++) 'Show/Show S01E0$i.mp4'];
      final fixture = await _Folders.create({
        'Show': [for (final path in paths) (path, false)],
      });
      fixture.failures.addAll(paths.skip(1));
      final manager = fixture.manager();
      try {
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('Show'));
        await _until(
          () => manager.completedCount == 1 && manager.failedCount == 3,
        );
        final originalIds = manager.taskIds.toSet();
        final completed = manager.entries.values.singleWhere(
          (entry) => entry.isComplete,
        );
        final completedRevision = manager.completedRevision;
        expect(completed.remotePath, paths.first);
        expect(fixture.gets, unorderedEquals(paths));

        fixture.failures.clear();
        final libraryRevision = manager.libraryRevision;
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('Show'));
        await _until(
          () =>
              manager.libraryRevision > libraryRevision &&
              manager.activeCount == 0,
        );
        expect(manager.completedCount, 4);
        expect(manager.failedCount, 0);
        expect(manager.taskIds.toSet(), originalIds);
        expect(
          manager.entryFor(completed.mediaId)?.localPath,
          completed.localPath,
        );
        expect(manager.completedRevision, completedRevision + 3);
        expect(fixture.store.records('media'), hasLength(4));
        expect(fixture.gets, unorderedEquals([...paths, ...paths.skip(1)]));
        for (final entry in manager.entries.values) {
          expect(
            await File(entry.localPath).readAsBytes(),
            List.generate(32, (i) => i),
          );
        }
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'folder retries preserve manual pauses and roll back after a binding conflict',
    () async {
      final paths = [for (var i = 1; i <= 4; i++) 'Show/Show S01E0$i.mp4'];
      final fixture = await _Folders.create({
        'Show': [for (final path in paths) (path, false)],
      });
      fixture.failures.addAll(paths.skip(1));
      fixture.store.save('media', 'paused', {
        'title': p.posix.basename(paths.first),
        'fileName': p.posix.basename(paths.first),
      });
      final pausedLocation = {
        'id': 'paused',
        'source': 'dav',
        'path': paths.first,
        'size': 32,
      };
      fixture.store.setLocal('location:paused', pausedLocation);
      final manager = fixture.manager(active: false);
      try {
        await manager.enqueue(
          media: fixture.store.get('media', 'paused')!,
          location: pausedLocation,
        );
        await manager.pause('paused');
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('Show'));
        manager.setActive(true);
        await _until(
          () => manager.failedCount == 3 && manager.activeCount == 0,
        );
        final originalIds = manager.taskIds.toSet();
        final failed = {
          for (final entry in manager.entries.values)
            if (entry.status == OfflineDownloadStatus.failed)
              entry.mediaId: entry,
        };
        expect(manager.entryFor('paused')?.userPaused, true);
        expect(manager.pausedCount, 1);
        expect(fixture.gets, unorderedEquals(paths.skip(1)));

        final stale = failed.values.singleWhere(
          (entry) => entry.remotePath == paths.last,
        );
        final location = Map<String, dynamic>.from(
          fixture.store.local('location:${stale.mediaId}'),
        );
        fixture.store.setLocal('location:${stale.mediaId}', {
          ...location,
          'previewRevision': 'rebound',
        });
        fixture.failures.clear();
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('Show'));
        await _until(
          () => manager.failedCount == 4 && manager.activeCount == 0,
        );
        final scan = manager.entries.values.singleWhere(
          (entry) => entry.isDirectory,
        );
        expect(scan.error, contains('旧视频位置'));
        expect(manager.entryFor('paused')?.userPaused, true);
        expect(manager.pausedCount, 1);
        expect(fixture.gets, unorderedEquals(paths.skip(1)));
        final database = sqlite3.open(
          p.join(fixture.directory.path, 'downloads.sqlite'),
          mode: OpenMode.readOnly,
        );
        try {
          for (final entry in failed.values) {
            expect(manager.entryFor(entry.mediaId)?.status, entry.status);
            expect(manager.entryFor(entry.mediaId)?.error, entry.error);
            final saved =
                jsonDecode(
                      database.select(
                            'SELECT value FROM downloads WHERE id=?',
                            [entry.mediaId],
                          ).single['value']
                          as String,
                    )
                    as Map;
            expect(saved['status'], 'failed');
            expect(saved['error'], entry.error);
          }
        } finally {
          database.dispose();
        }

        await manager.cancel(scan.mediaId);
        fixture.store.setLocal('location:${stale.mediaId}', location);
        await manager.enqueueFolder(sourceId: 'dav', entry: _folder('Show'));
        await _until(
          () => manager.completedCount == 3 && manager.activeCount == 0,
        );
        expect(manager.failedCount, 0);
        expect(manager.pausedCount, 1);
        expect(manager.entryFor('paused')?.userPaused, true);
        expect(manager.taskIds.toSet(), originalIds);
        expect(
          fixture.gets,
          unorderedEquals([...paths.skip(1), ...paths.skip(1)]),
        );
        await manager.resume('paused');
        await _until(() => manager.completedCount == 4);
        expect(fixture.gets.where((path) => path == paths.first), hasLength(1));
      } finally {
        await manager.close();
        manager.dispose();
        await fixture.close();
      }
    },
  );
}

SourceEntry _folder(String path) => SourceEntry(
  name: path.isEmpty ? 'Root' : path,
  path: path,
  directory: true,
);

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Folder operation timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Folders {
  final Directory root;
  final HttpServer server;
  final AppStore store;
  final Map<String, List<(String, bool)>> listings;
  final listed = <String>[], gets = <String>[];
  final failures = <String>{};
  Directory get directory => Directory(p.join(root.path, 'offline'));
  Map<String, dynamic> get source => {
    'id': 'dav',
    'kind': 'webdav',
    'url': 'http://127.0.0.1:${server.port}/dav/',
  };

  _Folders(this.root, this.server, this.store, this.listings) {
    store.setLocal('sources', [source]);
    server.listen((request) async {
      final raw = Uri.decodeComponent(
        request.uri.path,
      ).substring('/dav/'.length);
      final path = raw.replaceFirst(RegExp(r'/$'), '');
      final response = request.response;
      try {
        if (request.method == 'PROPFIND') {
          listed.add(path);
          response.statusCode = 207;
          response.headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          );
          response.write('<d:multistatus xmlns:d="DAV:">');
          for (final (child, directory)
              in listings[path] ?? <(String, bool)>[]) {
            final href = Uri(
              path: '/dav/$child${directory && child.isNotEmpty ? '/' : ''}',
            ).toString();
            response.write(
              '<d:response><d:href>${_xml(href)}</d:href><d:propstat><d:prop>'
              '<d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
              '<d:getcontentlength>32</d:getcontentlength></d:prop></d:propstat></d:response>',
            );
          }
          response.write('</d:multistatus>');
        } else if (request.method != 'HEAD' && failures.contains(path)) {
          gets.add(path);
          response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          response.headers.set('accept-ranges', 'bytes');
          response.contentLength = 32;
          if (request.method != 'HEAD') {
            gets.add(path);
            response.statusCode = 206;
            response.headers.set('content-range', 'bytes 0-31/32');
            response.add(List.generate(32, (i) => i));
          }
        }
        await response.close();
      } catch (_) {
        // The worker can cancel an in-flight request.
      }
    });
  }

  static Future<_Folders> create(
    Map<String, List<(String, bool)>> listings,
  ) async {
    final root = await Directory.systemTemp.createTemp('offline-folders-');
    return _Folders(
      root,
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      AppStore(p.join(root.path, 'library.sqlite')),
      listings,
    );
  }

  OfflineDownloads manager({bool active = true}) => OfflineDownloads(
    directory: directory,
    storePath: store.path,
    active: active,
    sourceConfiguration: (_) async => source,
  );

  Future<void> close() async {
    await server.close(force: true);
    store.dispose();
    await root.delete(recursive: true);
  }
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
