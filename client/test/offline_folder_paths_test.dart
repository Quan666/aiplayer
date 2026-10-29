import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => overrideSystemProxyPlatformForTesting('test'));

  test(
    'selected folder owns the disk and browser root across restart and overlapping selections',
    () async {
      final fixture = await _Fixture.create();
      const selected = 'NAS/2026-10/归还者 第二季';
      const relative = '归还者 第二季/Season 2/Show S02E01.mkv';
      try {
        await fixture.enqueue('dav', selected);
        await _completed(fixture.downloads, 2);
        final first = fixture.downloads.entries.values.singleWhere(
          (entry) => entry.remotePath == '$selected/Season 2/Show S02E01.mkv',
        );
        expect(first.downloadRoot, selected);
        expect(first.downloadRelativePath, relative);
        final diskParts = p.split(
          p.relative(first.localPath, from: fixture.offline.path),
        );
        expect(diskParts.skip(1), relative.split('/'));
        expect(diskParts.first, matches(RegExp(r'^[0-9a-f]{20}$')));
        final fileUri = Uri.file(first.localPath);
        expect(fileUri.scheme, 'file');
        expect(fileUri.toFilePath(), first.localPath);
        expect(await File.fromUri(fileUri).readAsBytes(), fixture.bytes);
        expect(
          fixture.store.local('location:${first.mediaId}')['path'],
          first.remotePath,
        );
        expect(
          fixture.downloads.completedLocations[first.mediaId]?['remotePath'],
          first.remotePath,
        );

        final before = {
          for (final entry in fixture.downloads.entries.values)
            entry.mediaId: entry.localPath,
        };
        await fixture.restart();
        expect({
          for (final entry in fixture.downloads.entries.values)
            entry.mediaId: entry.localPath,
        }, before);
        expect(
          fixture.downloads.entryFor(first.mediaId)?.downloadRelativePath,
          relative,
        );
        await fixture.enqueue('dav', selected);
        await _completed(fixture.downloads, 2);
        await fixture.enqueue('dav', 'NAS/2026-10');
        await _completed(fixture.downloads, 3);
        for (final entry in before.entries) {
          expect(fixture.downloads.entryFor(entry.key)?.localPath, entry.value);
        }
        expect(
          fixture.gets.where((path) => path == '/share/${first.remotePath}'),
          hasLength(1),
        );

        final snapshot = await fixture.snapshot();
        final root = snapshot.localDirectories['']!;
        expect(
          root.entries.map((entry) => entry.name),
          unorderedEquals(['归还者 第二季', '2026-10']),
        );
        expect(
          snapshot.localDirectories.values.any((entry) => entry.name == 'NAS'),
          isFalse,
        );
        final showEntry = root.entries.singleWhere(
          (entry) => entry.name == '归还者 第二季',
        );
        final show = snapshot.localDirectories[showEntry.path]!;
        final season =
            snapshot.localDirectories[show.entries
                .singleWhere((entry) => entry.directory)
                .path]!;
        expect(season.records.keys, [first.mediaId]);
        expect(await File(first.localPath).readAsBytes(), fixture.bytes);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'same folder names from separate sources and parents never overwrite each other',
    () async {
      final fixture = await _Fixture.create();
      const selected = 'NAS/2026-10/归还者 第二季';
      try {
        await fixture.enqueue('dav', selected);
        await _completed(fixture.downloads, 2);
        await fixture.enqueue('other', selected);
        await _completed(fixture.downloads, 4);
        await fixture.enqueue('dav', 'Archive/归还者 第二季');
        await _completed(fixture.downloads, 5);
        expect(
          fixture.downloads.entries.values
              .map((entry) => entry.localPath)
              .toSet(),
          hasLength(5),
        );
        final roots = (await fixture.snapshot()).localDirectories['']!.entries;
        expect(roots.map((entry) => entry.name), [
          '归还者 第二季',
          '归还者 第二季',
          '归还者 第二季',
        ]);
        expect(roots.map((entry) => entry.path).toSet(), hasLength(3));
        for (final entry in fixture.downloads.entries.values) {
          expect(await File(entry.localPath).readAsBytes(), fixture.bytes);
        }
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'selecting a source root uses its selected name and keeps child paths',
    () async {
      final fixture = await _Fixture.create();
      try {
        await fixture.enqueue('root', '', name: '我的视频');
        await _completed(fixture.downloads, 2);
        expect(
          fixture.downloads.entries.values.map(
            (entry) => entry.downloadRelativePath,
          ),
          unorderedEquals(['我的视频/Root.mkv', '我的视频/Extras/Extra.mkv']),
        );
        for (final entry in fixture.downloads.entries.values) {
          expect(
            p
                .split(p.relative(entry.localPath, from: fixture.offline.path))
                .skip(1),
            entry.downloadRelativePath!.split('/'),
          );
        }
        final snapshot = await fixture.snapshot();
        final selected =
            snapshot.localDirectories[snapshot
                .localDirectories['']!
                .entries
                .single
                .path]!;
        expect(selected.name, '我的视频');
        expect(selected.records, hasLength(1));
        expect(
          selected.entries.singleWhere((entry) => entry.directory).name,
          'Extras',
        );
      } finally {
        await fixture.close();
      }
    },
  );
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
    } else if (downloads.activeCount == 0 &&
        downloads.pausedCount == 0 &&
        downloads.completedCount > 0) {
      if (downloads.completedCount == count) {
        done.complete();
      } else {
        done.completeError(
          StateError(
            'Expected $count completed files, got ${downloads.completedCount}',
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
  final Directory directory;
  final AppStore store;
  final HttpServer server;
  final bytes = [1, 2, 3, 4];
  final gets = <String>[];
  final files = {
    '/share/NAS/2026-10/归还者 第二季/Season 2/Show S02E01.mkv',
    '/share/NAS/2026-10/归还者 第二季/Show S02E02.mkv',
    '/share/NAS/2026-10/Bonus.mkv',
    '/share/Archive/归还者 第二季/Show S02E02.mkv',
    '/root/Root.mkv',
    '/root/Extras/Extra.mkv',
  };
  late OfflineDownloads downloads;
  late final reader = LibrarySnapshotReader(store);
  Directory get offline => Directory(p.join(directory.path, 'offline'));
  Map<String, dynamic> config(String id) => {
    'id': id,
    'kind': 'webdav',
    'label': 'NAS',
    'url':
        'http://127.0.0.1:${server.port}/${id == 'root' ? 'root' : 'share'}/',
  };

  _Fixture(this.directory, this.store, this.server) {
    store.setLocal('sources', [
      for (final id in ['dav', 'other', 'root']) config(id),
    ]);
    server.listen(_handle);
    downloads = _manager();
  }

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp('folder-paths-');
    return _Fixture(
      directory,
      await AppStore.open(p.join(directory.path, 'library.sqlite')),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
  }

  OfflineDownloads _manager() => OfflineDownloads(
    directory: offline,
    storePath: store.path,
    sourceConfiguration: (id) async => config(id),
  );

  Future<void> enqueue(String source, String path, {String? name}) =>
      downloads.enqueueFolder(
        sourceId: source,
        entry: SourceEntry(
          name: name ?? p.posix.basename(path),
          path: path,
          directory: true,
        ),
      );

  Future<void> restart() async {
    await downloads.close();
    downloads.dispose();
    downloads = _manager();
    await downloads.initialize();
  }

  Future<LibrarySnapshot> snapshot() => reader.read(
    query: '',
    revision: (
      store.recordsRevision('media'),
      store.recordsRevision('progress'),
      store.locationRevision,
    ),
    offlineRevision: downloads.completedRevision,
    offlineLocations: downloads.completedLocations,
  );

  Future<void> _handle(HttpRequest request) async {
    final path = Uri.decodeComponent(request.uri.path);
    if (request.method == 'PROPFIND') {
      final children = <String>{path};
      for (final file in files.where((file) => file.startsWith(path))) {
        final remaining = file.substring(path.length).split('/');
        children.add(remaining.length == 1 ? file : '$path${remaining.first}/');
      }
      request.response.statusCode = HttpStatus.multiStatus;
      request.response.write('<d:multistatus xmlns:d="DAV:">');
      for (final child in children) {
        final href = Uri(pathSegments: child.split('/')).toString();
        request.response.write(
          '<d:response><d:href>$href</d:href><d:propstat><d:prop><d:resourcetype>${child.endsWith('/') ? '<d:collection/>' : ''}</d:resourcetype><d:getcontentlength>${bytes.length}</d:getcontentlength></d:prop></d:propstat></d:response>',
        );
      }
      request.response.write('</d:multistatus>');
    } else if (files.contains(path)) {
      request.response.headers.set('accept-ranges', 'bytes');
      request.response.headers.set('etag', '"folder-paths-v1"');
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
  }

  Future<void> close() async {
    reader.dispose();
    await downloads.close();
    downloads.dispose();
    store.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}
