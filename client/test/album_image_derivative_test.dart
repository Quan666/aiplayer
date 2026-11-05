import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('The independent derivative worker did not settle.');
}

class _Fixture {
  final Directory root;
  final List<SourceEntry> entries;
  final services = <AlbumImageService>[];
  _Fixture(this.root, this.entries);

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('album-derivative-');
    final bytes = await Isolate.run(() {
      final pixels = images.Image(width: 2560, height: 1920);
      var random = 31;
      for (final pixel in pixels) {
        random = (random * 1664525 + 1013904223) & 0xffffffff;
        pixel.setRgb(
          (random >> 24) & 255,
          (random >> 16) & 255,
          (random >> 8) & 255,
        );
      }
      return images.encodeJpg(pixels, quality: 80);
    });
    final entries = <SourceEntry>[];
    for (var i = 0; i < 3; i++) {
      final file = await File('${root.path}/$i.jpg').writeAsBytes(bytes);
      entries.add(
        SourceEntry(
          name: '$i.jpg',
          path: file.path,
          size: bytes.length,
          modified: 1,
        ),
      );
    }
    return _Fixture(root, entries);
  }

  AlbumImageService service({int thumbnailFiles = 100000}) {
    final value = AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      maxThumbnailFiles: thumbnailFiles,
    );
    services.add(value);
    return value;
  }

  Future<int> thumbnailCount() async {
    final folder = Directory('${root.path}/cache/album-thumbnails-v1');
    if (!await folder.exists()) return 0;
    return folder.list().where((entry) => entry.path.endsWith('.jpg')).length;
  }

  Future<void> close() async {
    for (final service in services) {
      service.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await root.delete(recursive: true);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  tearDown(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  test('JPEG paints its compressed source before an idle durable derivative silently replaces future lookups', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service();
    final entry = fixture.entries.first;
    final initial = await service.load(entry).future;
    expect(initial.error, isNull);
    expect(initial.encodedSource, isTrue);
    expect(initial.width, 2560);
    expect(service.derivativePendingCount, 1);
    expect(service.derivativeActiveCount, 0);
    var changes = 0;
    service.addListener(() => changes++);
    await _until(() => service.derivativePendingCount == 0);
    final durable = service.peekPrepared(entry)!;
    expect(durable.encodedSource, isFalse);
    expect(durable.width, 512);
    expect(durable.path, isNot(initial.path));
    expect(durable.decodedFallbackPath, initial.path);
    expect(service.peek(entry), same(durable));
    expect(
      changes,
      0,
      reason: 'A mounted resident frame must not be replaced.',
    );
    await File(entry.path).delete();
    final reopened = await fixture.service().load(entry).future;
    expect(reopened.error, isNull);
    expect(reopened.path, durable.path);
    expect(reopened.decodedFallbackPath, initial.path);
  });

  test('new visible source requests preempt derivative CPU work and background cancels without any frame', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final service = fixture.service();
    await service.load(fixture.entries[0]).future;
    await _until(() => service.derivativeActiveCount == 1);
    final next = await service.load(fixture.entries[1]).future;
    expect(next.error, isNull);
    expect(next.encodedSource, isTrue);
    expect(service.derivativeActiveCount, 0);
    await _until(() => service.derivativeActiveCount == 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _until(() => service.derivativeActiveCount == 0);
    final pending = service.derivativePendingCount;
    final files = await fixture.thumbnailCount();
    expect(pending, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(service.derivativePendingCount, pending);
    expect(service.derivativeActiveCount, 0);
    expect(await fixture.thumbnailCount(), files);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(service.derivativeActiveCount, 0);
    expect(await fixture.thumbnailCount(), files);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _until(() => service.derivativePendingCount == 0);
    expect(service.peek(fixture.entries[0])!.encodedSource, isFalse);
    expect(service.peek(fixture.entries[1])!.encodedSource, isFalse);
  });

  test(
    'disposing during isolated conversion prevents late cache publication',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final service = fixture.service();
      await service.load(fixture.entries[0]).future;
      await _until(() => service.derivativeActiveCount == 1);
      service.dispose();
      final files = await fixture.thumbnailCount();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(await fixture.thumbnailCount(), files);
      expect(service.derivativePendingCount, 0);
      expect(service.derivativeActiveCount, 0);
    },
  );
  test('regenerating an evicted derivative revalidates the small path without reviving a stale pointer', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final wall = fixture.service(thumbnailFiles: 2);
    final peer = fixture.service(thumbnailFiles: 2);
    final entry = fixture.entries[0];
    await wall.load(entry).future;
    await _until(() => wall.derivativePendingCount == 0);
    final small = wall.peekPrepared(entry)!;
    await peer.load(fixture.entries[1]).future;
    await _until(() => peer.derivativePendingCount == 0);
    expect(wall.wasEvicted(small.path!), isTrue);
    expect(wall.peek(entry), isNull);
    final quick = await wall.load(entry).future;
    expect(quick.encodedSource, isTrue);
    await _until(() => wall.derivativePendingCount == 0);
    expect(await File(small.path!).exists(), isTrue);
    expect(
      wall.wasEvicted(small.path!),
      isTrue,
      reason: 'A stale completion cannot clear a newer eviction marker.',
    );
    expect(wall.peek(entry), isNull);
    expect(wall.peekPrepared(entry), isNull);
    final checked = await wall.load(entry).future;
    expect(checked.error, isNull);
    expect(checked.path, small.path);
    expect(checked.encodedSource, isFalse);
    expect(wall.wasEvicted(small.path!), isFalse);
  });
}
