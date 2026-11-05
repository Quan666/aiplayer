import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/album_image_cache.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:sqlite3/sqlite3.dart';

Future<List<SourceEntry>> _photos(String root) => Isolate.run(() async {
  final bytes = images.encodeJpg(images.Image(width: 800, height: 600));
  return [
    for (var i = 0; i < 48; i++)
      SourceEntry(
        name: '$i.jpg',
        path: (await File('$root/$i.jpg').writeAsBytes(bytes)).path,
        size: bytes.length,
        modified: 1,
      ),
  ];
});

Future<void> _closed(String directory) async {
  for (var i = 0; i < 300; i++) {
    final pins = await Isolate.run(() {
      final database = sqlite3.open('$directory/album-cache-v1.sqlite');
      try {
        return database
            .select('SELECT COUNT(*) AS n FROM live_pins')
            .single['n'];
      } finally {
        database.dispose();
      }
    });
    if (pins == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('The album worker did not release its pins.');
}

Future<void> _maintain(String directory) => Isolate.run(() async {
  final cache = AlbumImageDiskCache(
    directory: directory,
    adaptiveOriginals: true,
    originalBytes: 1024 * 1024 * 1024,
    originalFiles: 8192,
    thumbnailBytes: 8 * 1024 * 1024 * 1024,
    thumbnailFiles: 100000,
    publish: publishAlbumCacheFile,
    onEvicted: (_) {},
  );
  try {
    while (await cache.maintain(CancelToken())) {}
  } finally {
    await cache.close();
  }
});

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('a gallery exceeding the derivative queue keeps disk fallbacks after restart', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final root = await Directory.systemTemp.createTemp(
      'album-gallery-fallback-',
    );
    final cachePath = '${root.path}/cache';
    final entries = await _photos(root.path);
    final services = <AlbumImageService>[];
    AlbumImageService service() {
      final value = AlbumImageService(
        cacheDirectory: cachePath,
        sourceId: 'local',
        source: const {'kind': 'local'},
        maxThumbnailBytes: 8 * 1024 * 1024 * 1024,
      )..setMaintenanceHeld(true);
      services.add(value);
      return value;
    }

    try {
      final first = service();
      final paths = <String>[];
      for (final entry in entries) {
        final image = await first.load(entry).future;
        expect(image.error, isNull);
        expect(image.encodedSource, isTrue);
        paths.add(image.path!);
      }
      expect(first.derivativePendingCount, 32);
      first.dispose();
      await _closed(cachePath);

      // Use a new connection and owner, with no surviving UI or queue pins.
      // This deterministically runs the same proactive cleanup as a viewer.
      await _maintain(cachePath);
      for (final path in paths) {
        expect(await File(path).exists(), isTrue);
      }
      for (final entry in entries) {
        await File(entry.path).delete();
      }
      final reopened = service();
      for (var i = 0; i < 16; i++) {
        final image = await reopened.load(entries[i]).future;
        expect(image.error, isNull);
        expect(image.path, paths[i]);
      }
      expect(reopened.derivativePendingCount, 16);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final pending = reopened.derivativePendingCount;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(reopened.derivativePendingCount, pending);
      expect(reopened.derivativeActiveCount, 0);
    } finally {
      for (final service in services) {
        service.dispose();
      }
      await _closed(cachePath);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await root.delete(recursive: true);
    }
  });
}
