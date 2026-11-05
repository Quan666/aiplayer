import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/album_image_cache.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _Fixture {
  final Directory root;
  final evictions = <List<String>>[];
  final caches = <AlbumImageDiskCache>[];
  _Fixture(this.root);

  static Future<_Fixture> create() async =>
      _Fixture(await Directory.systemTemp.createTemp('album-disk-index-'));

  AlbumImageDiskCache cache({
    int originalBytes = 1000,
    int originalFiles = 1000,
    int thumbnailBytes = 1000,
    Future<void> Function(File, List<int>, CancelToken)? publish,
    void Function(List<String>)? onEvicted,
  }) {
    final value = AlbumImageDiskCache(
      directory: root.path,
      originalBytes: originalBytes,
      originalFiles: originalFiles,
      thumbnailBytes: thumbnailBytes,
      thumbnailFiles: 1000,
      publish:
          publish ??
          (file, bytes, cancel) => publishAlbumCacheFile(file, bytes, cancel),
      onEvicted: (paths) {
        evictions.add(List.of(paths));
        onEvicted?.call(paths);
      },
    );
    caches.add(value);
    return value;
  }

  File image(String tier, String name) => File(
    '${root.path}/${tier == 'original' ? 'album-images-v2' : 'album-thumbnails-v1'}/$name.jpg',
  );

  Future<void> write(
    AlbumImageDiskCache cache,
    String tier,
    String name, {
    int bytes = 200,
    CancelToken? cancel,
  }) {
    final file = image(tier, name);
    return cache.write(tier, {
      file: List.filled(bytes, 42),
      File('${file.path}.json'): List.filled(10, 32),
    }, cancel ?? CancelToken());
  }

  List<Map<String, Object?>> rows(String sql) {
    final database = sqlite3.open('${root.path}/album-cache-v1.sqlite');
    try {
      return database
          .select(sql)
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    } finally {
      database.dispose();
    }
  }

  Future<void> verifyAccounting() async {
    final entries = rows('SELECT path,bytes,files FROM entries');
    var sumBytes = 0, sumFiles = 0;
    for (final entry in entries) {
      var bytes = 0, files = 0;
      for (final name in [entry['path'] as String, '${entry['path']}.json']) {
        final stat = await File(name).stat();
        if (stat.type == FileSystemEntityType.file) {
          bytes += stat.size;
          files++;
        }
      }
      expect(entry['bytes'], bytes);
      expect(entry['files'], files);
      sumBytes += bytes;
      sumFiles += files;
    }
    final totals = rows(
      'SELECT SUM(bytes) AS bytes,SUM(files) AS files FROM totals',
    ).single;
    expect(totals['bytes'], sumBytes);
    expect(totals['files'], sumFiles);
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
    'original eviction preserves persistent thumbnails across worker restart',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final wall = fixture.cache(originalBytes: 500);
      await fixture.write(wall, 'thumbnail', 'retained');
      await fixture.write(wall, 'original', 'first');
      await fixture.write(wall, 'original', 'second');
      await wall.close();
      final viewer = fixture.cache(originalBytes: 500);
      await fixture.write(viewer, 'original', 'third');
      expect(await fixture.image('original', 'first').exists(), isFalse);
      expect(await fixture.image('thumbnail', 'retained').exists(), isTrue);
      expect(
        fixture
            .rows("SELECT files FROM totals WHERE tier='original'")
            .single['files'],
        4,
      );
      await fixture.verifyAccounting();
    },
  );

  test(
    'byte pressure uses LRU hysteresis and replacement counts only growth',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final cache = fixture.cache();
      for (var i = 0; i < 10; i++) {
        await fixture.write(cache, 'original', '$i', bytes: 90);
      }
      await fixture.write(cache, 'original', '9', bytes: 90);
      expect(
        fixture.evictions,
        isEmpty,
        reason: 'An in-place refresh uses no extra capacity.',
      );
      await cache.touch([fixture.image('original', '0').path]);
      await fixture.write(cache, 'original', '10', bytes: 90);
      expect(await fixture.image('original', '0').exists(), isTrue);
      expect(fixture.evictions.single, hasLength(2));
      expect(
        fixture
            .rows("SELECT bytes FROM totals WHERE tier='original'")
            .single['bytes'],
        900,
      );
      await fixture.verifyAccounting();
    },
  );

  test(
    'failed publication reconciles deleted victims and a partial image pair',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final cache = fixture.cache(
        originalFiles: 2,
        publish: (file, bytes, cancel) async {
          await publishAlbumCacheFile(file, bytes, cancel);
          if (file.path.endsWith('/broken.jpg')) cancel.cancel();
        },
      );
      await fixture.write(cache, 'original', 'old');
      await expectLater(
        fixture.write(cache, 'original', 'broken'),
        throwsA(isA<Cancelled>()),
      );
      expect(await fixture.image('original', 'old').exists(), isFalse);
      expect(await fixture.image('original', 'broken').exists(), isTrue);
      expect(
        await File('${fixture.image('original', 'broken').path}.json').exists(),
        isFalse,
      );
      expect(fixture.evictions.single, [fixture.image('original', 'old').path]);
      await fixture.verifyAccounting();
      await cache.close();
      final reopened = fixture.cache(originalFiles: 2);
      await fixture.write(reopened, 'original', 'replacement');
      expect(await fixture.image('original', 'broken').exists(), isFalse);
      await fixture.verifyAccounting();
    },
  );

  test(
    'lowering both tier limits drains each tier in bounded maintenance turns',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final cache = fixture.cache();
      for (final tier in ['original', 'thumbnail']) {
        await fixture.write(cache, tier, 'first');
        await fixture.write(cache, tier, 'last');
      }
      cache.updateLimits(250, 250);
      expect(await cache.maintain(CancelToken()), isTrue);
      expect(await cache.maintain(CancelToken()), isFalse);
      for (final tier in ['original', 'thumbnail']) {
        expect(
          fixture
              .rows("SELECT bytes FROM totals WHERE tier='$tier'")
              .single['bytes'],
          210,
        );
        expect(await fixture.image(tier, 'last').exists(), isTrue);
      }
      await fixture.verifyAccounting();
    },
  );

  test(
    'cancelled maintenance still reports every deleted path and repairs totals',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final cache = fixture.cache(originalBytes: 100000);
      for (var i = 0; i < 100; i++) {
        await fixture.write(cache, 'original', '$i');
      }
      cache.updateLimits(1000, 100);
      final cancel = CancelToken();
      final maintenance = cache.maintain(cancel);
      final stopped = expectLater(maintenance, throwsA(isA<Cancelled>()));
      for (var attempt = 0; attempt < 1000; attempt++) {
        if (!await fixture.image('original', '0').exists()) break;
        await Future<void>.delayed(Duration.zero);
      }
      cancel.cancel();
      await stopped;
      expect(fixture.evictions, isNotEmpty);
      expect(fixture.evictions.every((batch) => batch.length <= 64), isTrue);
      await fixture.verifyAccounting();
    },
  );
  test(
    'a write after major downsizing releases the shared lock every 64 victims',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      var batches = 0;
      final cache = fixture.cache(
        originalBytes: 100000,
        onEvicted: (paths) {
          expect(paths.length, lessThanOrEqualTo(64));
          if (++batches != 1) return;
          final peer = sqlite3.open(
            '${fixture.root.path}/album-cache-v1.sqlite',
          );
          try {
            peer.execute('PRAGMA busy_timeout=0');
            peer.execute('BEGIN IMMEDIATE');
            expect(
              peer.select('SELECT COUNT(*) AS n FROM entries').single['n'],
              greaterThan(2),
            );
            expect(
              peer.select('SELECT path FROM entries WHERE path=?', [
                fixture.image('original', 'incoming').path,
              ]),
              isEmpty,
            );
            peer.execute('COMMIT');
          } finally {
            peer.dispose();
          }
        },
      );
      for (var i = 0; i < 100; i++) {
        await fixture.write(cache, 'original', '$i');
      }
      cache.updateLimits(1000, 500);
      await fixture.write(cache, 'original', 'incoming');
      expect(batches, greaterThan(1));
      expect(await fixture.image('original', 'incoming').exists(), isTrue);
      expect(
        fixture
            .rows("SELECT bytes FROM totals WHERE tier='original'")
            .single['bytes'],
        lessThanOrEqualTo(500),
      );
      await fixture.verifyAccounting();
    },
  );
}
