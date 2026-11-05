import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('large detail browsing cannot evict a prepared wall image or refetch it after restart', () async {
    final root = await Directory.systemTemp.createTemp('album-image-tiers-');
    final bytes = images.encodeJpg(images.Image(width: 1200, height: 800));
    final entries = <SourceEntry>[];
    for (final name in ['wall', 'other']) {
      final source = await File('${root.path}/$name.jpg').writeAsBytes(bytes);
      entries.add(
        SourceEntry(
          name: '$name.jpg',
          path: source.path,
          size: bytes.length,
          modified: 1,
        ),
      );
    }
    final services = <AlbumImageService>[];
    AlbumImageService service({bool original = false}) {
      final service = AlbumImageService(
        cacheDirectory: '${root.path}/cache',
        sourceId: 'local',
        source: const {'kind': 'local'},
        maxCacheFiles: 2,
        preferOriginal: original,
        observeLifecycle: false,
      );
      services.add(service);
      return service;
    }

    try {
      final wall = service();
      final quick = await wall.load(entries.first).future;
      expect(quick.encodedSource, isTrue);
      for (var i = 0; i < 300 && wall.derivativePendingCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(wall.derivativePendingCount, 0);
      final small = wall.peekPrepared(entries.first)!;
      expect(small.error, isNull);
      expect(small.width, 512);
      expect(small.encodedSource, isFalse);
      final viewer = service(original: true);
      final full = await viewer.load(entries.first, targetEdge: 2048).future;
      expect(full.encodedSource, isTrue);
      expect(full.width, 1200);
      expect(full.path, isNot(small.path));
      await viewer.load(entries.last, targetEdge: 2048).future;
      expect(await File(full.path!).exists(), isFalse);
      expect(await File(small.path!).exists(), isTrue);
      expect(wall.peek(entries.first), same(small));
      await File(entries.first.path).delete();
      final reopened = await service()
          .load(entries.first, targetEdge: 320)
          .future;
      expect(reopened.error, isNull);
      expect(reopened.path, small.path);
    } finally {
      for (final service in services) {
        service.dispose();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await root.delete(recursive: true);
    }
  });

  test('small pixel JPEG with oversized ancillary bytes stays small in thumbnail tier', () async {
    final root = await Directory.systemTemp.createTemp(
      'album-thumbnail-padding-',
    );
    final jpeg = images.encodeJpg(images.Image(width: 200, height: 100));
    final bytes = Uint8List(1024 * 1024)..setRange(0, jpeg.length, jpeg);
    final file = await File('${root.path}/photo.jpg').writeAsBytes(bytes);
    final entry = SourceEntry(
      name: 'photo.jpg',
      path: file.path,
      size: bytes.length,
      modified: 1,
    );
    final service = AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    try {
      // A source larger than the new original budget must still get a valid
      // thumbnail, including when the limit changes before the worker starts.
      service.updateCacheLimits(
        thumbnailBytes: 512 * 1024,
        originalBytes: 512 * 1024,
      );
      final small = await service.load(entry).future;
      expect(small.error, isNull);
      expect((small.width, small.height), (200, 100));
      expect(await File(small.path!).length(), lessThan(128 * 1024));
    } finally {
      service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await root.delete(recursive: true);
    }
  });

  test('large JPEG source dimensions use bounded DC-only decoding while PNG keeps its pixel limit', () {
    final pixels = images.Image(width: 800, height: 600);
    final jpeg = images.encodeJpg(pixels);
    final decoded = decodeAlbumImage(jpeg, edge: 512, maxPixels: 20000);
    expect(decoded, isNotNull);
    expect((decoded!.width, decoded.height), (100, 75));
    expect(
      decodeAlbumImage(images.encodePng(pixels), edge: 512, maxPixels: 20000),
      isNull,
    );
  });
}
