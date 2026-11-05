import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_viewer.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/remote_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

class _Fixture {
  final Directory root;
  final HttpServer server;
  final Map<String, Uint8List> files;
  final reads = <String, int>{};
  final List<SourceEntry> entries;
  final AppStore store;
  late final AppModel model = AppModel(store, root, backgroundWork: false);
  late final source = <String, dynamic>{
    'id': 'http',
    'kind': 'http',
    'url': 'http://127.0.0.1:${server.port}/',
  };
  late final snapshot = AlbumIndex(
    entries,
    sourceId: 'http',
    directory: '/',
  ).filter(AlbumOptions());
  _Fixture(this.root, this.server, this.files, this.entries, this.store);

  static Future<_Fixture> create({int count = 32, bool formats = false}) async {
    final root = await Directory.systemTemp.createTemp('album-viewer-window-');
    final (jpeg, png) = await Isolate.run(() {
      final pixels = raster.Image(width: 800, height: 600);
      raster.fill(pixels, color: raster.ColorRgb8(30, 120, 180));
      final encoded = raster.encodeJpg(pixels);
      return (
        Uint8List(64 * 1024)..setRange(0, encoded.length, encoded),
        Uint8List.fromList(raster.encodePng(pixels)),
      );
    });
    final files = <String, Uint8List>{
      for (var i = 0; i < count; i++)
        '/${i.toString().padLeft(3, '0')}.jpg': jpeg,
      if (formats) '/004.png': png,
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture(root, server, files, [
      for (final file in files.entries)
        SourceEntry(
          name: file.key.substring(1),
          path: file.key,
          size: file.value.length,
          modified: 1,
        ),
    ], AppStore(':memory:'));
    server.listen((request) async {
      fixture.reads.update(
        request.uri.path,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      final bytes = files[request.uri.path];
      try {
        if (bytes == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          final range = RegExp(r'bytes=(\d+)-(\d*)')
              .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
          final start = int.tryParse(range?.group(1) ?? '') ?? 0;
          final requestedEnd = int.tryParse(range?.group(2) ?? '');
          final end = (requestedEnd ?? bytes.length - 1).clamp(
            start,
            bytes.length - 1,
          );
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
          request.response.contentLength = end - start + 1;
          request.response.add(Uint8List.sublistView(bytes, start, end + 1));
        }
        await request.response.close();
      } catch (_) {
        // A route/lifecycle change may cancel an otherwise valid read.
      }
    });
    return fixture;
  }

  String get cacheDirectory => '${root.path}/album-images-v1';
  int get readCount => reads.values.fold(0, (total, count) => total + count);

  Future<int> originalCount() async {
    final originals = Directory('$cacheDirectory/album-images-v2');
    if (!await originals.exists()) return 0;
    return originals.list().where((file) => file.path.endsWith('.jpg')).length;
  }

  Future<int> retainedOriginalCount() async {
    var count = await originalCount();
    for (var i = 0; i < 300 && count > 13; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      count = await originalCount();
    }
    return count;
  }

  Future<void> close() async {
    model.dispose();
    await model.flushMetadataTasks();
    store.dispose();
    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await root.delete(recursive: true);
  }
}

Finder get _current => find.descendant(
  of: find.byKey(const ValueKey('album-current-page')),
  matching: find.byType(AlbumThumbnail),
);

AlbumThumbnail _photo(WidgetTester tester) => tester.widget(_current);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  final queue = ArtworkDecodeQueue.instance;
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (_current.evaluate().isNotEmpty &&
        _photo(tester).service.pendingCount == 0 &&
        queue.activeCount == 0 &&
        queue.pendingCount == 0 &&
        !tester.binding.hasScheduledFrame) {
      expect(
        tester
            .widgetList<RawImage>(
              find.descendant(of: _current, matching: find.byType(RawImage)),
            )
            .any((image) => image.image != null),
        isTrue,
        reason: 'A prepared source alone is not a decoded visible page.',
      );
      expect(tester.takeException(), isNull);
      return;
    }
  }
  fail('The viewer did not finish its bounded source/decode work.');
}

Future<void> _advance(WidgetTester tester, int direction) async {
  await tester
      .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
      .onCommand(
        RemoteCommand(
          1,
          direction > 0 ? 'next' : 'previous',
          null,
          null,
          null,
          () => true,
        ),
      );
  await _settle(tester);
}

