import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/album_view_settings.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/sources/configuration.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Background worker did not reach the expected state.');
}

Uint8List _rawWithOrientation(
  Uint8List jpeg,
  int orientation, {
  Endian endian = Endian.little,
  int? previewOrientation,
}) {
  final bytes = Uint8List(128 + jpeg.length)
    ..setRange(128, 128 + jpeg.length, jpeg);
  bytes[0] = bytes[1] = endian == Endian.little ? 0x49 : 0x4d;
  final data = ByteData.sublistView(bytes);
  void u16(int at, int value) => data.setUint16(at, value, endian);
  void u32(int at, int value) => data.setUint32(at, value, endian);
  void ifd(int at, int value, {int next = 0, bool preview = true}) {
    u16(at, preview ? 2 : 1);
    u16(at + 2, 0x112);
    u16(at + 4, 3);
    u32(at + 6, 1);
    u16(at + 10, value);
    if (preview) {
      u16(at + 14, 0x201);
      u16(at + 16, 4);
      u32(at + 18, 1);
      u32(at + 22, 128);
    }
    u32(at + 2 + (preview ? 24 : 12), next);
  }

  u16(2, 42);
  u32(4, 8);
  ifd(
    8,
    orientation,
    next: previewOrientation == null ? 0 : 48,
    preview: previewOrientation == null,
  );
  if (previewOrientation != null) ifd(48, previewOrientation);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => overrideSystemProxyPlatformForTesting('test'));

  for (final extension in ['jpg', 'png']) {
    test(
      'missing and corrupt $extension prepared files recover without invalidating other images',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'album-repair-$extension-',
        );
        final pixels = images.Image(width: 80, height: 40);
        final bytes = extension == 'jpg'
            ? images.encodeJpg(pixels)
            : images.encodePng(pixels);
        final source = await File('${root.path}/photo.$extension')
            .writeAsBytes(bytes);
        final other = await File('${root.path}/other.$extension')
            .writeAsBytes(bytes);
        final service = AlbumImageService(
          cacheDirectory: '${root.path}/cache',
          sourceId: 'local',
          source: const {'kind': 'local'},
          observeLifecycle: false,
        );
        final entry = SourceEntry(
          name: 'photo.$extension',
          path: source.path,
          size: bytes.length,
          modified: 1,
        );
        final otherEntry = SourceEntry(
          name: 'other.$extension',
          path: other.path,
          size: bytes.length,
          modified: 1,
        );
        try {
          final first = await service.load(entry, targetEdge: 64).future;
          final unrelated = await service
              .load(otherEntry, targetEdge: 64)
              .future;
          await File(first.path!).delete();
          // A resident prepared result cannot notice an external cache deletion.
          expect(
            (await service.load(entry, targetEdge: 64).future).path,
            first.path,
          );
          expect(await File(first.path!).exists(), isFalse);
          final revision = service.revision;
          service.invalidatePrepared(
            entry,
            targetEdge: 64,
            failedPath: first.path,
          );
          expect(service.peek(entry), isNull);
          expect(service.wasEvicted(first.path!), isTrue);
          expect(service.peek(otherEntry), same(unrelated));
          expect(service.revision, revision);
          service.setScrolling(true);
          var completed = false;
          final repair = service.load(entry, targetEdge: 64);
          unawaited(repair.future.then((_) => completed = true));
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(
            completed,
            isFalse,
            reason: 'Repair must not reopen sources during a scroll.',
          );
          service.setScrolling(false);
          final joined = service.load(entry, targetEdge: 64);
          final results = await Future.wait([repair.future, joined.future]);
          expect(results.first.error, isNull);
          expect(results.last.path, results.first.path);
          expect(await File(results.first.path!).exists(), isTrue);
          expect(
            images.decodeJpg(await File(results.first.path!).readAsBytes()),
            isNotNull,
          );
          expect(service.peek(otherEntry), same(unrelated));

          await File(results.first.path!).writeAsBytes([0, 1, 2]);
          service.invalidatePrepared(
            entry,
            targetEdge: 64,
            failedPath: results.first.path,
          );
          final recovered = await service.load(entry, targetEdge: 64).future;
          expect(recovered.error, isNull);
          expect(
            images.decodeJpg(await File(recovered.path!).readAsBytes()),
            isNotNull,
          );
          expect(service.wasEvicted(recovered.path!), isFalse);
        } finally {
          service.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await root.delete(recursive: true);
        }
      },
    );
  }

  test('another album worker can prune a retained path and targeted repair restores it', () async {
    final root = await Directory.systemTemp.createTemp(
      'album-shared-cache-prune-',
    );
    final bytes = images.encodeJpg(images.Image(width: 40, height: 30));
    final firstFile = await File('${root.path}/a.jpg').writeAsBytes(bytes);
    final secondFile = await File('${root.path}/b.jpg').writeAsBytes(bytes);
    AlbumImageService service() => AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
      maxCacheFiles: 2,
      maxThumbnailFiles: 2,
    );
    final wall = service(), viewer = service();
    final entry = SourceEntry(
      name: 'a.jpg',
      path: firstFile.path,
      size: bytes.length,
      modified: 1,
    );
    try {
      final retained = await wall.load(entry).future;
      await viewer
          .load(
            SourceEntry(
              name: 'b.jpg',
              path: secondFile.path,
              size: bytes.length,
              modified: 1,
            ),
          )
          .future;
      expect(await File(retained.path!).exists(), isFalse);
      expect(
        wall.wasEvicted(retained.path!),
        isTrue,
        reason: 'Peer services receive one batched invalidation.',
      );
      expect(wall.peek(entry), isNull);
      wall.invalidatePrepared(entry, failedPath: retained.path);
      final repaired = await wall.load(entry).future;
      expect(repaired.error, isNull);
      expect(await File(repaired.path!).exists(), isTrue);
      expect(
        await firstFile.readAsBytes(),
        bytes,
        reason: 'Repair must never delete or replace the local source.',
      );
    } finally {
      wall.dispose();
      viewer.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test('late repair for an older entry cannot replace a newer revision or revive cancelled work', () async {
    final root = await Directory.systemTemp.createTemp(
      'album-repair-revision-',
    );
    final oldBytes = images.encodeJpg(images.Image(width: 80, height: 40));
    final newBytes = images.encodeJpg(images.Image(width: 40, height: 80));
    final file = await File('${root.path}/photo.jpg').writeAsBytes(oldBytes);
    final service = AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    final oldEntry = SourceEntry(
      name: 'photo.jpg',
      path: file.path,
      size: oldBytes.length,
      modified: 1,
    );
    final newEntry = SourceEntry(
      name: 'photo.jpg',
      path: file.path,
      size: newBytes.length,
      modified: 2,
    );
    try {
      final old = await service.load(oldEntry).future;
      service.setActive(false);
      service.invalidatePrepared(oldEntry, failedPath: old.path);
      final cancelled = service.load(oldEntry);
      service.invalidate();
      expect((await cancelled.future).cancelled, isTrue);
      await file.writeAsBytes(newBytes);
      final latestRequest = service.load(newEntry);
      service.setActive(true);
      final latest = await latestRequest.future;
      expect(latest.error, isNull);
      expect((latest.width, latest.height), (40, 80));

      service.invalidatePrepared(oldEntry, failedPath: old.path);
      expect(service.peek(newEntry), same(latest));
      final lateRepair = await service.load(oldEntry).future;
      expect(lateRepair.error, isNull);
      expect(service.peek(newEntry), same(latest));
      expect(await File(latest.path!).readAsBytes(), newBytes);
      expect((await service.load(newEntry).future).path, latest.path);
      expect(await file.readAsBytes(), newBytes);
    } finally {
      service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test(
    'JPEG display sizes share original bytes and never redownload or transcode',
    () async {
      final root = await Directory.systemTemp.createTemp('album-native-jpeg-');
      final original = images.Image(width: 800, height: 600);
      original.exif.imageIfd.orientation = 6;
      original.exif.imageIfd['Model'] = 'Camera example';
      final jpeg = images.encodeJpg(original, quality: 95);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0, transferred = 0;
      server.listen((request) async {
        requests++;
        transferred += jpeg.length;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'content-range',
          'bytes 0-${jpeg.length - 1}/${jpeg.length}',
        );
        request.response.contentLength = jpeg.length;
        request.response.add(jpeg);
        await request.response.close();
      });
      AlbumImageService service() => AlbumImageService(
        cacheDirectory: root.path,
        sourceId: 'http',
        source: {'kind': 'http', 'url': 'http://127.0.0.1:${server.port}/'},
        observeLifecycle: false,
        preferOriginal: true,
      );
      final first = service(), second = service(), third = service();
      final entry = SourceEntry(
        name: 'photo.jpg',
        path: '/photo.jpg',
        size: jpeg.length,
        modified: 1,
      );
      try {
        final wall = await first.load(entry, targetEdge: 128).future;
        final viewer = await first.load(entry, targetEdge: 2048).future;
        final reopened = await second.load(entry, targetEdge: 2560).future;
        expect(wall.error, isNull);
        expect(wall.encodedSource, isTrue);
        expect(viewer.path, wall.path);
        expect(reopened.path, wall.path);
        expect(reopened.encodedSource, isTrue);
        expect((viewer.width, viewer.height), (600, 800));
        expect(viewer.orientation, 6);
        expect(viewer.exif['相机型号'], 'Camera example');
        expect(await File(viewer.path!).readAsBytes(), jpeg);
        expect(requests, 1);
        expect(transferred, jpeg.length);
        expect(first.peekPrepared(entry, targetEdge: 128)?.path, wall.path);
        expect(
          first.peekPrepared(
            SourceEntry(
              name: entry.name,
              path: entry.path,
              size: entry.size,
              modified: 2,
            ),
            targetEdge: 128,
          ),
          isNull,
        );

        await Directory('${root.path}/album-metadata-v3')
            .delete(recursive: true);
        final recoveredFacts = await third.loadMetadata(entry).future;
        expect(recoveredFacts.path, isNull);
        expect(recoveredFacts.exif['相机型号'], 'Camera example');
        expect(requests, 1);

        // The same path with a new source revision must fetch fresh bytes.
        final changed = await first
            .load(
              SourceEntry(
                name: entry.name,
                path: entry.path,
                size: entry.size,
                modified: 2,
              ),
              targetEdge: 1024,
            )
            .future;
        expect(changed.path, isNot(viewer.path));
        expect(requests, 2);
      } finally {
        first.dispose();
        second.dispose();
        third.dispose();
        await server.close(force: true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await root.delete(recursive: true);
      }
    },
  );

  test('changing a source endpoint cannot reuse another origins same-revision image', () async {
    final root = await Directory.systemTemp.createTemp(
      'album-source-revision-',
    );
    final servers = [
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ];
    final requests = [0, 0];
    for (var index = 0; index < servers.length; index++) {
      final source = images.Image(width: 20, height: 20);
      images.fill(
        source,
        color: index == 0
            ? images.ColorRgb8(240, 10, 10)
            : images.ColorRgb8(10, 10, 240),
      );
      final encoded = images.encodeJpg(source);
      final bytes = Uint8List(2048)..setRange(0, encoded.length, encoded);
      servers[index].listen((request) async {
        requests[index]++;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('content-range', 'bytes 0-2047/2048');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
    }
    AlbumImageService service(int origin, {String label = 'source'}) =>
        AlbumImageService(
          cacheDirectory: root.path,
          sourceId: 'same-id',
          observeLifecycle: false,
          source: {
            'kind': 'http',
            'url': 'http://127.0.0.1:${servers[origin].port}/',
            'label': label,
          },
        );
    const entry = SourceEntry(
      name: 'photo.jpg',
      path: '/photo.jpg',
      size: 2048,
      modified: 1,
    );
    final first = service(0),
        second = service(1),
        relabelled = service(0, label: 'renamed');
    try {
      final a = await first.load(entry).future;
      final b = await second.load(entry).future;
      final renamed = await relabelled.load(entry).future;
      expect(a.path, isNotNull);
      expect(b.path, isNotNull);
      expect(a.path, isNot(b.path));
      expect(renamed.path, a.path);
      expect(requests, [1, 1]);
      final pixel = images
          .decodeJpg(await File(b.path!).readAsBytes())!
          .getPixel(10, 10);
      expect(pixel.b, greaterThan(200));
      expect(pixel.r, lessThan(50));
    } finally {
      first.dispose();
      second.dispose();
      relabelled.dispose();
      for (final server in servers) {
        await server.close(force: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  testWidgets(
    'bounded parallel reads pause without a frame and resume every demand',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('album-parallel-');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final bytes = images.encodeJpg(images.Image(width: 40, height: 30));
        final release = Completer<void>();
        var requests = 0;
        server.listen((request) async {
          requests++;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'content-range',
            'bytes 0-${bytes.length - 1}/${bytes.length}',
          );
          request.response.contentLength = bytes.length;
          try {
            request.response.add(bytes.sublist(0, 1));
            await request.response.flush();
            await release.future;
            request.response.add(bytes.sublist(1));
            await request.response.close();
          } catch (_) {}
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final service = AlbumImageService(
          cacheDirectory: root.path,
          sourceId: 'http',
          source: {'kind': 'http', 'url': 'http://127.0.0.1:${server.port}/'},
        );
        final handles = List.generate(
          4,
          (i) => service.load(
            SourceEntry(
              name: '$i.jpg',
              path: '/$i.jpg',
              size: bytes.length,
              modified: 1,
            ),
          ),
        );
        try {
          await _until(() => requests == 3);
          expect(service.activeCount, 3);
          expect(service.pendingCount, 4);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          // No pump: all network lanes must cancel directly, and slot four stays idle.
          await _until(() => service.activeCount == 0);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(requests, 3);
          expect(service.pendingCount, 4);
          release.complete();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          final results = await Future.wait(
            handles.map((handle) => handle.future),
          );
          expect(results.every((result) => result.path != null), isTrue);
          expect(requests, 7);
        } finally {
          if (!release.isCompleted) release.complete();
          service.dispose();
          await server.close(force: true);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await root.delete(recursive: true);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      });
    },
  );

  test('metadata reads a bounded header without stat and shares full image facts across sizes', () async {
    final root = await Directory.systemTemp.createTemp('album-header-budget-');
    final original = images.Image(width: 120, height: 80);
    original.exif.exifIfd['DateTimeOriginal'] = '2026:09:01 10:00:00';
    final jpeg = images.encodeJpg(original);
    final bytes = Uint8List(1024 * 1024)..setRange(0, jpeg.length, jpeg);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var reads = 0, head = 0, transferred = 0;
    server.listen((request) async {
      if (request.method == 'HEAD') head++;
      final range = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers.value('range') ?? '')!;
      final start = int.parse(range[1]!), end = int.parse(range[2]!);
      reads++;
      transferred += end - start + 1;
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes $start-$end/${bytes.length}',
      );
      request.response.contentLength = end - start + 1;
      request.response.add(bytes.sublist(start, end + 1));
      await request.response.close();
    });
    AlbumImageService service() => AlbumImageService(
      cacheDirectory: root.path,
      sourceId: 'http',
      source: {'kind': 'http', 'url': 'http://127.0.0.1:${server.port}/'},
      observeLifecycle: false,
    );
    final first = service();
    final entry = SourceEntry(
      name: 'photo.jpg',
      path: '/photo.jpg',
      size: bytes.length,
      modified: 1,
    );
    try {
      final facts = await first.loadMetadata(entry).future;
      expect(facts.capturedAt, isNotNull);
      expect(head, 0);
      expect(transferred, 128 * 1024);
      await first.load(entry, targetEdge: 128).future;
      final before = reads;
      final cached = await first.loadMetadata(entry).future;
      expect(cached.capturedAt, facts.capturedAt);
      expect(reads, before);
      final second = service();
      try {
        expect(
          (await second.loadMetadata(entry).future).capturedAt,
          facts.capturedAt,
        );
        expect(reads, before);
      } finally {
        second.dispose();
      }
    } finally {
      first.dispose();
      await server.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test(
    'truncated metadata header is not a cached permanent missing capture time',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'album-header-truncated-',
      );
      final original = images.Image(width: 40, height: 30);
      original.exif.exifIfd['DateTimeOriginal'] = '2026:09:01 10:00:00';
      final jpeg = images.encodeJpg(original);
      final data = BytesBuilder(copy: false)..add([0xff, 0xd8]);
      for (var i = 0; i < 3; i++) {
        final app = Uint8List(65537)..setRange(0, 4, [0xff, 0xe2, 0xff, 0xff]);
        data.add(app);
      }
      data.add(jpeg.sublist(2));
      final bytes = data.takeBytes();
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
        final first = await service.loadMetadata(entry).future;
        expect(first.capturedAt, isNull);
        expect(first.metadataIncomplete, isTrue);
        final second = await service.loadMetadata(entry).future;
        expect(second.metadataIncomplete, isTrue);
        expect(identical(first, second), isFalse);
        expect(await Directory('${root.path}/cache').exists(), isFalse);
        final full = await service.load(entry, targetEdge: 64).future;
        expect(full.path, isNotNull);
        expect(full.capturedAt, isNotNull);
        expect(
          (await service.loadMetadata(entry).future).capturedAt,
          full.capturedAt,
        );
      } finally {
        service.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'visible image requests overtake queued prefetch and promotion is honored',
    () async {
      final root = await Directory.systemTemp.createTemp('album-priority-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = images.encodeJpg(images.Image(width: 20, height: 20));
      final started = Completer<void>(), release = Completer<void>();
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        if (paths.length == 1) {
          started.complete();
          await release.future;
        }
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'content-range',
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        );
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final service = AlbumImageService(
        cacheDirectory: root.path,
        sourceId: 'http',
        source: {'kind': 'http', 'url': 'http://127.0.0.1:${server.port}/'},
        observeLifecycle: false,
        maxConcurrentRequests: 1,
      );
      SourceEntry entry(int index) => SourceEntry(
        name: '$index.jpg',
        path: '/$index.jpg',
        size: bytes.length,
        modified: 1,
      );
      try {
        final running = service.load(entry(0));
        await started.future;
        final nearby = service.load(entry(1), priority: 2);
        final promoted = service.load(entry(2), priority: 2);
        final visible = service.load(entry(3));
        promoted.updatePriority!(1);
        release.complete();
        await Future.wait([
          running.future,
          nearby.future,
          promoted.future,
          visible.future,
        ]);
        expect(paths, ['/0.jpg', '/3.jpg', '/2.jpg', '/1.jpg']);
      } finally {
        if (!release.isCompleted) release.complete();
        service.dispose();
        await server.close(force: true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await root.delete(recursive: true);
      }
    },
  );

  test('scrolling serves disk thumbnails but defers uncached source work until idle', () async {
    final root = await Directory.systemTemp.createTemp('album-scroll-cache-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = images.encodeJpg(images.Image(width: 120, height: 80));
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes 0-${bytes.length - 1}/${bytes.length}',
      );
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    AlbumImageService service() => AlbumImageService(
      cacheDirectory: root.path,
      sourceId: 'http',
      source: {'kind': 'http', 'url': 'http://127.0.0.1:${server.port}/'},
      observeLifecycle: false,
    );
    final warm = SourceEntry(
      name: 'warm.jpg',
      path: '/warm.jpg',
      size: bytes.length,
      modified: 1,
    );
    final cold = SourceEntry(
      name: 'cold.jpg',
      path: '/cold.jpg',
      size: bytes.length,
      modified: 1,
    );
    final seed = service();
    AlbumImageService? viewer;
    try {
      final original = await seed.load(warm, targetEdge: 100).future;
      expect(original.path, isNotNull);
      expect(requests, 1);
      seed.dispose();
      final active = viewer = service()..setScrolling(true);
      var coldCompleted = false;
      final deferred = active.load(cold, targetEdge: 100);
      unawaited(deferred.future.then((_) => coldCompleted = true));
      // A preceding cache miss must not hold up a later cached cell.
      final cached = await active
          .load(warm, targetEdge: 110)
          .future
          .timeout(const Duration(seconds: 5));
      expect(cached.path, original.path);
      await _until(() => active.activeCount == 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(requests, 1);
      expect(coldCompleted, isFalse);
      expect(active.pendingCount, 1);
      active.setScrolling(false);
      expect((await deferred.future).path, isNotNull);
      expect(requests, 2);
    } finally {
      seed.dispose();
      viewer?.dispose();
      await server.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test('JPEG thumbnails retain content while bounding both decoded edges', () {
    final original = images.Image(width: 1600, height: 1200);
    images.fill(original, color: images.ColorRgb8(220, 30, 40));
    final bytes = images.encodeJpg(original);
    final thumbnail = decodeAlbumImage(bytes, edge: 200, maxPixels: 2000000)!;
    expect((thumbnail.width, thumbnail.height), (200, 150));
    expect(thumbnail.getPixel(100, 75).r, greaterThan(190));
    expect(decodeAlbumImage(bytes, edge: 200, maxPixels: 1000), isNull);
  });

  test('RAW preview extraction selects the largest bounded complete JPEG', () {
    final small = images.encodeJpg(images.Image(width: 8, height: 8));
    final large = images.encodeJpg(images.Image(width: 80, height: 40));
    final bytes = Uint8List.fromList([
      0x49,
      0x49,
      0x2a,
      0,
      ...small,
      1,
      2,
      3,
      ...large,
      0xff,
      0xd8,
      0xff,
    ]);
    final preview = extractAlbumRawJpeg(bytes, maxPixels: 10000)!;
    final decoded = images.decodeJpg(preview)!;
    expect((decoded.width, decoded.height), (80, 40));
    final limited = extractAlbumRawJpeg(bytes, maxPixels: 100)!;
    expect(images.decodeJpg(limited)!.width, 8);
    expect(extractAlbumRawJpeg(Uint8List(50), maxPixels: 100), isNull);
  });

  test('RAW TIFF orientation covers all transforms and embedded EXIF wins exactly once', () {
    final original = images.Image(width: 40, height: 20);
    for (var y = 0; y < original.height; y++) {
      for (var x = 0; x < original.width; x++) {
        original.setPixelRgb(x, y, x * 5, y * 10, 30);
      }
    }
    final plain = images.encodeJpg(original);
    for (var value = 1; value <= 8; value++) {
      for (final endian in [Endian.little, Endian.big]) {
        final raw = _rawWithOrientation(plain, value, endian: endian);
        final preview = extractAlbumRawJpeg(raw, maxPixels: 10000)!;
        final orientation = readAlbumRawOrientation(
          raw,
          previewOffset: preview.offsetInBytes - raw.offsetInBytes,
        );
        expect(orientation, value);
        final decoded = decodeAlbumImage(
          preview,
          edge: 100,
          maxPixels: 10000,
          fallbackOrientation: orientation,
        )!;
        final expected = images.bakeOrientation(
          images.decodeJpg(plain)!..exif.imageIfd.orientation = value,
        );
        expect(
          (decoded.width, decoded.height),
          (expected.width, expected.height),
        );
        expect(
          decoded.getPixel(0, 0).toList(),
          expected.getPixel(0, 0).toList(),
        );
        expect(decoded.exif.imageIfd.orientation, isNull);
      }
    }
    for (final embedded in [1, 6, 8]) {
      original.exif.imageIfd.orientation = embedded;
      final jpeg = images.encodeJpg(original);
      final decoded = decodeAlbumImage(
        jpeg,
        edge: 100,
        maxPixels: 10000,
        fallbackOrientation: 6,
      )!;
      final expected = images.decodeJpg(jpeg)!;
      expect(
        (decoded.width, decoded.height),
        (expected.width, expected.height),
      );
      expect(decoded.getPixel(0, 0).toList(), expected.getPixel(0, 0).toList());
      expect(decoded.exif.imageIfd.orientation, isNull);
    }
    final ownPreview = _rawWithOrientation(plain, 6, previewOrientation: 1);
    expect(readAlbumRawOrientation(ownPreview, previewOffset: 128), 1);
    final subIfd = _rawWithOrientation(plain, 6, previewOrientation: 8);
    final tags = ByteData.sublistView(subIfd);
    tags.setUint16(8, 2, Endian.little);
    tags.setUint16(22, 0x14a, Endian.little);
    tags.setUint16(24, 4, Endian.little);
    tags.setUint32(26, 1, Endian.little);
    tags.setUint32(30, 48, Endian.little);
    tags.setUint32(34, 0, Endian.little);
    expect(readAlbumRawOrientation(subIfd, previewOffset: 128), 8);
    // Preview tags with unrelated offsets do not override the primary IFD.
    expect(readAlbumRawOrientation(ownPreview, previewOffset: 127), 6);
    expect(
      readAlbumRawOrientation(
        Uint8List.fromList([0x49, 0x49, 42, 0, 255, 255, 255, 255]),
        previewOffset: 0,
      ),
      isNull,
    );
    expect(
      readAlbumRawOrientation(
        _rawWithOrientation(plain, 9),
        previewOffset: 128,
      ),
      isNull,
    );
    final cyclic = _rawWithOrientation(plain, 6);
    ByteData.sublistView(cyclic).setUint32(34, 8, Endian.little);
    expect(readAlbumRawOrientation(cyclic, previewOffset: 0), 6);
  });

  test('worker caches upright RAW preview and persists orientation without fabricated dimensions', () async {
    final directory = await Directory.systemTemp.createTemp(
      'album-raw-orientation-',
    );
    final jpeg = images.encodeJpg(images.Image(width: 80, height: 40));
    final file = await File('${directory.path}/portrait.arw')
        .writeAsBytes(_rawWithOrientation(jpeg, 6));
    final stat = await file.stat();
    final entry = SourceEntry(
      name: 'portrait.arw',
      path: file.path,
      size: stat.size,
      modified: stat.modified.millisecondsSinceEpoch,
    );
    final normalized = sourceFormValues(const {'kind': 'local'});
    final oldKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              3,
              'local',
              [
                for (final key in [
                  'kind',
                  'url',
                  'host',
                  'port',
                  'share',
                  'domain',
                  'user',
                  'smbSecurity',
                ])
                  normalized[key],
              ],
              entry.path,
              entry.size,
              entry.modified,
              512,
            ]),
          ),
        )
        .toString();
    final oldCache = File('${directory.path}/album-images-v2/$oldKey.jpg');
    await oldCache.parent.create(recursive: true);
    await oldCache.writeAsBytes(jpeg);
    await File('${oldCache.path}.json').writeAsString(
      jsonEncode({'version': 2, 'thumbnailWidth': 80, 'thumbnailHeight': 40}),
    );
    AlbumImageService service() => AlbumImageService(
      cacheDirectory: directory.path,
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    final first = service();
    final second = service();
    try {
      final result = await first.load(entry).future;
      expect(result.error, isNull);
      expect(result.path, isNot(oldCache.path));
      expect(result.orientation, 6);
      expect((result.width, result.height), (40, 80));
      expect(result.metadata?.width, isNull);
      expect(result.metadata?.height, isNull);
      final pixels = images.decodeJpg(await File(result.path!).readAsBytes())!;
      expect((pixels.width, pixels.height), (40, 80));
      expect(pixels.exif.imageIfd.orientation, isNull);
      await file
          .delete(); // A fresh service must reuse the corrected disk cache.
      final cached = await second.load(entry).future;
      expect(cached.path, result.path);
      expect(cached.orientation, 6);
      expect((cached.width, cached.height), (40, 80));
    } finally {
      first.dispose();
      second.dispose();
      await directory.delete(recursive: true);
    }
  });

  test(
    'capture date preserves unknown offsets and rejects normalized bad dates',
    () {
      expect(parseAlbumCaptureTime('2026:11:04 20:30:00', '+08:00'), (
        DateTime.utc(2026, 11, 4, 12, 30).millisecondsSinceEpoch,
        480,
      ));
      expect(parseAlbumCaptureTime('2026:11:04 20:30:00', null)?.$2, isNull);
      expect(parseAlbumCaptureTime('2026:02:31 20:30:00', '+08:00'), isNull);
    },
  );

  test('metadata sidecar retains EXIF and original oriented dimensions across cache hits', () async {
    final root = await Directory.systemTemp.createTemp('album-metadata-');
    final original = images.Image(width: 120, height: 80);
    original.exif.imageIfd.orientation = 6;
    original.exif.imageIfd['Make'] = 'Example camera';
    original.exif.imageIfd['Model'] = 'Model 123';
    original.exif.exifIfd['LensModel'] = 'Example 35mm';
    original.exif.exifIfd['ExposureTime'] = [1, 250];
    original.exif.exifIfd['DateTimeOriginal'] = '2026:11:04 20:30:00';
    original.exif.exifIfd['OffsetTimeOriginal'] = '+08:00';
    final file = await File('${root.path}/001.jpg')
        .writeAsBytes(images.encodeJpg(original));
    final stat = await file.stat();
    final entry = SourceEntry(
      name: '001.jpg',
      path: file.path,
      size: stat.size,
      modified: stat.modified.millisecondsSinceEpoch,
    );
    AlbumImageService service() => AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    final first = service();
    try {
      final result = await first.loadMetadata(entry).future;
      expect(result.error, isNull);
      expect(result.path, isNull);
      expect(result.metadata?.width, 80);
      expect(result.metadata?.height, 120);
      expect(
        result.capturedAt,
        DateTime.utc(2026, 11, 4, 12, 30).millisecondsSinceEpoch,
      );
      expect(result.orientation, 6);
      expect(result.captureOffsetMinutes, 480);
      expect(result.exif['相机厂商'], 'Example camera');
      expect(result.exif['相机型号'], 'Model 123');
      expect(result.exif['镜头型号'], 'Example 35mm');
      expect(result.exif['曝光时间'], contains('250'));
      expect(() => result.exif['x'] = 'y', throwsUnsupportedError);
      final thumbnail = await first.load(entry, targetEdge: 64).future;
      expect(thumbnail.path, isNotNull);
      final second = service();
      try {
        final cached = await second.load(entry, targetEdge: 64).future;
        expect(cached.path, thumbnail.path);
        expect(cached.metadata?.width, 80);
        expect(cached.metadata?.height, 120);
        expect(cached.captureTimeRaw, '2026:11:04 20:30:00');
        expect(cached.exif, thumbnail.exif);
        expect(first.peek(entry)?.path, thumbnail.path);
        expect(
          first.peek(
            SourceEntry(
              name: entry.name,
              path: entry.path,
              size: entry.size,
              modified: entry.modified + 1,
            ),
          ),
          isNull,
        );
        final replacement = images.Image(width: 20, height: 30);
        await file.writeAsBytes(images.encodeJpg(replacement));
        final newer = await file.stat();
        final changed = await second
            .load(
              SourceEntry(
                name: '001.jpg',
                path: file.path,
                size: newer.size,
                modified: newer.modified.millisecondsSinceEpoch,
              ),
              targetEdge: 64,
            )
            .future;
        expect(changed.path, isNot(cached.path));
        expect(changed.metadata?.width, 20);
        expect(changed.metadata?.height, 30);
      } finally {
        second.dispose();
      }
    } finally {
      first.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  for (final preferOriginal in [false, true]) {
    test(
      'v2 cached ${preferOriginal ? 'original' : 'thumbnail'} still paints immediately and refreshes missing EXIF on demand',
      () async {
        final root = await Directory.systemTemp.createTemp('album-old-exif-');
        final original = images.Image(width: 40, height: 30);
        original.exif.imageIfd['Make'] = 'Old cache camera';
        original.exif.exifIfd['DateTimeOriginal'] = '2026:09:01 10:00:00';
        final bytes = images.encodeJpg(original);
        final source = await File('${root.path}/photo.jpg').writeAsBytes(bytes);
        final entry = SourceEntry(
          name: 'photo.jpg',
          path: source.path,
          size: bytes.length,
          modified: 1,
        );
        AlbumImageService service() => AlbumImageService(
          cacheDirectory: '${root.path}/cache',
          sourceId: 'local',
          source: const {'kind': 'local'},
          observeLifecycle: false,
          preferOriginal: preferOriginal,
        );
        final first = service();
        String? thumbnailPath;
        try {
          thumbnailPath = (await first.load(entry, targetEdge: 64).future).path;
          expect(thumbnailPath, isNotNull);
        } finally {
          first.dispose();
        }
        final sidecar = File('$thumbnailPath.json');
        final json = jsonDecode(await sidecar.readAsString()) as Map;
        json['version'] = 2;
        json.remove('exif');
        await sidecar.writeAsString(jsonEncode(json));
        await Directory('${root.path}/cache/album-metadata-v3')
            .delete(recursive: true);
        final second = service();
        try {
          final old = await second.load(entry, targetEdge: 64).future;
          expect(old.path, thumbnailPath);
          expect(old.exif, isEmpty);
          expect(old.metadataVersion, 2);
          final refreshed = await second.loadMetadata(entry).future;
          expect(refreshed.exif['相机厂商'], 'Old cache camera');
          expect(refreshed.metadataVersion, 3);
          expect(refreshed.capturedAt, isNotNull);
        } finally {
          second.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await root.delete(recursive: true);
        }
      },
    );
  }

  test('folder worker nominates only a sole visible video and preserves photo priority', () async {
    final root = await Directory.systemTemp.createTemp('album-video-cover-');
    final media = await Directory('${root.path}/media').create();
    final video = await File('${media.path}/clip.mp4').writeAsBytes([1, 2, 3]);
    await File('${media.path}/.hidden.mov').writeAsBytes([4, 5]);
    final service = AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    final folder = SourceEntry(
      name: 'media',
      path: media.path,
      directory: true,
    );
    try {
      final onlyVideo = await service.load(folder).future;
      expect(onlyVideo.path, isNull);
      expect(onlyVideo.singleVideo?.path, video.path);
      expect(onlyVideo.singleVideo?.size, 3);
      final photo = await File('${media.path}/photo.jpg')
          .writeAsBytes(images.encodeJpg(images.Image(width: 40, height: 20)));
      service.invalidate();
      final mixed = await service.load(folder).future;
      expect(mixed.sourcePath, photo.path);
      expect(mixed.singleVideo?.path, video.path);
      final imagesOnly = await service
          .load(folder, extensions: {'.jpg'})
          .future;
      expect(imagesOnly.singleVideo, isNull);
      final excluded = await service
          .load(folder, excludedExtensions: {'.mp4'})
          .future;
      expect(excluded.singleVideo, isNull);
      final hiddenShown = await service.load(folder, hideHidden: false).future;
      expect(hiddenShown.singleVideo, isNull);
      await File('${media.path}/second.mkv').writeAsBytes([6]);
      service.invalidate();
      expect((await service.load(folder).future).singleVideo, isNull);
      await File('${media.path}/second.mkv').delete();
      await photo.delete();
      service.invalidate();
      expect((await service.load(folder).future).singleVideo?.path, video.path);
    } finally {
      service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test('saved folder cover validates current file and respects exact extension filters', () async {
    final root = await Directory.systemTemp.createTemp('album-cover-');
    final media = await Directory('${root.path}/media').create();
    final first = await File('${media.path}/a.jpg')
        .writeAsBytes(images.encodeJpg(images.Image(width: 40, height: 20)));
    final chosen = await File('${media.path}/z.png')
        .writeAsBytes(images.encodePng(images.Image(width: 30, height: 50)));
    final prefs = File(albumSettingsPath(root.path, 'local', media.path));
    await prefs.parent.create(recursive: true);
    await prefs.writeAsString(
      jsonEncode({
        'cover': {
          'name': 'z.png',
          'path': chosen.path,
          'size': 1,
          'modified': 1,
        },
      }),
    );
    final service = AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      documentsPath: root.path,
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    final folder = SourceEntry(
      name: 'media',
      path: media.path,
      directory: true,
    );
    try {
      final selected = await service.load(folder).future;
      expect(selected.sourcePath, chosen.path);
      expect(selected.sourceWidth, 30);
      final filtered = await service.load(folder, extensions: {'.jpg'}).future;
      expect(filtered.sourcePath, first.path);
      expect(filtered.sourceWidth, 40);
      final invalid = await service.load(folder, extensions: {'.arw'}).future;
      expect(invalid.path, isNull);
    } finally {
      service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test('hidden folder covers persist, invalidate cached images and video fallbacks, and stay isolated', () async {
    final root = await Directory.systemTemp.createTemp('album-hidden-cover-');
    final media = await Directory('${root.path}/media').create();
    final videos = await Directory('${root.path}/videos').create();
    final other = await Directory('${root.path}/other').create();
    final jpeg = images.encodeJpg(images.Image(width: 40, height: 20));
    final first = await File('${media.path}/a.jpg').writeAsBytes(jpeg);
    final chosen = await File('${media.path}/z.jpg').writeAsBytes(jpeg);
    final unrelated = await File('${other.path}/photo.jpg').writeAsBytes(jpeg);
    final video = await File('${videos.path}/clip.mp4').writeAsBytes([1, 2, 3]);
    SourceEntry folder(Directory directory) => SourceEntry(
      name: directory.path.split('/').last,
      path: directory.path,
      directory: true,
    );
    Future<void> save(Directory directory, Map<String, dynamic> value) async {
      final file = File(albumSettingsPath(root.path, 'local', directory.path));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(value));
    }

    AlbumImageService createService() => AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      documentsPath: root.path,
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    final service = createService();
    AlbumImageService? reopened;
    final selection = {'name': 'z.jpg', 'path': chosen.path};
    void expectHidden(AlbumImageResult result) {
      expect(result.path, isNull);
      expect(result.sourcePath, isNull);
      expect(result.singleVideo, isNull);
      expect(result.error, isNull);
    }

    try {
      await save(media, {'cover': selection});
      expect(
        (await service.load(folder(media)).future).sourcePath,
        chosen.path,
      );
      expect(
        (await service.load(folder(videos)).future).singleVideo?.path,
        video.path,
      );
      expect(
        (await service.load(folder(other)).future).sourcePath,
        unrelated.path,
      );

      await save(media, {'cover': selection, 'hideCover': true});
      await save(videos, {'hideCover': true});
      service.invalidate();
      expect(service.peekPrepared(folder(media)), isNull);
      expectHidden(await service.load(folder(media)).future);
      expectHidden(await service.load(folder(videos)).future);
      expectHidden(service.peekPrepared(folder(media))!);
      expectHidden(
        await service
            .load(
              folder(media),
              cover: SourceEntry(name: 'z.jpg', path: chosen.path),
            )
            .future,
      );
      expect(
        (await service.load(folder(other)).future).sourcePath,
        unrelated.path,
      );

      reopened = createService();
      expectHidden(await reopened.load(folder(media)).future);
      expectHidden(await reopened.load(folder(videos)).future);
      reopened.dispose();
      reopened = null;

      await save(media, {});
      await save(videos, {});
      service.invalidate();
      expect((await service.load(folder(media)).future).sourcePath, first.path);
      expect(
        (await service.load(folder(videos)).future).singleVideo?.path,
        video.path,
      );
      await save(media, {'cover': selection, 'hideCover': false});
      service.invalidate();
      expect(
        (await service.load(folder(media)).future).sourcePath,
        chosen.path,
      );
      expect(await first.exists(), isTrue);
      expect(await chosen.exists(), isTrue);
    } finally {
      service.dispose();
      reopened?.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test('hidden folder covers do not open or inspect a remote source', () async {
    final root = await Directory.systemTemp.createTemp('album-hidden-remote-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.method);
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    final file = File(albumSettingsPath(root.path, 'remote', '/photos/'));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'hideCover': true}));
    final service = AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      documentsPath: root.path,
      sourceId: 'remote',
      source: {'kind': 'webdav', 'url': 'http://127.0.0.1:${server.port}/'},
      observeLifecycle: false,
    );
    const folder = SourceEntry(
      name: 'photos',
      path: '/photos/',
      directory: true,
    );
    const cover = SourceEntry(name: 'chosen.jpg', path: '/photos/chosen.jpg');
    try {
      for (final explicit in [false, true]) {
        final result = await service
            .load(folder, cover: explicit ? cover : null)
            .future;
        expect(result.path, isNull);
        expect(result.singleVideo, isNull);
        expect(result.error, isNull);
      }
      expect(requests, isEmpty);

      await file.writeAsString('{}');
      service.invalidate();
      await service.load(folder, cover: cover).future;
      expect(requests, isNotEmpty);
    } finally {
      service.dispose();
      await server.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test(
    'worker lists, reads, caches, filters folder covers and marks RAW previews',
    () async {
      final root = await Directory.systemTemp.createTemp('album-worker-');
      final media = await Directory('${root.path}/media').create();
      final jpeg = images.encodeJpg(images.Image(width: 80, height: 40));
      final photo = await File('${media.path}/001.jpg').writeAsBytes(jpeg);
      final raw = await File('${media.path}/001.arw')
          .writeAsBytes([1, 2, 3, ...jpeg]);
      await File('${media.path}/different.jpeg').writeAsBytes(jpeg);
      final service = AlbumImageService(
        cacheDirectory: '${root.path}/cache',
        sourceId: 'local',
        source: const {'kind': 'local'},
        observeLifecycle: false,
      );
      try {
        final listing = await service.listDirectory(media.path);
        expect(listing.map((e) => e.name), containsAll(['001.jpg', '001.arw']));
        final jpgEntry = listing.singleWhere((e) => e.path == photo.path);
        final first = await service.load(jpgEntry, targetEdge: 64).future;
        expect(first.error, isNull);
        expect(first.path, isNotNull);
        expect(await File(first.path!).exists(), isTrue);
        final cached = await service.load(jpgEntry, targetEdge: 64).future;
        expect(cached.path, first.path);
        final folder = await service
            .load(
              SourceEntry(name: 'media', path: media.path, directory: true),
              targetEdge: 64,
              extensions: {'.jpg'},
            )
            .future;
        expect(folder.path, first.path);
        final directoryEntry = SourceEntry(
          name: 'media',
          path: media.path,
          directory: true,
        );
        expect(
          service
              .peekPrepared(
                directoryEntry,
                targetEdge: 64,
                extensions: {'.jpg'},
              )
              ?.path,
          first.path,
        );
        expect(
          service.peekPrepared(
            directoryEntry,
            targetEdge: 64,
            extensions: {'.arw'},
          ),
          isNull,
          reason: 'Folder covers must not bypass the active filters.',
        );
        final rawResult = await service
            .load(listing.singleWhere((e) => e.path == raw.path))
            .future;
        expect(rawResult.previewOnly, isTrue);
        expect(rawResult.path, isNotNull);
        final excluded = await service
            .load(
              SourceEntry(name: 'media', path: media.path, directory: true),
              extensions: {'.jpg'},
              excludedExtensions: {'.jpg'},
            )
            .future;
        expect(excluded.path, isNull);
        expect(excluded.error, isNull);
        service.invalidate();
        expect(service.peek(jpgEntry), isNull);
        expect(
          service.peekPrepared(
            directoryEntry,
            targetEdge: 64,
            extensions: {'.jpg'},
          ),
          isNull,
        );
      } finally {
        service.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'bounded admission, consumer cancellation and pause prevent new jobs',
    () async {
      final root = await Directory.systemTemp.createTemp('album-bounds-');
      final service = AlbumImageService(
        cacheDirectory: root.path,
        sourceId: 'local',
        source: const {'kind': 'local'},
        observeLifecycle: false,
      );
      service.setActive(false);
      final handles = List.generate(
        64,
        (i) => service.load(SourceEntry(name: '$i.jpg', path: '/$i.jpg')),
      );
      expect(service.pendingCount, 64);
      expect(service.activeCount, 0);
      final refused = await service
          .load(const SourceEntry(name: '65.jpg', path: '/65.jpg'))
          .future;
      expect(refused.deferred, isTrue);
      handles.first.cancel();
      expect((await handles.first.future).cancelled, isTrue);
      expect(service.pendingCount, 63);
      service.dispose();
      expect((await handles.last.future).cancelled, isTrue);
      await root.delete(recursive: true);
    },
  );

  test(
    'disk eviction removes stale resolved paths and regenerates on demand',
    () async {
      final root = await Directory.systemTemp.createTemp('album-eviction-');
      final bytes = images.encodeJpg(images.Image(width: 40, height: 30));
      final a = await File('${root.path}/a.jpg').writeAsBytes(bytes);
      final b = await File('${root.path}/b.jpg').writeAsBytes(bytes);
      final service = AlbumImageService(
        cacheDirectory: '${root.path}/cache',
        sourceId: 'local',
        source: const {'kind': 'local'},
        observeLifecycle: false,
        maxCacheFiles: 2,
        maxThumbnailFiles: 2,
      );
      final entries = await service.listDirectory(root.path);
      final entryA = entries.singleWhere((entry) => entry.path == a.path);
      final entryB = entries.singleWhere((entry) => entry.path == b.path);
      try {
        final first = await service.load(entryA).future;
        await service.load(entryB).future;
        expect(await File(first.path!).exists(), isFalse);
        expect(service.wasEvicted(first.path!), isTrue);
        final reloaded = await service.load(entryA).future;
        expect(reloaded.path, first.path);
        expect(await File(reloaded.path!).exists(), isTrue);
        expect(service.wasEvicted(reloaded.path!), isFalse);
      } finally {
        service.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'bounded metadata cache never evicts the already prepared photo JPEG',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'album-metadata-budget-',
      );
      final bytes = images.encodeJpg(images.Image(width: 40, height: 30));
      final files = await Future.wait(
        List.generate(
          40,
          (i) => File('${root.path}/$i.jpg').writeAsBytes(bytes),
        ),
      );
      final service = AlbumImageService(
        cacheDirectory: '${root.path}/cache',
        sourceId: 'local',
        source: const {'kind': 'local'},
        observeLifecycle: false,
        maxCacheFiles: 2,
      );
      SourceEntry entry(int index) => SourceEntry(
        name: '$index.jpg',
        path: files[index].path,
        size: bytes.length,
        modified: 1,
      );
      try {
        final thumbnail = await service.load(entry(0), targetEdge: 64).future;
        expect(thumbnail.path, isNotNull);
        for (var i = 1; i < files.length; i++) {
          expect((await service.loadMetadata(entry(i)).future).error, isNull);
        }
        expect(await File(thumbnail.path!).exists(), isTrue);
        expect(service.wasEvicted(thumbnail.path!), isFalse);
        expect(
          await Directory('${root.path}/cache/album-metadata-v3').list().length,
          lessThanOrEqualTo(100000),
        );
      } finally {
        service.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await root.delete(recursive: true);
      }
    },
  );

  test('concurrent worker cache writes are atomic and disposal completes pending consumers', () async {
    final root = await Directory.systemTemp.createTemp('album-concurrent-');
    final file = await File('${root.path}/a.jpg')
        .writeAsBytes(images.encodeJpg(images.Image(width: 600, height: 400)));
    final stat = await file.stat();
    final entry = SourceEntry(
      name: 'a.jpg',
      path: file.path,
      size: stat.size,
      modified: stat.modified.millisecondsSinceEpoch,
    );
    AlbumImageService create() => AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      observeLifecycle: false,
    );
    final a = create(), b = create();
    try {
      final results = await Future.wait([
        a.load(entry).future,
        b.load(entry).future,
      ]);
      expect(results.map((e) => e.error), everyElement(isNull));
      expect(results.first.path, results.last.path);
      expect(
        images.decodeJpg(await File(results.first.path!).readAsBytes()),
        isNotNull,
      );
      b.setActive(false);
      // A size change is already satisfied by the shared encoded source. A
      // new file revision still queues real work, which disposal must cancel.
      final waiting = b.load(
        SourceEntry(
          name: entry.name,
          path: entry.path,
          size: entry.size,
          modified: entry.modified + 1,
        ),
      );
      b.dispose();
      expect((await waiting.future).cancelled, isTrue);
      expect((await b.load(entry).future).cancelled, isTrue);
      b.setActive(true);
      b.invalidate();
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await root.delete(recursive: true);
    }
  });

  test('overlapping cache publishers isolate staging and expose only complete commits', () async {
    final directory = await Directory.systemTemp.createTemp('album-atomic-');
    final target = File('${directory.path}/shared.jpg');
    final original = images.encodeJpg(images.Image(width: 40, height: 20));
    final replacement = images.encodeJpg(images.Image(width: 80, height: 60));
    await target.writeAsBytes(original);
    const writers = 8;
    var staged = 0;
    final allStaged = Completer<void>();
    final commit = Completer<void>();
    final work = [
      for (var index = 0; index < writers; index++)
        publishAlbumCacheFile(
          target,
          replacement,
          CancelToken(),
          beforeCommit: () async {
            if (++staged == writers) allStaged.complete();
            await commit.future;
          },
        ),
    ];
    try {
      await allStaged.future.timeout(const Duration(seconds: 5));
      final temporary = await directory
          .list()
          .where((entity) => entity is Directory)
          .toList();
      expect(temporary, hasLength(writers));
      expect(
        temporary.map((entity) => entity.path).toSet(),
        hasLength(writers),
      );
      expect(await target.readAsBytes(), original);
      commit.complete();
      await Future.wait(work);
      expect(await target.readAsBytes(), replacement);
      final decoded = images.decodeJpg(await target.readAsBytes())!;
      expect((decoded.width, decoded.height), (80, 60));
      expect(await directory.list().toList(), hasLength(1));

      final cancel = CancelToken();
      await expectLater(
        publishAlbumCacheFile(
          target,
          original,
          cancel,
          beforeCommit: () async => cancel.cancel(),
        ),
        throwsA(isA<Cancelled>()),
      );
      expect(await target.readAsBytes(), replacement);
      expect(await directory.list().toList(), hasLength(1));
    } finally {
      if (!commit.isCompleted) commit.complete();
      try {
        await Future.wait(work);
      } finally {
        await directory.delete(recursive: true);
      }
    }
  });

  testWidgets(
    'paused without another frame cancels transfer, stops queue, and resumes demands',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('album-lifecycle-');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final bytes = images.encodePng(images.Image(width: 60, height: 40));
        final firstStarted = Completer<void>();
        final releaseFirst = Completer<void>();
        var requests = 0;
        server.listen((request) async {
          requests++;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            'content-range',
            'bytes 0-${bytes.length - 1}/${bytes.length}',
          );
          request.response.contentLength = bytes.length;
          try {
            if (requests == 1) {
              request.response.add(bytes.sublist(0, 1));
              await request.response.flush();
              firstStarted.complete();
              await releaseFirst.future;
              request.response.add(bytes.sublist(1));
            } else {
              request.response.add(bytes);
            }
            await request.response.close();
          } catch (_) {}
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final service = AlbumImageService(
          cacheDirectory: root.path,
          sourceId: 'http',
          maxConcurrentRequests: 1,
          source: {'kind': 'http', 'url': 'http://127.0.0.1:${server.port}/'},
        );
        final first = service.load(
          SourceEntry(
            name: 'first.png',
            path: '/first.png',
            size: bytes.length,
          ),
        );
        final second = service.load(
          SourceEntry(
            name: 'second.png',
            path: '/second.png',
            size: bytes.length,
          ),
        );
        try {
          await firstStarted.future.timeout(const Duration(seconds: 10));
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          // Deliberately no pump: lifecycle must cancel directly.
          await _until(() => service.activeCount == 0);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(requests, 1);
          expect(service.pendingCount, 2);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          releaseFirst.complete();
          expect((await first.future).path, isNotNull);
          expect((await second.future).path, isNotNull);
          expect(requests, 3);
        } finally {
          if (!releaseFirst.isCompleted) releaseFirst.complete();
          service.dispose();
          await server.close(force: true);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await root.delete(recursive: true);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      });
    },
  );
}
