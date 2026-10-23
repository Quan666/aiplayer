import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late AppStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('playback-location-');
    store = AppStore('${directory.path}/app.db');
    store.setLocal('location:video', _location());
  });

  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<bool> updateSize([int size = 200]) => store.updatePlaybackLocationSize(
    'video',
    sourceId: 'nas',
    path: '/video.mkv',
    size: size,
  );

  test('an unchanged playback size does not invalidate snapshots', () async {
    final revision = store.locationRevision;
    final keyRevision = store.localKeyRevision('location:video');
    final modified = store.local('syncModified:location:video');
    expect(await updateSize(100), isFalse);
    expect(store.locationRevision, revision);
    expect(store.localKeyRevision('location:video'), keyRevision);
    expect(store.local('syncModified:location:video'), modified);
  });

  test('a worker size update invalidates a cached location', () async {
    expect(store.locationFor('nas', '/video.mkv')?['size'], 100);
    final revision = store.locationRevision;
    expect(await updateSize(), isTrue);
    expect(store.locationRevision, greaterThan(revision));
    expect(store.locationFor('nas', '/video.mkv')?['size'], 200);
    expect(store.local('location:video')['title'], 'Original');
  });

  test('a blocked size write leaves the main event loop responsive', () async {
    final writer = AppStore.openExisting(store.path);
    var locked = true;
    var ticks = 0;
    writer.db.execute('BEGIN IMMEDIATE');
    final heartbeat = Timer.periodic(const Duration(milliseconds: 20), (_) {
      ticks++;
    });
    final release = Timer(const Duration(milliseconds: 160), () {
      writer.db.execute('COMMIT');
      locked = false;
    });
    try {
      expect(await updateSize(), isTrue);
      expect(locked, isFalse);
      expect(ticks, greaterThanOrEqualTo(3));
    } finally {
      heartbeat.cancel();
      release.cancel();
      if (locked) writer.db.execute('ROLLBACK');
      writer.dispose();
    }
  });

  test('a waiting size write preserves concurrently edited fields', () async {
    final writer = AppStore.openExisting(store.path);
    var locked = true;
    writer.db.execute('BEGIN IMMEDIATE');
    final pending = updateSize();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      writer.setLocal('location:video', {
        ..._location(),
        'title': 'Renamed while opening',
        'duration': 123,
      });
      writer.db.execute('COMMIT');
      locked = false;
      expect(await pending, isTrue);
      expect(store.local('location:video'), {
        ..._location(),
        'size': 200,
        'title': 'Renamed while opening',
        'duration': 123,
      });
    } finally {
      if (locked) writer.db.execute('ROLLBACK');
      await pending;
      writer.dispose();
    }
  });

  for (final change in ['delete', 'source', 'path']) {
    test('a waiting size write cannot undo a location $change', () async {
      final writer = AppStore.openExisting(store.path);
      var locked = true;
      writer.db.execute('BEGIN IMMEDIATE');
      final pending = updateSize();
      try {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final moved = {
          ..._location(),
          if (change == 'source') 'source': 'other-nas',
          if (change == 'path') 'path': '/moved.mkv',
        };
        if (change == 'delete') {
          writer.removeLocal('location:video');
        } else {
          writer.setLocal('location:video', moved);
        }
        writer.db.execute('COMMIT');
        locked = false;
        expect(await pending, isFalse);
        expect(
          store.local('location:video'),
          change == 'delete' ? null : moved,
        );
      } finally {
        if (locked) writer.db.execute('ROLLBACK');
        await pending;
        writer.dispose();
      }
    });
  }

  test('in-memory stores use the same conditional size mutation', () async {
    final memory = AppStore(':memory:');
    addTearDown(memory.dispose);
    memory.setLocal('location:video', _location());
    expect(
      await memory.updatePlaybackLocationSize(
        'video',
        sourceId: 'nas',
        path: '/video.mkv',
        size: 200,
      ),
      isTrue,
    );
    expect(memory.local('location:video'), {..._location(), 'size': 200});
  });
}

Map<String, dynamic> _location() => {
  'id': 'video',
  'source': 'nas',
  'path': '/video.mkv',
  'size': 100,
  'title': 'Original',
};
