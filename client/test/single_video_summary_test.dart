import 'dart:async';

import 'package:aiplayer/sources/directory_sort.dart';
import 'package:aiplayer/sources/directory_sort_worker.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'video summary ignores directories and preserves the sole file facts',
    () async {
      final worker = DirectorySortWorker();
      const entries = [
        SourceEntry(name: 'nested.mp4', path: 'nested', directory: true),
        SourceEntry(name: 'photo.jpg', path: 'photo'),
        SourceEntry(name: 'audio.m4a', path: 'audio'),
        SourceEntry(name: 'captions.ass', path: 'captions'),
        SourceEntry(
          name: '.clip.MP4',
          path: 'clip',
          size: 1234,
          modified: 987,
          seekable: false,
          hidden: true,
        ),
      ];
      try {
        final sole = await worker.singleVideo(entries);
        expect(sole, isNotNull);
        expect(
          (
            sole!.name,
            sole.path,
            sole.size,
            sole.modified,
            sole.seekable,
            sole.hidden,
          ),
          ('.clip.MP4', 'clip', 1234, 987, false, true),
        );
        // Visibility is already decided by the caller. A hidden flag alone
        // must not silently change membership in that prepared snapshot.
        expect(await worker.singleVideo(entries.sublist(0, 4)), isNull);
        expect(
          await worker.singleVideo([
            ...entries,
            const SourceEntry(name: 'second.mkv', path: 'second'),
          ]),
          isNull,
        );
        expect(entries.last.path, 'clip');
      } finally {
        worker.close();
      }
    },
  );

  test(
    'summaries share the worker without replacing its prepared search index',
    () async {
      final worker = DirectorySortWorker();
      const entries = [
        SourceEntry(name: 'First.mp4', path: 'first'),
        SourceEntry(name: 'Second.jpg', path: 'second'),
      ];
      try {
        expect((await worker.search(entries, 'first')).single.path, 'first');
        expect((await worker.singleVideo(entries))!.path, 'first');
        expect((await worker.search(entries, 'second')).single.path, 'second');
        expect(await worker.singleVideo(const []), isNull);
        final sorted = await worker.sort(
          entries,
          const DirectorySort(descending: true),
          hideHiddenFiles: false,
        );
        expect(sorted.map((entry) => entry.path), ['second', 'first']);
        expect((await worker.search(entries, 'first')).single.path, 'first');
      } finally {
        worker.close();
      }
    },
  );

  test(
    'video summary requests remain bounded and navigation cancels pending work',
    () async {
      final worker = DirectorySortWorker();
      final requests = <Future<SourceEntry?>>[];
      try {
        for (var i = 0; i < 20; i++) {
          requests.add(
            worker
                .singleVideo([SourceEntry(name: '$i.mp4', path: '$i')])
                .then<SourceEntry?>(
                  (value) => value,
                  onError: (Object error) {
                    expect(error, isA<DirectorySortCancelled>());
                    return null;
                  },
                ),
          );
        }
        final results = await Future.wait(requests);
        expect(results.where((entry) => entry == null), isNotEmpty);
        expect(results.last!.path, '19');

        final active = worker.singleVideo(const [
          SourceEntry(name: 'active.mp4', path: 'active'),
        ]);
        final pending = worker.singleVideo(const [
          SourceEntry(name: 'pending.mp4', path: 'pending'),
        ]);
        final cancelled = expectLater(
          pending,
          throwsA(isA<DirectorySortCancelled>()),
        );
        worker.cancelPending();
        await cancelled;
        expect((await active)!.path, 'active');

        final closing = worker.singleVideo(const [
          SourceEntry(name: 'closing.mp4', path: 'closing'),
        ]);
        final stopped = expectLater(
          closing,
          throwsA(isA<DirectorySortCancelled>()),
        );
        worker.close();
        await stopped;
        await expectLater(
          worker.singleVideo(const []),
          throwsA(isA<DirectorySortCancelled>()),
        );
      } finally {
        worker.close();
      }
    },
  );

  test(
    'large video summaries leave the caller event loop responsive',
    () async {
      final entries = [
        for (var i = 0; i < 120000; i++)
          SourceEntry(name: 'photo-$i.jpg', path: '$i'),
        const SourceEntry(name: 'last.mp4', path: 'video'),
      ];
      final worker = DirectorySortWorker();
      try {
        await worker.singleVideo(const []);
        var beats = 0;
        final timer = Timer.periodic(
          const Duration(milliseconds: 1),
          (_) => beats++,
        );
        try {
          final sole = await worker.singleVideo(entries);
          expect(sole!.path, 'video');
          expect(beats, greaterThan(0));
        } finally {
          timer.cancel();
        }
      } finally {
        worker.close();
      }
    },
  );
}