Future<void> _mount(
  WidgetTester tester,
  _Fixture fixture, {
  int initialIndex = 0,
  Key? viewerKey,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AlbumViewer(
        key: viewerKey,
        model: fixture.model,
        source: fixture.source,
        password: '',
        snapshot: fixture.snapshot,
        initialIndex: initialIndex,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 100));
  final queue = ArtworkDecodeQueue.instance;
  for (var attempt = 0; attempt < 100 && queue.activeCount > 0; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets(
    'long browsing keeps nearby originals and a bounded tail while durable wall images survive',
    (tester) async {
      final fixture = (await tester.runAsync(_Fixture.create))!;
      final wall = AlbumImageService(
        cacheDirectory: fixture.cacheDirectory,
        sourceId: 'http',
        source: fixture.source,
      );
      try {
        final small = (await tester.runAsync(() async {
          await wall.load(fixture.entries.first).future;
          for (var i = 0; i < 300 && wall.derivativePendingCount > 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(wall.derivativePendingCount, 0);
          return wall.peekPrepared(fixture.entries.first)!;
        }))!;
        expect(small.encodedSource, isFalse);
        wall.setActive(false);
        await _mount(tester, fixture);
        final viewer = _photo(tester).service;
        expect(viewer.originalWindowPaths, [
          '/000.jpg',
          '/001.jpg',
          '/002.jpg',
        ]);
        final initial = viewer.peek(fixture.entries.first)!;
        for (var index = 1; index <= 28; index++) {
          await _advance(tester, 1);
          expect(_photo(tester).entry, fixture.entries[index]);
          expect(viewer.pendingCount, 0);
          expect(viewer.originalWindowPaths, [
            '/${index.toString().padLeft(3, '0')}.jpg',
            '/${(index + 1).toString().padLeft(3, '0')}.jpg',
            '/${(index - 1).toString().padLeft(3, '0')}.jpg',
            '/${(index + 2).toString().padLeft(3, '0')}.jpg',
            if (index > 1) '/${(index - 2).toString().padLeft(3, '0')}.jpg',
          ]);
        }
        // The disk policy has five protected neighbors and at most eight older
        // originals. Historical photo count must not become the disk footprint.
        final count = await tester.runAsync(fixture.retainedOriginalCount);
        expect(count, lessThanOrEqualTo(13));
        expect(
          await tester.runAsync(() => File(initial.path!).exists()),
          isFalse,
        );
        expect(await tester.runAsync(() => File(small.path!).exists()), isTrue);

        final beforeReverse = fixture.readCount;
        await _advance(tester, -1);
        expect(viewer.originalWindowPaths, [
          '/027.jpg',
          '/026.jpg',
          '/028.jpg',
          '/025.jpg',
          '/029.jpg',
        ]);
        await _advance(tester, 1);
        expect(
          fixture.readCount,
          beforeReverse,
          reason: 'A short direction reversal stays in the nearby window.',
        );

        // A distant revisit is allowed to reread its original; its small wall
        // image is independent and remains a no-network hit.
        final firstReads = fixture.reads['/000.jpg'];
        await _mount(
          tester,
          fixture,
          viewerKey: const ValueKey('distant-return'),
        );
        expect(viewer.active, isFalse);
        expect(viewer.pendingCount, 0);
        expect(_photo(tester).service.originalWindowPaths, [
          '/000.jpg',
          '/001.jpg',
          '/002.jpg',
        ]);
        expect(
          await tester.runAsync(fixture.retainedOriginalCount),
          lessThanOrEqualTo(13),
        );
        expect(fixture.reads['/000.jpg'], greaterThan(firstReads!));
        wall.setActive(true);
        final beforeWall = fixture.readCount;
        final restored = await tester.runAsync(
          () => wall.load(fixture.entries.first).future,
        );
        expect(restored!.path, small.path);
        expect(restored.encodedSource, isFalse);
        expect(fixture.readCount, beforeWall);
      } finally {
        await _unmount(tester);
        wall.dispose();
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'format changes and lifecycle pauses keep only the current bounded viewer work',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _Fixture.create(count: 10, formats: true),
      ))!;
      try {
        await _mount(tester, fixture, initialIndex: 4);
        final viewer = _photo(tester).service;
        expect(_photo(tester).entry.path, '/004.jpg');
        expect(viewer.originalWindowPaths, [
          '/004.jpg',
          '/005.jpg',
          '/003.jpg',
          '/006.jpg',
          '/002.jpg',
        ]);
        expect(
          fixture.reads.keys,
          unorderedEquals(['/003.jpg', '/004.jpg', '/005.jpg']),
        );
        await tester.tap(find.byTooltip('选择格式'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<int>, '004.png'),
        );
        await _settle(tester);
        expect(_photo(tester).entry.path, '/004.png');
        expect(viewer.originalWindowPaths, [
          '/004.png',
          '/005.jpg',
          '/003.jpg',
          '/006.jpg',
          '/002.jpg',
        ]);
        expect(viewer.peek(_photo(tester).entry)?.error, isNull);
        expect(
          fixture.reads.keys,
          unorderedEquals(['/003.jpg', '/004.jpg', '/005.jpg', '/004.png']),
        );

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        final beforePause = fixture.readCount;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 650)),
        );
        // Deliberately no pump after hidden/paused.
        expect(viewer.active, isFalse);
        expect(viewer.activeCount, 0);
        expect(viewer.pendingCount, 0);
        expect(fixture.readCount, beforePause);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _settle(tester);
        expect(_photo(tester).entry.path, '/004.png');
        expect(fixture.readCount, beforePause);
        await _advance(tester, -1);
        expect(_photo(tester).entry.path, '/003.jpg');
        expect(viewer.originalWindowPaths, [
          '/003.jpg',
          '/002.jpg',
          '/004.jpg',
          '/001.jpg',
          '/005.jpg',
        ]);
        await _unmount(tester);
        final afterExit = fixture.readCount;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 650)),
        );
        expect(viewer.active, isFalse);
        expect(viewer.activeCount, 0);
        expect(viewer.pendingCount, 0);
        expect(fixture.readCount, afterExit);
      } finally {
        await _unmount(tester);
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'a held swipe reverses its working window before release and can cancel or pause safely',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _Fixture.create(count: 10),
      ))!;
      try {
        await _mount(tester, fixture, initialIndex: 4);
        final viewer = _photo(tester).service;
        expect(viewer.maintenanceHeld, isFalse);
        final canvas = find.byKey(const ValueKey('album-photo-canvas'));
        final gesture = await tester.startGesture(tester.getCenter(canvas));
        await gesture.moveBy(const Offset(-100, 0));
        await tester.pump();
        expect(_photo(tester).entry.path, '/004.jpg');
        expect(viewer.maintenanceHeld, isTrue);
        expect(viewer.originalWindowPaths, [
          '/004.jpg',
          '/005.jpg',
          '/003.jpg',
          '/006.jpg',
          '/002.jpg',
        ]);
        await gesture.moveBy(const Offset(200, 0));
        await tester.pump();
        expect(_photo(tester).entry.path, '/004.jpg');
        expect(viewer.maintenanceHeld, isTrue);
        expect(viewer.originalWindowPaths, [
          '/004.jpg',
          '/003.jpg',
          '/005.jpg',
          '/002.jpg',
          '/006.jpg',
        ]);
        await gesture.cancel();
        expect(
          viewer.maintenanceHeld,
          isTrue,
          reason: 'The cancelled drag still has a snap-back animation.',
        );
        await _settle(tester);
        expect(_photo(tester).entry.path, '/004.jpg');
        expect(viewer.maintenanceHeld, isFalse);
        expect(
          fixture.reads.keys,
          unorderedEquals(['/003.jpg', '/004.jpg', '/005.jpg']),
        );

        final pausedGesture = await tester.startGesture(
          tester.getCenter(canvas),
        );
        await pausedGesture.moveBy(const Offset(-100, 0));
        await tester.pump();
        expect(viewer.maintenanceHeld, isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        final beforePause = fixture.readCount;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        // No frame follows the lifecycle event: the held state must not leave
        // source/decode work running or turn its late gesture into navigation.
        expect(viewer.active, isFalse);
        expect(viewer.maintenanceHeld, isFalse);
        expect(viewer.activeCount, 0);
        expect(viewer.pendingCount, 0);
        expect(fixture.readCount, beforePause);
        await pausedGesture.cancel();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _settle(tester);
        expect(_photo(tester).entry.path, '/004.jpg');
        expect(viewer.maintenanceHeld, isFalse);
        await _advance(tester, 1);
        expect(_photo(tester).entry.path, '/005.jpg');
        expect(viewer.maintenanceHeld, isFalse);
        expect(fixture.reads['/006.jpg'], isNotNull);
      } finally {
        await _unmount(tester);
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'edge pages stop prefetching beyond the album and reset the window on replacement',
    (tester) async {
      final fixture = (await tester.runAsync(() => _Fixture.create(count: 4)))!;
      try {
        await _mount(tester, fixture);
        final first = _photo(tester).service;
        expect(first.originalWindowPaths, ['/000.jpg', '/001.jpg', '/002.jpg']);
        expect(fixture.reads.keys, unorderedEquals(['/000.jpg', '/001.jpg']));
        final beforeEdge = fixture.readCount;
        await _advance(tester, -1);
        expect(_photo(tester).entry.path, '/000.jpg');
        expect(fixture.readCount, beforeEdge);

        await _mount(
          tester,
          fixture,
          initialIndex: 3,
          viewerKey: const ValueKey('last-page'),
        );
        final last = _photo(tester).service;
        expect(last, isNot(same(first)));
        expect(first.active, isFalse);
        expect(first.pendingCount, 0);
        expect(last.originalWindowPaths, ['/003.jpg', '/002.jpg', '/001.jpg']);
        final afterReplacement = fixture.readCount;
        await _advance(tester, 1);
        expect(_photo(tester).entry.path, '/003.jpg');
        expect(fixture.readCount, afterReplacement);
        await _advance(tester, -1);
        expect(last.originalWindowPaths, [
          '/002.jpg',
          '/001.jpg',
          '/003.jpg',
          '/000.jpg',
        ]);
        expect(fixture.readCount, afterReplacement);
      } finally {
        await _unmount(tester);
        await tester.runAsync(fixture.close);
      }
    },
  );
}
