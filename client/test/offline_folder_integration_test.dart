import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Future<void> _completedFiles(OfflineDownloads downloads, int count) async {
  final done = Completer<void>();
  void changed() {
    if (done.isCompleted) return;
    final failure = downloads.entries.values
        .where((entry) => entry.status == OfflineDownloadStatus.failed)
        .firstOrNull;
    if (failure != null) {
      done.completeError(StateError(failure.error));
    } else if (downloads.completedCount == count &&
        downloads.activeCount == 0 &&
        downloads.pausedCount == 0) {
      done.complete();
    }
  }

  downloads.addListener(changed);
  changed();
  try {
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    downloads.removeListener(changed);
  }
}

String _listing(String directory, Iterable<String> children, int size) {
  final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
  for (final path in [directory, ...children]) {
    xml.write(
      '<d:response><d:href>${Uri(path: path)}</d:href>'
      '<d:propstat><d:prop><d:resourcetype>'
      '${path.endsWith('/') ? '<d:collection/>' : ''}'
      '</d:resourcetype><d:getcontentlength>$size</d:getcontentlength>'
      '</d:prop></d:propstat></d:response>',
    );
  }
  return '$xml</d:multistatus>';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final root in ['', '2026-10/', '2026-10/动画/']) {
    test(
      'folder selection ($root) deduplicates nested files and preserves local details and paths',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp(
          'folder-offline-',
        );
        final store = await AppStore.open(p.join(directory.path, 'app.sqlite'));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final bytes = List<int>.generate(8192, (index) => index % 251);
        final folder = '/share/$root';
        final first = '${root}Show S01E01.mkv';
        final second = '${root}Season 2/Show S02E01.MP4';
        final listings = <String, List<String>>{
          folder: [
            '/share/$first',
            '${folder}Season 2/',
            '${folder}notes.txt',
            '${folder}Show S01E01.srt',
            '${folder}Empty/',
          ],
          '${folder}Season 2/': [
            '/share/$second',
            '${folder}Season 2/cover.jpg',
          ],
          '${folder}Empty/': [],
        };
        final listed = <String>[];
        final downloaded = <String>[];
        final transferGate = Completer<void>();
        server.listen((request) async {
          final path = Uri.decodeComponent(request.uri.path);
          if (request.method == 'PROPFIND') {
            listed.add(path);
            final children = listings[path];
            if (children == null) {
              request.response.statusCode = HttpStatus.notFound;
            } else {
              request.response.statusCode = HttpStatus.multiStatus;
              request.response.write(_listing(path, children, bytes.length));
            }
          } else if (path == '/share/$first' || path == '/share/$second') {
            request.response.headers.set('accept-ranges', 'bytes');
            request.response.headers.set('etag', '"folder-version-1"');
            request.response.contentLength = bytes.length;
            if (request.method == 'GET') {
              downloaded.add(path);
              request.response.statusCode = HttpStatus.partialContent;
              request.response.headers.set(
                'content-range',
                'bytes 0-${bytes.length - 1}/${bytes.length}',
              );
              await transferGate.future;
              request.response.add(bytes);
            }
          } else {
            request.response.statusCode = HttpStatus.notFound;
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
        store.save('media', 'known-episode', {
          'title': 'Show S01E01.mkv',
          'fileName': 'Show S01E01.mkv',
          'series': 'Show',
          'episode': '1',
          'season': '1',
          'bangumiId': '42',
          'metadataTitle': '保留的作品详情',
          'size': bytes.length,
        });
        store.setLocal('location:known-episode', {
          'id': 'known-episode',
          'source': 'dav',
          'path': first,
          'size': bytes.length,
        });
        final model = AppModel(
          store,
          directory,
          secrets: const FlutterSecureStorage(),
          backgroundWork: false,
        );
        final admittedNotification = Completer<void>();
        void libraryChanged() {
          final record = model.sourceMedia('dav', second);
          if (!admittedNotification.isCompleted &&
              record != null &&
              model.downloads.entryFor(record.id) != null) {
            admittedNotification.complete();
          }
        }

        model.addListener(libraryChanged);
        try {
          await model.downloadSourceEntries('dav', [
            SourceEntry(name: 'Media', path: root, directory: true),
            SourceEntry(
              name: 'Season 2',
              path: '${root}Season 2/',
              directory: true,
            ),
            SourceEntry(
              name: 'Show S01E01.mkv',
              path: first,
              size: bytes.length,
            ),
          ]);
          await admittedNotification.future.timeout(
            const Duration(seconds: 15),
          );
          expect(model.downloads.completedCount, 0);
          expect(model.downloads.libraryRevision, greaterThan(0));
          transferGate.complete();
          await _completedFiles(model.downloads, 2);
          expect(listed.toSet(), listings.keys.toSet());
          expect(
            downloaded,
            unorderedEquals(['/share/$first', '/share/$second']),
          );
          expect(store.all('media'), hasLength(2));
          final known = store.get('media', 'known-episode')!;
          expect(known.data['metadataTitle'], '保留的作品详情');
          expect(model.sourceMedia('dav', first)?.id, known.id);
          final nested = model.sourceMedia('dav', second)!;
          final snapshot = await model.loadLibrarySnapshot();
          expect(
            snapshot.localEntries.map((entry) => entry.path),
            unorderedEquals([known.id, nested.id]),
          );
          expect(snapshot.localRecords[known.id]?.data['bangumiId'], '42');
          expect(snapshot.localRecords[nested.id]?.data['episode'], '1');
          for (final (record, remotePath) in [
            (known, first),
            (nested, second),
          ]) {
            final local = await model.playbackLocation(record);
            expect(local?['source'], 'local');
            expect(
              local?['path'],
              endsWith(p.joinAll(['share', ...remotePath.split('/')])),
            );
            expect(await File(local!['path'] as String).readAsBytes(), bytes);
            expect(store.local('location:${record.id}')['path'], remotePath);
          }
          await model.deleteDownload(nested.id);
          expect((await model.playbackLocation(nested))?['source'], 'dav');
          expect(
            (await model.loadLibrarySnapshot()).localEntries.single.path,
            known.id,
          );
          expect(store.get('media', nested.id)?.deleted, isFalse);
        } finally {
          if (!transferGate.isCompleted) transferGate.complete();
          model.removeListener(libraryChanged);
          await model.downloads.close();
          model.dispose();
          store.dispose();
          await server.close(force: true);
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test(
    'folder download includes all four files despite a one-episode preview',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'four-episode-offline-',
      );
      final store = await AppStore.open(p.join(directory.path, 'app.sqlite'));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final files = [
        for (var episode = 1; episode <= 4; episode++)
          SourceEntry(
            name: 'Show S01E0$episode.mkv',
            path: 'Show/Show S01E0$episode.mkv',
            size: 4096,
          ),
      ];
      final content = {
        for (var index = 0; index < files.length; index++)
          '/share/${files[index].path}': List<int>.generate(
            files[index].size,
            (offset) => (offset + index) % 251,
          ),
      };
      final listed = <String>[];
      final downloaded = <String>[];
      final transferGate = Completer<void>();
      server.listen((request) async {
        final path = Uri.decodeComponent(request.uri.path);
        if (request.method == 'PROPFIND' && path == '/share/Show/') {
          listed.add(path);
          request.response.statusCode = HttpStatus.multiStatus;
          request.response.write(_listing(path, content.keys, 4096));
        } else if (content[path] case final bytes?) {
          request.response.headers.set('accept-ranges', 'bytes');
          request.response.headers.set('etag', '"four-episode-v1"');
          request.response.contentLength = bytes.length;
          if (request.method == 'GET') {
            downloaded.add(path);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              'content-range',
              'bytes 0-${bytes.length - 1}/${bytes.length}',
            );
            await transferGate.future;
            request.response.add(bytes);
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      store.setLocal('settings', {
        'metadataStrategy': 'off',
        'autoDiscover': false,
      });
      store.setLocal('sources', [
        {
          'id': 'dav',
          'kind': 'webdav',
          'label': 'Media',
          'url': 'http://127.0.0.1:${server.port}/share/',
        },
      ]);
      store.save('media', 'known-episode', {
        'title': files.first.name,
        'fileName': files.first.name,
        'series': 'Show',
        'episode': '1',
        'season': '1',
        'bangumiId': '42',
        'metadataTitle': '保留的作品详情',
        'size': files.first.size,
      });
      store.setLocal('location:known-episode', {
        'id': 'known-episode',
        'source': 'dav',
        'path': files.first.path,
        'size': files.first.size,
      });
      persistDirectoryPreview(
        store,
        'dav',
        'Show',
        DirectoryPreview(
          collection: identifyDirectory('Show', [files.first]),
          context: 'old-listing',
          fingerprint: 'one-episode',
          updatedAt: 1,
          modified: 0,
        ),
      );
      final model = AppModel(store, directory, backgroundWork: false);
      final admitted = Completer<void>();
      void changed() {
        if (admitted.isCompleted) return;
        final failure = model.downloads.entries.values
            .where((entry) => entry.status == OfflineDownloadStatus.failed)
            .firstOrNull;
        if (failure != null) {
          admitted.completeError(StateError(failure.error));
        } else if (model.downloads.entries.length == files.length &&
            model.downloads.entries.values.every(
              (entry) => !entry.isDirectory,
            )) {
          admitted.complete();
        }
      }

      model.downloads.addListener(changed);
      const folder = SourceEntry(name: 'Show', path: 'Show/', directory: true);
      try {
        await model.downloadSourceEntries('dav', [folder]);
        await admitted.future.timeout(const Duration(seconds: 15));
        expect(model.downloads.completedCount, 0);
        expect(
          model.downloads.entries.values.map((entry) => entry.remotePath),
          unorderedEquals(files.map((entry) => entry.path)),
        );
        expect(store.all('media'), hasLength(4));
        expect(model.sourceMedia('dav', files.first.path)?.id, 'known-episode');
        expect(
          store.get('media', 'known-episode')?.data['metadataTitle'],
          '保留的作品详情',
        );
        transferGate.complete();
        await _completedFiles(model.downloads, 4);
        final ids = model.downloads.taskIds.toSet();
        for (final file in files) {
          final media = model.sourceMedia('dav', file.path)!;
          final local = await model.playbackLocation(media);
          expect(local?['source'], 'local');
          expect(
            await File(local!['path'] as String).readAsBytes(),
            content['/share/${file.path}'],
          );
          expect(store.local('location:${media.id}')['path'], file.path);
        }

        // Selecting the folder again rescans it without duplicating media,
        // transfer tasks or completed files.
        await model.downloadSourceEntries('dav', [folder]);
        await _completedFiles(model.downloads, 4);
        expect(model.downloads.taskIds.toSet(), ids);
        expect(store.all('media'), hasLength(4));
        expect(downloaded, unorderedEquals(content.keys));
        expect(listed, ['/share/Show/', '/share/Show/']);
      } finally {
        if (!transferGate.isCompleted) transferGate.complete();
        model.downloads.removeListener(changed);
        await model.downloads.close();
        model.dispose();
        store.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
