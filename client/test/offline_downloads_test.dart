import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => overrideSystemProxyPlatformForTesting('test'));

  test(
    'manual pause continues a validated HTTP prefix and remains paused across lifecycle',
    () async {
      final fixture = (await _Fixture.create(hold: true))..etag = '"version-1"';
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _untilPartial(downloads, 'one');
        await downloads.pause('one');
        final paused = downloads.entryFor('one')!;
        expect(paused.userPaused, true);
        expect(paused.status, OfflineDownloadStatus.paused);
        expect(paused.received, 1000);
        expect(
          await File('${paused.localPath}.part').length(),
          paused.received,
        );
        expect(downloads.activeCount, 0);
        expect(downloads.pausedCount, 1);
        expect(downloads.taskIds, ['one']);
        expect(() => downloads.taskIds.add('bad'), throwsUnsupportedError);
        final revision = downloads.tasksRevision;
        downloads.setActive(false);
        downloads.setActive(true);
        fixture.release();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(fixture.gets, hasLength(1));
        await downloads.resume('one');
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(fixture.ranges, ['bytes=0-191999', 'bytes=1000-191999']);
        expect(fixture.ifRanges, [null, '"version-1"']);
        expect(await File(paused.localPath).readAsBytes(), fixture.bytes);
        expect(downloads.tasksRevision, revision);
        expect(downloads.completedCount, 1);
        expect(downloads.pausedCount, 0);
        expect(downloads.activeCount, 0);
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'immediate pause then resume serializes checkpoint before the next range',
    () async {
      final fixture = (await _Fixture.create(hold: true))..etag = '"version-1"';
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _untilPartial(downloads, 'one');
        final pause = downloads.pause('one');
        final resume = downloads.resume('one');
        await Future.wait([pause, resume]);
        fixture.release();
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(fixture.ranges, ['bytes=0-191999', 'bytes=1000-191999']);
        expect(
          await File(downloads.entryFor('one')!.localPath).readAsBytes(),
          fixture.bytes,
        );
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'manual pause survives restart and resume in background waits for visibility',
    () async {
      final fixture = (await _Fixture.create(hold: true))..etag = '"version-1"';
      var downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _untilPartial(downloads, 'one');
        await downloads.pause('one');
        await downloads.close();
        downloads.dispose();
        downloads = fixture.manager();
        await downloads.initialize();
        expect(downloads.entryFor('one')?.userPaused, true);
        expect(downloads.entryFor('one')?.received, 1000);
        expect(downloads.entryFor('one')?.status, OfflineDownloadStatus.paused);
        downloads.setActive(false);
        await downloads.resume('one');
        expect(downloads.entryFor('one')?.userPaused, false);
        expect(downloads.entryFor('one')?.status, OfflineDownloadStatus.paused);
        fixture.release();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(fixture.gets, hasLength(1));
        downloads.setActive(true);
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(fixture.ranges.last, 'bytes=1000-191999');
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'global pause stops running and queued tasks without frames then resumes them',
    () async {
      final fixture = (await _Fixture.create(hold: true))..etag = '"version-1"';
      final downloads = fixture.manager();
      try {
        for (final id in ['one', 'two', 'three', 'four']) {
          await downloads.enqueue(media: _media(id), location: _location(id));
        }
        await _untilPartial(downloads, 'one');
        await _untilPartial(downloads, 'two');
        await downloads.pauseAll();
        expect(downloads.activeCount, 0);
        expect(downloads.pausedCount, 4);
        expect(downloads.entries.values.every((e) => e.userPaused), true);
        expect(downloads.entryFor('three')?.received, 0);
        final revision = downloads.tasksRevision;
        fixture.release();
        downloads.setActive(false);
        downloads.setActive(true);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(fixture.gets, hasLength(2));
        await downloads.resumeAll();
        await _until(() => downloads.completedCount == 4);
        expect(downloads.tasksRevision, revision);
        expect(
          downloads.activeCount + downloads.pausedCount + downloads.failedCount,
          0,
        );
        expect(fixture.gets, hasLength(6));
        expect(
          fixture.ranges.where((r) => r == 'bytes=1000-191999'),
          hasLength(2),
        );
        await downloads.delete('one');
        expect(downloads.completedCount, 3);
        expect(downloads.tasksRevision, revision + 1);
        expect(downloads.taskIds, ['two', 'three', 'four']);
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test('task insertion order survives state updates and restart', () async {
    final fixture = await _Fixture.create();
    var downloads = fixture.manager(active: false);
    try {
      for (final id in ['one', 'two', 'three']) {
        await downloads.enqueue(media: _media(id), location: _location(id));
      }
      await downloads.pause('one');
      await downloads.pause('two');
      await downloads.resume('one');
      expect(downloads.taskIds, ['one', 'two', 'three']);
      await downloads.close();
      downloads.dispose();
      downloads = fixture.manager(active: false);
      await downloads.initialize();
      expect(downloads.taskIds, ['one', 'two', 'three']);
      expect(downloads.pausedCount, 3);
      expect(downloads.entryFor('two')?.userPaused, true);
      expect(downloads.entryFor('one')?.userPaused, false);
    } finally {
      await downloads.close();
      downloads.dispose();
      await fixture.close();
    }
  });

  test('cancel and delete erase paused fragments permanently', () async {
    final fixture = (await _Fixture.create(hold: true))..etag = '"version-1"';
    var downloads = fixture.manager();
    try {
      for (final id in ['one', 'two']) {
        await downloads.enqueue(media: _media(id), location: _location(id));
        await _untilPartial(downloads, id);
      }
      await downloads.pauseAll();
      final paths = downloads.entries.values.map((e) => e.localPath).toList();
      await downloads.cancel('one');
      await downloads.delete('two');
      expect(downloads.taskIds, isEmpty);
      expect(downloads.pausedCount, 0);
      for (final path in paths) {
        expect(await File('$path.part').exists(), false);
        expect(await File(path).exists(), false);
      }
      await downloads.close();
      downloads.dispose();
      fixture.release();
      downloads = fixture.manager();
      await downloads.initialize();
      expect(downloads.entries, isEmpty);
      expect(fixture.gets, hasLength(2));
    } finally {
      fixture.release();
      await downloads.close();
      downloads.dispose();
      await fixture.close();
    }
  });

  for (final mode in [
    'changed-200',
    'changed-206',
    'ignored-range',
    'weak-etag',
    'last-modified',
    'invalid-date',
  ]) {
    test('resume safely handles $mode', () async {
      final fixture = await _Fixture.create(hold: true);
      fixture.etag = const ['last-modified', 'invalid-date'].contains(mode)
          ? null
          : mode == 'weak-etag'
          ? 'W/"version-1"'
          : '"version-1"';
      if (mode == 'last-modified') {
        fixture.lastModified = 'Wed, 21 Oct 2026 12:00:00 GMT';
        fixture.responseDate = 'Wed, 21 Oct 2026 12:05:00 GMT';
      }
      if (mode == 'invalid-date') {
        fixture.lastModified = 'invalid date';
        fixture.responseDate = 'Wed, 21 Oct 2026 12:05:00 GMT';
      }
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _untilPartial(downloads, 'one');
        await downloads.pause('one');
        final path = downloads.entryFor('one')!.localPath;
        if (mode.startsWith('changed')) {
          fixture.etag = '"version-2"';
          for (var i = 0; i < fixture.bytes.length; i++) {
            fixture.bytes[i] = (i + 71) % 251;
          }
        }
        fixture.lieAboutIfRange = mode == 'changed-206';
        fixture.ignoreRanges = mode == 'ignored-range';
        fixture.release();
        await downloads.resume('one');
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(await File(path).readAsBytes(), fixture.bytes);
        if (mode == 'weak-etag' || mode == 'invalid-date') {
          expect(fixture.ranges.last, 'bytes=0-191999');
          expect(fixture.ifRanges.last, null);
        } else if (mode == 'changed-206') {
          expect(fixture.ranges, [
            'bytes=0-191999',
            'bytes=1000-191999',
            'bytes=0-191999',
          ]);
        } else {
          expect(fixture.ranges.last, 'bytes=1000-191999');
          expect(
            fixture.ifRanges.last,
            mode == 'last-modified' ? fixture.lastModified : '"version-1"',
          );
        }
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    });
  }

  test(
    'same-second Last-Modified is not used to append a changed representation',
    () async {
      final fixture = await _Fixture.create(hold: true);
      fixture.lastModified = fixture.responseDate =
          'Wed, 21 Oct 2026 12:00:00 GMT';
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _untilPartial(downloads, 'one');
        await downloads.pause('one');
        for (var i = 0; i < fixture.bytes.length; i++) {
          fixture.bytes[i] = (i + 71) % 251;
        }
        fixture.release();
        await downloads.resume('one');
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(fixture.ranges.last, 'bytes=0-191999');
        expect(fixture.ifRanges.last, null);
        expect(
          await File(downloads.entryFor('one')!.localPath).readAsBytes(),
          fixture.bytes,
        );
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'network failure retains a flushed prefix for explicit retry only',
    () async {
      final fixture = (await _Fixture.create())
        ..etag = '"version-1"'
        ..failAfterPrefix = true;
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _until(
          () =>
              downloads.entryFor('one')?.status == OfflineDownloadStatus.failed,
        );
        final failed = downloads.entryFor('one')!;
        expect(failed.received, 1000);
        expect(await File('${failed.localPath}.part').length(), 1000);
        expect(downloads.failedCount, 1);
        await downloads.resumeAll();
        expect(downloads.failedCount, 1);
        expect(fixture.gets, hasLength(1));
        fixture.failAfterPrefix = false;
        await downloads.retry('one');
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(fixture.ranges.last, 'bytes=1000-191999');
        expect(downloads.failedCount, 0);
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'close checkpoints partial bytes and restart discards an uncheckpointed tail',
    () async {
      final fixture = (await _Fixture.create(hold: true))..etag = '"version-1"';
      var downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _untilPartial(downloads, 'one');
        final path = downloads.entryFor('one')!.localPath;
        downloads.setActive(false);
        await downloads.close();
        downloads.dispose();
        final part = File('$path.part');
        expect(await part.length(), 1000);
        await part.writeAsBytes([9, 9, 9, 9], mode: FileMode.append);
        downloads = fixture.manager(active: false);
        await downloads.initialize();
        expect(downloads.entryFor('one')?.received, 1000);
        expect(downloads.entryFor('one')?.userPaused, false);
        fixture.release();
        downloads.setActive(true);
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(fixture.ranges.last, 'bytes=1000-191999');
        expect(await File(path).readAsBytes(), fixture.bytes);
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'an empty catalogue initializes without creating a directory or database',
    () async {
      final parent = await Directory.systemTemp.createTemp('offline-idle-');
      final directory = Directory(p.join(parent.path, 'offline'));
      final downloads = OfflineDownloads(
        directory: directory,
        storePath: ':memory:',
        sourceConfiguration: (_) async => throw StateError('No work requested'),
      );
      try {
        expect(downloads.initialized, false);
        await downloads.initialize();
        expect(downloads.initialized, true);
        expect(downloads.entries, isEmpty);
        expect(await directory.exists(), false);
        downloads.setActive(false);
        downloads.setActive(true);
        await downloads.close();
        expect(await directory.exists(), false);
      } finally {
        await downloads.close();
        downloads.dispose();
        await parent.delete(recursive: true);
      }
    },
  );

  test(
    'downloads original DAV hierarchy, persists, validates and deletes locally',
    () async {
      final fixture = await _Fixture.create();
      var downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        final task = downloads.entryFor('one')!;
        expect(task.localPath, endsWith(p.join('share', '2026-10', 'one.mp4')));
        expect(await File(task.localPath).readAsBytes(), fixture.bytes);
        expect(await File('${task.localPath}.part').exists(), false);
        expect(fixture.gets, ['/share/2026-10/one.mp4']);
        expect(fixture.ranges.single, 'bytes=0-${fixture.bytes.length - 1}');
        expect(downloads.completedLocations['one']?['offline'], true);
        expect(
          () => downloads.completedLocations['one']!['path'] = 'bad',
          throwsUnsupportedError,
        );
        final revision = downloads.completedRevision;
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        expect(downloads.completedRevision, revision);
        expect(fixture.gets, hasLength(1));
        await downloads.close();
        downloads.dispose();
        downloads = fixture.manager();
        await downloads.initialize();
        expect(downloads.entryFor('one')?.isComplete, true);
        expect(await downloads.localPath('one'), task.localPath);
        final database = await File(
          p.join(fixture.directory.path, 'downloads.sqlite'),
        ).readAsBytes();
        expect(latin1.decode(database), isNot(contains('private-password')));
        await downloads.delete('one');
        expect(downloads.entryFor('one'), null);
        expect(downloads.completedLocations, isEmpty);
        expect(await File(task.localPath).exists(), false);
        expect(fixture.gets, hasLength(1));
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'servers returning full HTTP 200 without range support download correctly',
    () async {
      final fixture = await _Fixture.create(rangeSupport: false);
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(
          await File(downloads.entryFor('one')!.localPath).readAsBytes(),
          fixture.bytes,
        );
        expect(fixture.ranges.last, 'bytes=0-${fixture.bytes.length - 1}');
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'a changed HTTP range total never promotes a clipped video or auto-retries',
    () async {
      final fixture = await _Fixture.create(wrongRangeTotal: true);
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _until(
          () =>
              downloads.entryFor('one')?.status == OfflineDownloadStatus.failed,
        );
        final task = downloads.entryFor('one')!;
        expect(await File(task.localPath).exists(), false);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(await File('${task.localPath}.part').exists(), false);
        expect(fixture.gets, hasLength(1));
        expect(downloads.completedLocations, isEmpty);
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'background pause cancels transfers without frames or queue replenishment',
    () async {
      final fixture = await _Fixture.create(hold: true);
      final downloads = fixture.manager();
      try {
        for (final id in ['one', 'two', 'three', 'four']) {
          await downloads.enqueue(media: _media(id), location: _location(id));
        }
        await _until(() => fixture.gets.length == 2);
        downloads.setActive(false);
        await _until(
          () => downloads.entries.values.every(
            (e) => e.status == OfflineDownloadStatus.paused,
          ),
        );
        final requests = fixture.gets.length;
        // No widget pump/frame or periodic maintenance is involved.
        fixture.release();
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(fixture.gets.length, requests);
        expect(downloads.entries.values.any((e) => e.isComplete), false);
        expect(downloads.completedRevision, 0);
        downloads.setActive(true);
        await _until(() => downloads.entries.values.every((e) => e.isComplete));
        expect(downloads.entries, hasLength(4));
        expect(fixture.gets.length, 6);
        expect(fixture.maxConcurrent, lessThanOrEqualTo(2));
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'cancel pending work and delete in-flight bytes cannot resurrect tasks',
    () async {
      final fixture = await _Fixture.create(hold: true);
      final downloads = fixture.manager();
      try {
        for (final id in ['one', 'two', 'three']) {
          await downloads.enqueue(media: _media(id), location: _location(id));
        }
        await _until(() => fixture.gets.length == 2);
        await downloads.cancel('three');
        final path = downloads.entryFor('one')!.localPath;
        await downloads.delete('one');
        fixture.release();
        await _until(() => downloads.entryFor('two')?.isComplete == true);
        expect(downloads.entryFor('one'), null);
        expect(downloads.entryFor('three'), null);
        expect(await File(path).exists(), false);
        expect(await File('$path.part').exists(), false);
        expect(fixture.gets, hasLength(2));
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'source binding edits during transfer prevent stale file promotion',
    () async {
      final fixture = await _Fixture.create(hold: true);
      final store = AppStore(p.join(fixture.directory.path, 'library.sqlite'));
      final location = {
        ..._location('one'),
        'id': 'one',
        'previewRevision': 'before',
      };
      store.save('media', 'one', _media('one').data);
      store.setLocal('location:one', location);
      final downloads = fixture.manager(storePath: store.path);
      try {
        await downloads.enqueue(media: _media('one'), location: location);
        await _until(() => fixture.gets.length == 1);
        expect(downloads.entryFor('one')?.bindingRevision, 'before');
        store.setLocal('location:one', {
          ...location,
          'previewRevision': 'after',
        });
        fixture.release();
        await _until(
          () =>
              downloads.entryFor('one')?.status == OfflineDownloadStatus.failed,
        );
        expect(downloads.completedLocations, isEmpty);
        expect(
          await File(downloads.entryFor('one')!.localPath).exists(),
          false,
        );
        await expectLater(
          downloads.enqueue(
            media: _media('one'),
            location: {...location, 'previewRevision': 'after'},
          ),
          throwsA(anything),
        );
      } finally {
        fixture.release();
        await downloads.close();
        downloads.dispose();
        store.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'missing completed file invalidates local playback and can be retried',
    () async {
      final fixture = await _Fixture.create();
      final downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        final revision = downloads.completedRevision;
        await File(downloads.entryFor('one')!.localPath).writeAsBytes([1]);
        expect(await downloads.localPath('one'), null);
        expect(downloads.completedRevision, revision + 1);
        expect(downloads.completedLocations, isEmpty);
        expect(downloads.entryFor('one')?.status, OfflineDownloadStatus.failed);
        await downloads.retry('one');
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        expect(
          await File(downloads.entryFor('one')!.localPath).length(),
          fixture.bytes.length,
        );
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'traversal is rejected and symlink deletion never reaches outside storage',
    () async {
      final fixture = await _Fixture.create();
      final downloads = fixture.manager();
      final external = await Directory.systemTemp.createTemp(
        'offline-external-',
      );
      try {
        await expectLater(
          downloads.enqueue(
            media: _media('bad'),
            location: {'source': 'dav', 'path': '../escape.mp4', 'size': 12},
          ),
          throwsA(anything),
        );
        expect(fixture.gets, isEmpty);
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        final path = downloads.entryFor('one')!.localPath;
        final outsideFile = File(p.join(external.path, 'outside.mp4'));
        await outsideFile.writeAsBytes([1, 2, 3]);
        await File(path).delete();
        await Link(path).create(outsideFile.path);
        expect(await downloads.localPath('one'), null);
        await expectLater(downloads.delete('one'), throwsA(anything));
        expect(await outsideFile.readAsBytes(), [1, 2, 3]);
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
        await external.delete(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires developer privileges'
        : false,
  );

  test(
    'restoring verifies completed files before exposing local locations',
    () async {
      final fixture = await _Fixture.create();
      var downloads = fixture.manager();
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        await _until(() => downloads.entryFor('one')?.isComplete == true);
        final path = downloads.entryFor('one')!.localPath;
        await downloads.close();
        downloads.dispose();
        await File(path).delete();
        downloads = fixture.manager();
        await downloads.initialize();
        expect(downloads.entryFor('one')?.status, OfflineDownloadStatus.failed);
        expect(downloads.completedLocations, isEmpty);
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );

  test(
    'close and restart preserve paused queue without connecting while inactive',
    () async {
      final fixture = await _Fixture.create();
      var downloads = fixture.manager(active: false);
      try {
        await downloads.enqueue(
          media: _media('one'),
          location: _location('one'),
        );
        expect(downloads.entryFor('one')?.status, OfflineDownloadStatus.paused);
        await downloads.close();
        downloads.dispose();
        downloads = fixture.manager(active: false);
        await downloads.initialize();
        expect(downloads.entryFor('one')?.status, OfflineDownloadStatus.paused);
        expect(fixture.gets, isEmpty);
        downloads.setActive(true);
        await _until(() => downloads.entryFor('one')?.isComplete == true);
      } finally {
        await downloads.close();
        downloads.dispose();
        await fixture.close();
      }
    },
  );
}

SyncRecord _media(String id) => SyncRecord(
  id: id,
  kind: 'media',
  data: {'fileName': '$id.mp4', 'title': 'Episode $id'},
);
Map<String, dynamic> _location(String id) => {
  'source': 'dav',
  'path': '2026-10/$id.mp4',
  'size': 192000,
};

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for download');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _untilPartial(OfflineDownloads downloads, String id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final path = downloads.entryFor(id)?.localPath;
    if (path != null && path.isNotEmpty) {
      final file = File('$path.part');
      if (await file.exists() && await file.length() > 0) return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for partial data');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _Fixture {
  final Directory directory;
  final HttpServer server;
  final bytes = List<int>.generate(192000, (i) => i % 251);
  final gets = <String>[];
  final ranges = <String?>[];
  final ifRanges = <String?>[];
  String? etag, lastModified, responseDate;
  bool ignoreRanges = false, lieAboutIfRange = false, failAfterPrefix = false;
  final bool rangeSupport, wrongRangeTotal;
  Completer<void>? gate;
  var concurrent = 0, maxConcurrent = 0;

  _Fixture(
    this.directory,
    this.server,
    bool hold, {
    this.rangeSupport = true,
    this.wrongRangeTotal = false,
  }) {
    if (hold) gate = Completer<void>();
    server.listen((request) async {
      final response = request.response;
      response.bufferOutput = false;
      response.headers.set('accept-ranges', rangeSupport ? 'bytes' : 'none');
      response.contentLength = bytes.length;
      if (etag != null) response.headers.set('etag', etag!);
      if (responseDate != null) response.headers.set('date', responseDate!);
      if (lastModified != null) {
        response.headers.set('last-modified', lastModified!);
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      gets.add(request.uri.path);
      ranges.add(request.headers.value('range'));
      final ifRange = request.headers.value('if-range');
      ifRanges.add(ifRange);
      concurrent++;
      if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      final full =
          !rangeSupport ||
          ignoreRanges ||
          (!lieAboutIfRange &&
              ifRange != null &&
              ifRange != (etag ?? lastModified));
      final requested = int.parse(
        RegExp(
          r'bytes=(\d+)-',
        ).firstMatch(request.headers.value('range') ?? 'bytes=0-')![1]!,
      );
      final start = full ? 0 : requested;
      response.statusCode = full ? 200 : 206;
      response.contentLength = bytes.length - start;
      if (!full) {
        response.headers.set(
          'content-range',
          'bytes $start-${bytes.length - 1}/${bytes.length + (wrongRangeTotal ? 1 : 0)}',
        );
      }
      try {
        final prefixEnd = (start + 1000).clamp(0, bytes.length);
        if (failAfterPrefix) {
          final socket = await response.detachSocket(writeHeaders: false);
          socket.add(
            utf8.encode(
              'HTTP/1.1 206 Partial Content\r\n'
              'Content-Length: ${bytes.length - start}\r\n'
              'Content-Range: bytes $start-${bytes.length - 1}/${bytes.length}\r\n'
              '${etag == null ? '' : 'ETag: $etag\r\n'}'
              'Connection: close\r\n\r\n',
            ),
          );
          socket.add(bytes.sublist(start, prefixEnd));
          await socket.flush();
          await socket.close();
          return;
        }
        response.add(bytes.sublist(start, prefixEnd));
        await response.flush();
        await gate?.future;
        response.add(bytes.sublist(prefixEnd));
        await response.close();
      } catch (_) {
        // Cancellation deliberately aborts the connection.
      } finally {
        concurrent--;
      }
    });
  }

  static Future<_Fixture> create({
    bool hold = false,
    bool rangeSupport = true,
    bool wrongRangeTotal = false,
  }) async => _Fixture(
    await Directory.systemTemp.createTemp('offline-download-'),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    hold,
    rangeSupport: rangeSupport,
    wrongRangeTotal: wrongRangeTotal,
  );

  OfflineDownloads manager({
    bool active = true,
    String storePath = ':memory:',
  }) => OfflineDownloads(
    directory: directory,
    storePath: storePath,
    active: active,
    sourceConfiguration: (_) async => {
      'kind': 'webdav',
      'url': 'http://127.0.0.1:${server.port}/share/',
      'user': 'tester',
      'password': 'private-password',
    },
  );

  void release() {
    if (gate?.isCompleted == false) gate!.complete();
    gate = null;
  }

  Future<void> close() async {
    release();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}
