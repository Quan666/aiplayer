import 'dart:async';

import 'package:aiplayer/sources/directory_sort.dart';
import 'package:aiplayer/sources/directory_sort_worker.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'worker preserves directory priority, natural order and filters',
    () async {
      final worker = DirectorySortWorker();
      const entries = [
        SourceEntry(name: 'video10.mkv', path: 'ten', size: 5, modified: 3),
        SourceEntry(
          name: 'video2.mkv',
          path: 'two',
          size: 10,
          modified: 2,
          seekable: false,
        ),
        SourceEntry(name: 'video02.mkv', path: 'zero-two', size: 10),
        SourceEntry(name: '.hidden.mkv', path: 'hidden'),
        SourceEntry(name: 'video1.ass', path: 'subtitle'),
        SourceEntry(name: 'folder10', path: 'folder-ten', directory: true),
        SourceEntry(name: 'folder2', path: 'folder-two', directory: true),
      ];
      try {
        for (final field in ['name', 'modified', 'size', 'type']) {
          for (final descending in [false, true]) {
            for (final showSubtitles in [false, true]) {
              for (final hideHidden in [false, true]) {
                final order = DirectorySort(
                  field: field,
                  descending: descending,
                  showSubtitles: showSubtitles,
                );
                final expected = order.apply(
                  entries,
                  hideHiddenFiles: hideHidden,
                );
                final actual = await worker.sort(
                  entries,
                  order,
                  hideHiddenFiles: hideHidden,
                );
                expect(
                  actual.map(
                    (entry) => (
                      entry.path,
                      entry.seekable,
                      entry.size,
                      entry.modified,
                    ),
                  ),
                  expected.map(
                    (entry) => (
                      entry.path,
                      entry.seekable,
                      entry.size,
                      entry.modified,
                    ),
                  ),
                );
              }
            }
          }
        }
        expect(entries.first.path, 'ten');
      } finally {
        worker.close();
      }
    },
  );

  test('large sort leaves the caller event loop responsive', () async {
    final worker = DirectorySortWorker();
    final entries = _largeListing();
    try {
      await worker.sort([], const DirectorySort(), hideHiddenFiles: true);
      var heartbeats = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        heartbeats++;
      });
      try {
        final sorted = await worker.sort(
          entries,
          const DirectorySort(),
          hideHiddenFiles: true,
        );
        expect(heartbeats, greaterThan(0));
        expect(sorted.first.name, 'episode-1.mkv');
        expect(sorted.last.name, 'episode-60000.mkv');
      } finally {
        timer.cancel();
      }
    } finally {
      worker.close();
    }
  });

  test(
    'navigation discards pending work and close cancels active work',
    () async {
      final worker = DirectorySortWorker();
      final entries = _largeListing();
      final first = worker.sort(
        entries,
        const DirectorySort(),
        hideHiddenFiles: true,
      );
      final obsolete = worker.sort(
        entries,
        const DirectorySort(descending: true),
        hideHiddenFiles: true,
      );
      final cancelled = expectLater(
        obsolete,
        throwsA(isA<DirectorySortCancelled>()),
      );
      worker.cancelPending();
      await cancelled;
      expect((await first).first.name, 'episode-1.mkv');
      final active = worker.sort(
        entries,
        const DirectorySort(field: 'type'),
        hideHiddenFiles: true,
      );
      final stopped = expectLater(
        active,
        throwsA(isA<DirectorySortCancelled>()),
      );
      worker.close();
      await stopped;
    },
  );

  test('pending queue stays bounded and keeps the newest request', () async {
    final worker = DirectorySortWorker();
    final requests = <Future<List<SourceEntry>?>>[];
    try {
      for (var i = 0; i < 20; i++) {
        requests.add(
          worker
              .sort(
                [SourceEntry(name: '$i.mkv', path: '$i')],
                const DirectorySort(),
                hideHiddenFiles: true,
              )
              .then<List<SourceEntry>?>(
                (value) => value,
                onError: (Object error) {
                  expect(error, isA<DirectorySortCancelled>());
                  return null;
                },
              ),
        );
      }
      final results = await Future.wait(requests);
      expect(results.where((value) => value == null), isNotEmpty);
      expect(results.last!.single.path, '19');
    } finally {
      worker.close();
    }
  });
}

List<SourceEntry> _largeListing() => [
  for (var i = 60000; i > 0; i--)
    SourceEntry(name: 'episode-$i.mkv', path: '$i'),
];
