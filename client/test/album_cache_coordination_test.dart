import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:sqlite3/sqlite3.dart';

Future<void> _until(Future<bool> Function() ready) async {
  for (var i = 0; i < 200; i++) {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('The cache worker did not settle.');
}

Future<int> _used(String directory, String path) => Isolate.run(() {
  final database = sqlite3.open('$directory/album-cache-v1.sqlite');
  try {
    final rows = database.select('SELECT used FROM entries WHERE path=?', [
      path,
    ]);
    return rows.isEmpty ? -1 : rows.single['used'] as int;
  } finally {
    database.dispose();
  }
});

class _Fixture {
  final Directory root;
  final List<SourceEntry> entries;
  final services = <AlbumImageService>[];
  _Fixture(this.root, this.entries);

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('album-cache-peers-');
    final bytes = images.encodeJpg(images.Image(width: 160, height: 100));
    final entries = <SourceEntry>[];
    for (final name in ['a', 'b', 'c', 'd']) {
      final file = await File('${root.path}/$name.jpg').writeAsBytes(bytes);
      final stat = await file.stat();
      entries.add(
        SourceEntry(
          name: '$name.jpg',
          path: file.path,
          size: stat.size,
          modified: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    return _Fixture(root, entries);
  }

  AlbumImageService service({String cache = 'shared', int thumbnailFiles = 6}) {
    final value = AlbumImageService(
      cacheDirectory: '${root.path}/$cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      maxThumbnailFiles: thumbnailFiles,
    );
    services.add(value);
    return value;
  }

  Future<void> close() async {
    for (final service in services) {
      service.dispose();
    }
    // Worker shutdown closes its independent SQLite and source handles.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await root.delete(recursive: true);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  test(
    'peer eviction invalidates prepared paths once and respects hidden owners',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final wall = fixture.service(thumbnailFiles: 2);
      final viewer = fixture.service(thumbnailFiles: 2);
      final unrelated = fixture.service(cache: 'other');
      final first = await wall.load(fixture.entries[0]).future;
      final independent = await unrelated.load(fixture.entries[0]).future;
      expect(first.path, isNotNull);
      var notifications = 0;
      wall.addListener(() => notifications++);
      wall.setActive(false);
      notifications = 0;
      await viewer.load(fixture.entries[1]).future;
      await _until(() async => wall.wasEvicted(first.path!));

      expect(await File(first.path!).exists(), isFalse);
      expect(wall.peek(fixture.entries[0]), isNull);
      expect(notifications, 0, reason: 'A covered wall must not rebuild.');
      expect(unrelated.peek(fixture.entries[0]), same(independent));
      expect(await File(independent.path!).exists(), isTrue);
      wall.setActive(true);
      expect(
        notifications,
        1,
        reason: 'Resume coalesces hidden invalidations.',
      );
      final restored = await wall.load(fixture.entries[0]).future;
      expect(restored.error, isNull);
      expect(await File(restored.path!).exists(), isTrue);
      expect(wall.wasEvicted(restored.path!), isFalse);
    },
  );

  test(
    'an in-memory preview hit renews disk LRU before another worker trims',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      final wall = fixture.service();
      final peer = fixture.service();
      final a = await wall.load(fixture.entries[0]).future;
      final b = await wall.load(fixture.entries[1]).future;
      final c = await wall.load(fixture.entries[2]).future;
      final previous = await _used(wall.cacheDirectory, a.path!);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(wall.peek(fixture.entries[0]), same(a));
      await _until(
        () async => await _used(wall.cacheDirectory, a.path!) > previous,
      );
      final firstAccess = await _used(wall.cacheDirectory, a.path!);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      wall.peek(fixture.entries[1]);
      await _until(
        () async => await _used(wall.cacheDirectory, b.path!) > firstAccess,
      );
      final otherAccess = await _used(wall.cacheDirectory, b.path!);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      wall.peek(fixture.entries[0]);
      // A second visit within one minute must reach the shared ledger too.
      // A private per-worker throttle lets the peer evict this hot file.
      await _until(
        () async => await _used(wall.cacheDirectory, a.path!) > otherAccess,
      );
      await peer.load(fixture.entries[3]).future;

      expect(
        await File(a.path!).exists(),
        isTrue,
        reason: 'A is now most recently used.',
      );
      expect(await File(b.path!).exists(), isFalse);
      expect(await File(c.path!).exists(), isFalse);
      expect(wall.peek(fixture.entries[0]), same(a));
    },
  );

  test(
    'background without another frame defers cache touches until foreground',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      addTearDown(
        () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      final service = fixture.service();
      final first = await service.load(fixture.entries[0]).future;
      final previous = await _used(service.cacheDirectory, first.path!);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // No pump: platform cache work must respect the event immediately.
      service.peek(fixture.entries[0]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(await _used(service.cacheDirectory, first.path!), previous);
      expect(service.pendingCount, 0);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _until(
        () async => await _used(service.cacheDirectory, first.path!) > previous,
      );
      expect(await File(first.path!).exists(), isTrue);
    },
  );

  test('late cancelled reads cannot restart maintenance while paused', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    final bytes = await File(fixture.entries.first.path).readAsBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final started = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    server.listen((request) async {
      if (request.uri.path == '/slow.jpg') {
        if (!started.isCompleted) started.complete();
        await release.future;
      }
      try {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'content-range',
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        );
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      } catch (_) {
        // A lifecycle pause closes the held network request.
      }
    });
    final service = AlbumImageService(
      cacheDirectory: '${fixture.root.path}/http-cache',
      sourceId: 'http',
      source: {'kind': 'http', 'url': 'http://127.0.0.1:${server.port}/'},
      maxConcurrentRequests: 1,
    );
    fixture.services.add(service);
    SourceEntry entry(String name) => SourceEntry(
      name: '$name.jpg',
      path: '/$name.jpg',
      size: bytes.length,
      modified: 1,
    );
    final paths = <String>[];
    for (var i = 0; i < 10; i++) {
      paths.add((await service.load(entry('$i')).future).path!);
    }
    final slow = service.load(entry('slow'));
    await started.future.timeout(const Duration(seconds: 5));
    // The source lane is occupied, so cleanup must wait for its completion.
    service.updateCacheLimits(thumbnailBytes: 1, originalBytes: 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _until(() async => service.activeCount == 0);
    slow.cancel();
    release.complete();
    // No frames: a late worker completion must not revive optional maintenance.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      await Future.wait(paths.map((path) => File(path).exists())),
      everyElement(isTrue),
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _until(
      () async =>
          !(await Future.wait(paths.map((path) => File(path).exists())))
              .any((value) => value),
    );
    expect(service.pendingCount, 0);
  });
}
