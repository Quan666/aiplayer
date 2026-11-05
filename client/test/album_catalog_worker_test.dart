import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/album_catalog_worker.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('worker returns type choices and media neighbors with cached filter changes', () async {
    final worker = AlbumCatalogWorker();
    const entries = [
      SourceEntry(name: 'folder', path: '/trip/folder', directory: true),
      SourceEntry(name: '001.jpg', path: '/trip/001.jpg'),
      SourceEntry(name: '002.txt', path: '/trip/002.txt'),
      SourceEntry(name: '003.mp4', path: '/trip/003.mp4'),
      SourceEntry(name: '004.flac', path: '/trip/004.flac'),
      SourceEntry(name: 'README', path: '/trip/README'),
    ];
    try {
      final all = await worker.build(
        entries,
        sourceId: 'nas',
        directory: '/trip',
        options: AlbumOptions(types: const {'*'}),
      );
      expect(all.availableTypes, [
        'folder',
        '.flac',
        '.jpg',
        '.mp4',
        '.txt',
        'file',
      ]);
      expect(all.defaultTypes, {'folder', '.jpg', '.mp4'});
      expect(all.nextMediaIndex, {1: 3, 3: 4});
      expect(all.previousMediaIndex, {3: 1, 4: 3});
      final folders = await worker.build(
        entries,
        sourceId: 'nas',
        directory: '/trip',
        options: AlbumOptions(types: const {'folder'}),
      );
      expect(folders.items.single.isDirectory, isTrue);
      expect(folders.availableTypes, all.availableTypes);
      expect(folders.nextMediaIndex, isEmpty);
      expect(worker.indexTransfers, 1);
    } finally {
      worker.close();
    }
  });

  test(
    'browsing timeline freezes order and date rows while facts update',
    () async {
      final worker = AlbumCatalogWorker();
      final day = DateTime(2026, 11, 4).millisecondsSinceEpoch;
      final old = DateTime(2019, 1, 1).millisecondsSinceEpoch;
      final future = DateTime(2030, 1, 1).millisecondsSinceEpoch;
      final entries = [
        SourceEntry(name: 'a.jpg', path: '/trip/a.jpg', modified: day + 1000),
        SourceEntry(
          name: 'clip.mp4',
          path: '/trip/clip.mp4',
          modified: day + 2000,
        ),
        SourceEntry(name: 'z.jpg', path: '/trip/z.jpg', modified: day + 3000),
      ];
      final options = AlbumOptions(sortField: 'captured', descending: false);
      try {
        final first = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: options,
          dataRevision: 0,
          orderingRevision: 0,
        );
        final metadata = {
          '/trip/a.jpg': AlbumFileMetadata(
            capturedAt: future,
            width: 4000,
            height: 3000,
          ),
          '/trip/clip.mp4': AlbumFileMetadata(
            capturedAt: old,
            durationMilliseconds: 5000,
          ),
        };
        final warmed = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: options,
          metadata: metadata,
          dataRevision: 1,
          orderingRevision: 0,
        );
        expect(
          warmed.items.map((item) => item.id),
          first.items.map((item) => item.id),
        );
        expect(warmed.timelineById, first.timelineById);
        expect(warmed.wallSections.headerCount, 1);
        expect(warmed.wallSections.childByItem, first.wallSections.childByItem);
        expect(warmed.wallSections.totalRows, first.wallSections.totalRows);
        expect(warmed.nextMediaIndex, first.nextMediaIndex);
        expect(warmed.items.first.capturedAt, future);
        expect(warmed.items[1].capturedAt, old);
        expect(() => warmed.timelineById.clear(), throwsUnsupportedError);

        final reset = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: options,
          metadata: metadata,
          dataRevision: 1,
          orderingRevision: 1,
        );
        expect(reset.items.map((item) => item.preferred.name), [
          'clip.mp4',
          'z.jpg',
          'a.jpg',
        ]);
        expect(reset.wallSections.headerCount, 3);
        expect(reset.timelineById[reset.items.last.id], future);
        expect(worker.indexTransfers, 2);
      } finally {
        worker.close();
      }
    },
  );

  test(
    'directory returns retain their own timeline and listings invalidate it',
    () async {
      final worker = AlbumCatalogWorker();
      final entries = [
        const SourceEntry(name: 'a.jpg', path: '/trip/a.jpg', modified: 1000),
        const SourceEntry(
          name: 'clip.mp4',
          path: '/trip/clip.mp4',
          modified: 2000,
        ),
        const SourceEntry(name: 'z.jpg', path: '/trip/z.jpg', modified: 3000),
      ];
      final options = AlbumOptions(sortField: 'captured', descending: false);
      try {
        final first = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: options,
          orderingRevision: 0,
        );
        await worker.build(
          const [SourceEntry(name: 'other.jpg', path: '/other/other.jpg')],
          sourceId: 'nas',
          directory: '/other',
          orderingRevision: 0,
        );
        final returned = await worker.build(
          List.of(entries),
          sourceId: 'nas',
          directory: '/trip',
          options: options,
          orderingRevision: 0,
          dataRevision: 1,
          metadata: const {'/trip/a.jpg': AlbumFileMetadata(capturedAt: 9000)},
        );
        expect(returned.timelineById, first.timelineById);
        expect(
          returned.items.map((item) => item.id),
          first.items.map((item) => item.id),
        );

        entries[0] = const SourceEntry(
          name: 'a.jpg',
          path: '/trip/a.jpg',
          modified: 5000,
        );
        final changed = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: options,
          orderingRevision: 0,
          dataRevision: 2,
        );
        expect(changed.items.map((item) => item.preferred.name), [
          'clip.mp4',
          'z.jpg',
          'a.jpg',
        ]);
        expect(changed.timelineById[changed.items.last.id], 5000);
        entries.removeLast();
        final removed = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: options,
          orderingRevision: 0,
          dataRevision: 3,
        );
        expect(removed.items.map((item) => item.preferred.name), [
          'clip.mp4',
          'a.jpg',
        ]);
        expect(removed.timelineById, hasLength(2));
      } finally {
        worker.close();
      }
    },
  );

  test(
    'ordinary worker callers still sort by latest metadata without an epoch',
    () async {
      final worker = AlbumCatalogWorker();
      const entries = [
        SourceEntry(name: 'a.jpg', path: '/trip/a.jpg', modified: 1000),
        SourceEntry(name: 'clip.mp4', path: '/trip/clip.mp4', modified: 2000),
      ];
      try {
        final first = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: AlbumOptions(sortField: 'captured', descending: false),
        );
        expect(first.items.first.preferred.name, 'a.jpg');
        final latest = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: AlbumOptions(sortField: 'captured', descending: false),
          dataRevision: 1,
          metadata: const {'/trip/a.jpg': AlbumFileMetadata(capturedAt: 9000)},
        );
        expect(latest.items.first.preferred.name, 'clip.mp4');
      } finally {
        worker.close();
      }
    },
  );

  test(
    'directory revision reused across filters, refreshed after mutation',
    () async {
      final worker = AlbumCatalogWorker();
      final entries = [
        const SourceEntry(name: '001.jpg', path: '/trip/001.jpg'),
        const SourceEntry(name: '001.arw', path: '/trip/001.arw'),
      ];
      try {
        final all = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
        );
        expect(all.items.single.members, hasLength(2));
        final jpg = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          options: AlbumOptions(includeExtensions: ['jpg']),
        );
        expect(jpg.items.single.members.single.name, '001.jpg');
        expect(worker.indexTransfers, 1);
        entries.removeLast();
        final refreshed = await worker.build(
          entries,
          sourceId: 'nas',
          directory: '/trip',
          dataRevision: 1,
        );
        expect(refreshed.items.single.allMembers, hasLength(1));
        expect(worker.indexTransfers, 2);
      } finally {
        worker.close();
      }
    },
  );

  test(
    'large catalog leaves caller responsive and retains only latest query',
    () async {
      final worker = AlbumCatalogWorker();
      final entries = [
        for (var i = 30000; i > 0; i--)
          for (final extension in ['jpg', 'arw'])
            SourceEntry(
              name: 'photo$i.$extension',
              path: '/trip/photo$i.$extension',
            ),
      ];
      try {
        await worker.build(const [], sourceId: 'nas', directory: '/trip');
        var beats = 0;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
          beats++;
        });
        try {
          final prepared = await worker.build(
            entries,
            sourceId: 'nas',
            directory: '/trip',
          );
          expect(prepared.items, hasLength(30000));
          expect(prepared.items.first.name, 'photo1');
          expect(beats, greaterThan(0));
          final requests = <Future<AlbumSnapshot?>>[];
          for (var i = 0; i < 40; i++) {
            requests.add(
              worker
                  .build(
                    entries,
                    sourceId: 'nas',
                    directory: '/trip',
                    options: AlbumOptions(query: 'photo$i.jpg'),
                  )
                  .then<AlbumSnapshot?>(
                    (snapshot) => snapshot,
                    onError: (Object error) {
                      expect(error, isA<AlbumCatalogCancelled>());
                      return null;
                    },
                  ),
            );
            expect(worker.pendingCount, lessThanOrEqualTo(1));
          }
          final results = await Future.wait(requests);
          expect(results.whereType<AlbumSnapshot>(), hasLength(1));
          expect(results.last!.items.single.preferred.name, 'photo39.jpg');
          expect(worker.indexTransfers, 2);
        } finally {
          heartbeat.cancel();
        }
      } finally {
        worker.close();
      }
    },
  );

  test(
    'cancel and dispose require no frame and do not publish stale results',
    () async {
      final worker = AlbumCatalogWorker();
      final first = worker.build(
        [const SourceEntry(name: '001.jpg', path: '/trip/001.jpg')],
        sourceId: 'nas',
        directory: '/trip',
      );
      final cancelled = expectLater(
        first,
        throwsA(isA<AlbumCatalogCancelled>()),
      );
      worker.cancelBuilds();
      await cancelled;
      expect(worker.pendingCount, 0);
      final resumed = await worker.build(
        [const SourceEntry(name: '002.jpg', path: '/trip/002.jpg')],
        sourceId: 'nas',
        directory: '/trip',
      );
      expect(resumed.items.single.name, '002');
      final active = worker.build(
        const [],
        sourceId: 'nas',
        directory: '/trip',
      );
      final disposed = expectLater(
        active,
        throwsA(isA<AlbumCatalogCancelled>()),
      );
      worker.close();
      await disposed;
      await expectLater(
        worker.build(const [], sourceId: 'nas', directory: '/trip'),
        throwsA(isA<AlbumCatalogCancelled>()),
      );
    },
  );

  test(
    'preferences round trip off isolate and serialize newest pending save',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'album-preferences-',
      );
      final file = '${folder.path}/nested/options.json';
      final worker = AlbumCatalogWorker();
      try {
        expect(await worker.readPreferences(file), isEmpty);
        await worker.savePreferences(file, {
          'mode': 'album',
          'options': AlbumOptions(includeExtensions: ['jpg']).toJson(),
        });
        final saved = await worker.readPreferences(file);
        expect(saved['mode'], 'album');
        expect(AlbumOptions.fromJson(saved['options']).includeExtensions, {
          '.jpg',
        });
        final writes = <Future<void>>[];
        for (var i = 0; i < 25; i++) {
          writes.add(
            worker.savePreferences(file, {'size': i}).catchError((Object e) {
              expect(e, isA<AlbumCatalogCancelled>());
            }),
          );
        }
        await Future.wait(writes);
        expect(await worker.readPreferences(file), {'size': 24});
        final temporary = await folder.list(recursive: true).toList();
        expect(
          temporary.where((entry) => entry.path.contains('.pending-')),
          isEmpty,
        );
        await File(file).writeAsString('invalid json');
        await expectLater(
          worker.readPreferences(file),
          throwsA(isA<AlbumCatalogFailure>()),
        );
        // A failed IO request must not poison the worker's next request.
        await worker.savePreferences(file, {'recovered': true});
        expect(await worker.readPreferences(file), {'recovered': true});
      } finally {
        worker.close();
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'route disposal flushes its last accepted settings without another frame',
    () async {
      final folder = await Directory.systemTemp.createTemp('album-flush-');
      final file = '${folder.path}/options.json';
      final worker = AlbumCatalogWorker();
      try {
        final saved = worker.savePreferences(file, {
          'mode': 'album',
          'size': 'large',
        });
        final flushed = worker.flushPreferencesAndClose();
        await saved;
        await flushed;
        expect(await File(file).readAsString(), contains('large'));
        await expectLater(
          worker.readPreferences(file),
          throwsA(isA<AlbumCatalogCancelled>()),
        );
        expect(worker.pendingCount, 0);
      } finally {
        worker.close();
        await folder.delete(recursive: true);
      }
    },
  );
}
