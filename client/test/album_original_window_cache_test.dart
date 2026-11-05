import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/album_image_cache.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _Fixture {
  final Directory root;
  final caches = <AlbumImageDiskCache>[];
  _Fixture(this.root);
  static Future<_Fixture> create() async =>
      _Fixture(await Directory.systemTemp.createTemp('album-window-disk-'));

  AlbumImageDiskCache cache(
    String owner, {
    int bytes = 10000,
    int metadataBytes = 16 * 1024 * 1024,
    Future<void> Function(File, List<int>, CancelToken)? publisher,
  }) {
    final value = AlbumImageDiskCache(
      directory: root.path,
      ownerId: owner,
      adaptiveOriginals: true,
      originalBytes: bytes,
      originalFiles: 1000,
      thumbnailBytes: 10000,
      thumbnailFiles: 1000,
      metadataBytes: metadataBytes,
      publish:
          publisher ??
          (file, bytes, cancel) => publishAlbumCacheFile(file, bytes, cancel),
      onEvicted: (_) {},
    );
    caches.add(value);
    return value;
  }

  String path(int index, {String tier = 'original'}) =>
      '${root.path}/${tier == 'original' ? 'album-images-v2' : 'album-thumbnails-v1'}/$index.jpg';
  Future<bool> write(
    AlbumImageDiskCache cache,
    int index, {
    String tier = 'original',
    int? priority,
  }) async {
    final value = await cache.write(
      tier,
      {
        File(path(index, tier: tier)): List.filled(90, 42),
        File('${path(index, tier: tier)}.json'): List.filled(10, 32),
      },
      CancelToken(),
      admissionPriority: priority,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return value;
  }

  List<Map<String, Object?>> rows(String sql) {
    final db = sqlite3.open('${root.path}/album-cache-v1.sqlite');
    try {
      return db
          .select(sql)
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      db.dispose();
    }
  }

  Future<void> trim(AlbumImageDiskCache cache) async {
    for (var i = 0; i < 20; i++) {
      if (!await cache.maintain(CancelToken())) return;
    }
    fail('Maintenance did not settle in bounded batches.');
  }

  Future<void> close() async {
    for (final cache in caches) {
      await cache.close();
    }
    await root.delete(recursive: true);
  }
}

void main() {
  test(
    'failed or cancelled thumbnail publication keeps the durable fallback',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      var failSidecar = false, cancelSidecar = false;
      final cache = f.cache(
        'wall',
        publisher: (file, bytes, cancel) async {
          if (file.path.contains('album-thumbnails-v1') &&
              file.path.endsWith('.json')) {
            if (failSidecar) throw const AppFailure('Publication failed.');
            if (cancelSidecar) cancel.cancel();
          }
          await publishAlbumCacheFile(file, bytes, cancel);
        },
      );
      await f.write(cache, 0);
      await cache.retainOriginalUntilThumbnail(f.path(0), CancelToken());
      for (var i = 1; i < 20; i++) {
        await f.write(cache, i);
      }
      Future<bool> publishThumbnail() => cache.write(
        'thumbnail',
        {
          File(f.path(0, tier: 'thumbnail')): List.filled(90, 42),
          File('${f.path(0, tier: 'thumbnail')}.json'): List.filled(10, 32),
        },
        CancelToken(),
        releasesOriginalFallback: f.path(0),
      );
      failSidecar = true;
      await expectLater(publishThumbnail(), throwsA(isA<AppFailure>()));
      expect(
        f.rows('SELECT path FROM original_fallbacks').single['path'],
        f.path(0),
      );
      await f.trim(cache);
      expect(await File(f.path(0)).exists(), isTrue);

      failSidecar = false;
      cancelSidecar = true;
      await expectLater(publishThumbnail(), throwsA(isA<Cancelled>()));
      expect(
        f.rows('SELECT path FROM original_fallbacks').single['path'],
        f.path(0),
      );
      await f.trim(cache);
      expect(await File(f.path(0)).exists(), isTrue);

      cancelSidecar = false;
      expect(await publishThumbnail(), isTrue);
      expect(f.rows('SELECT path FROM original_fallbacks'), isEmpty);
      await f.trim(cache);
      expect(await File(f.path(0)).exists(), isFalse);
    },
  );

  test('gallery originals without thumbnails survive peer reclamation and reopen', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final wall = f.cache('wall'), peer = f.cache('viewer');
    for (var i = 0; i < 20; i++) {
      await f.write(wall, i);
      if (i < 12) {
        await wall.retainOriginalUntilThumbnail(f.path(i), CancelToken());
      }
    }
    await wall.close();
    await f.trim(peer);
    expect(
      f.rows("SELECT path FROM entries WHERE tier='original'"),
      hasLength(20),
    );
    expect(f.rows('SELECT path FROM original_fallbacks'), hasLength(12));

    // Successful thumbnail publication atomically ends the temporary fallback.
    for (var i = 0; i < 10; i++) {
      await peer.write(
        'thumbnail',
        {File(f.path(i, tier: 'thumbnail')): List.filled(20, 42)},
        CancelToken(),
        releasesOriginalFallback: f.path(i),
      );
    }
    await f.trim(peer);
    expect(f.rows('SELECT path FROM original_fallbacks'), hasLength(2));
    expect(
      f.rows("SELECT path FROM entries WHERE tier='original'"),
      hasLength(10),
    );
    expect(await File(f.path(0)).exists(), isFalse);
    expect(await File(f.path(10)).exists(), isTrue);
    expect(await File(f.path(0, tier: 'thumbnail')).exists(), isTrue);
  });

  test(
    'gallery fallbacks remain subject to the original hard budget',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.close);
      final cache = f.cache('wall', bytes: 300);
      for (var i = 0; i < 3; i++) {
        await f.write(cache, i);
        await cache.retainOriginalUntilThumbnail(f.path(i), CancelToken());
      }
      await f.write(cache, 3);
      expect(
        f
            .rows("SELECT bytes FROM totals WHERE tier='original'")
            .single['bytes'],
        lessThanOrEqualTo(300),
      );
      expect(await File(f.path(0)).exists(), isFalse);
      expect(
        f.rows(
          'SELECT path FROM original_fallbacks WHERE path NOT IN (SELECT path FROM entries)',
        ),
        isEmpty,
      );
      await f.trim(cache);
      expect(await File(f.path(2)).exists(), isTrue);
    },
  );

  test('independent viewers and pending derivatives survive proactive original reclamation', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final a = f.cache('a'), b = f.cache('b');
    await a.updateOwners(200, 1, ['a', 'b'], CancelToken());
    await b.updateOwners(200, 1, ['a', 'b'], CancelToken());
    for (var i = 0; i < 20; i++) {
      await f.write(a, i);
      await f.write(a, i, tier: 'thumbnail');
    }
    await a.pinOriginals('window', {
      f.path(0): 400,
      f.path(1): 99,
      f.path(2): 98,
    }, CancelToken());
    await b.pinOriginals('window', {f.path(3): 400}, CancelToken());
    await a.pinOriginals('read:1', {f.path(4): 0}, CancelToken());
    await a.pinOriginals('derivative', {f.path(5): 50}, CancelToken());
    await f.trim(b);
    expect(
      f.rows("SELECT path FROM entries WHERE tier='original'"),
      hasLength(14),
    );
    expect(
      f.rows("SELECT path FROM entries WHERE tier='thumbnail'"),
      hasLength(20),
    );
    for (var i = 0; i < 6; i++) {
      expect(await File(f.path(i)).exists(), isTrue);
    }
    expect(await File(f.path(6)).exists(), isFalse);

    await a.pinOriginals('window', {
      f.path(18): 400,
      f.path(17): 99,
      f.path(16): 98,
    }, CancelToken());
    for (var i = 20; i < 30; i++) {
      await f.write(a, i);
    }
    await f.trim(a);
    expect(await File(f.path(0)).exists(), isFalse);
    for (final i in [3, 4, 5, 16, 17, 18, 29]) {
      expect(await File(f.path(i)).exists(), isTrue);
    }
    await a.updateOwners(200, 2, ['a'], CancelToken());
    await f.trim(a);
    expect(await File(f.path(3)).exists(), isFalse);
    // Replacing a window did not remove separate in-flight/derivative roles.
    expect(await File(f.path(4)).exists(), isTrue);
    expect(await File(f.path(5)).exists(), isTrue);
  });

  test('same-session owner revisions reject stale snapshots and a new session ignores clock order', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final a = f.cache('a'), b = f.cache('b');
    await a.updateOwners(200, 1, ['a'], CancelToken());
    await f.write(a, 1);
    await a.pinOriginals('window', {f.path(1): 400}, CancelToken());
    await b.updateOwners(200, 2, ['a', 'b'], CancelToken());
    await b.pinOriginals('window', {f.path(2): 400}, CancelToken());
    await a.updateOwners(200, 1, ['a'], CancelToken());
    expect(f.rows("SELECT path FROM live_pins WHERE owner='b'"), hasLength(1));
    final c = f.cache('c');
    await c.updateOwners(100, 1, ['c'], CancelToken());
    await c.pinOriginals('window', {f.path(3): 400}, CancelToken());
    expect(f.rows('SELECT owner FROM live_owners').map((row) => row['owner']), [
      'c',
    ]);
    expect(f.rows('SELECT owner FROM live_pins').map((row) => row['owner']), [
      'c',
    ]);
  });

  test('an interrupted owner commit is retried by the next mandatory pin operation', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final a = f.cache('a'), b = f.cache('b');
    await a.updateOwners(1, 1, ['a'], CancelToken());
    await f.write(a, 1);
    await f.write(b, 2);
    final lock = sqlite3.open('${f.root.path}/album-cache-v1.sqlite');
    final cancel = CancelToken();
    try {
      lock.execute('BEGIN IMMEDIATE');
      final pending = b.updateOwners(1, 2, ['a', 'b'], cancel);
      final stopped = expectLater(pending, throwsA(isA<Cancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancel.cancel();
      await stopped;
      lock.execute('ROLLBACK');
      await b.pinOriginals('window', {f.path(2): 400}, CancelToken());
      expect(
        f.rows("SELECT path FROM live_pins WHERE owner='b'"),
        hasLength(1),
      );
    } finally {
      lock.dispose();
    }
  });

  test('far originals cannot displace current or nearer frames under a small hard budget', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final cache = f.cache('viewer', bytes: 200);
    await cache.updateOwners(1, 1, ['viewer'], CancelToken());
    await f.write(cache, 0);
    await f.write(cache, 1);
    await cache.pinOriginals('window', {
      f.path(0): 400,
      f.path(1): 99,
      f.path(2): 98,
    }, CancelToken());
    expect(await cache.canAdmitOriginal(100, 98, CancelToken()), isFalse);
    expect(await f.write(cache, 2, priority: 98), isFalse);
    expect(await File(f.path(0)).exists(), isTrue);
    expect(await File(f.path(1)).exists(), isTrue);
    expect(await f.write(cache, 2, priority: 400), isTrue);
    expect(await File(f.path(0)).exists(), isTrue);
    expect(await File(f.path(1)).exists(), isFalse);
  });

  test('unprotected originals keep a byte-bounded recent tail and metadata has its own runtime limit', () async {
    final f = await _Fixture.create();
    addTearDown(f.close);
    final cache = f.cache('a', bytes: 1000, metadataBytes: 250);
    await cache.updateOwners(1, 1, ['a'], CancelToken());
    for (var i = 0; i < 9; i++) {
      await f.write(cache, i);
    }
    await f.trim(cache);
    expect(
      f.rows("SELECT bytes FROM entries WHERE tier='original'"),
      hasLength(2),
    );
    expect(await File(f.path(8)).exists(), isTrue);
    for (var i = 0; i < 2; i++) {
      await cache.write('metadata', {
        File('${f.root.path}/album-metadata-v3/$i.json'): List.filled(100, 32),
      }, CancelToken());
    }
    cache.updateLimits(10000, 1000, metadata: 150);
    await f.trim(cache);
    expect(
      f.rows("SELECT bytes FROM totals WHERE tier='metadata'").single['bytes'],
      100,
    );
  });
}
