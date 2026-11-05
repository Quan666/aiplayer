import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;
import 'package:integration_test/integration_test.dart';

// From client/, serially with other native builds / Flutter tests:
// dbus-run-session -- xvfb-run -a -s '-screen 0 1600x1000x24' env
// LIBGL_ALWAYS_SOFTWARE=1 flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/album_scroll_return_performance_test.dart
// --dart-define=ALBUM_RETURN_ARTIFACT_DIR=/absolute/artifact/path
// Real AlbumPage, image/catalog workers, native decoding and isolate HTTP.
// Synthetic JPEGs and Linux software rendering do not establish device FPS.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('first recycled album frame and delayed thumbnail persistence', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = await _Fixture.start();
    final store = AppStore.openExisting('${fixture.root}/library.db');
    final model = AppModel(
      store,
      Directory(fixture.root),
      backgroundWork: false,
    );
    final wall = find.byKey(const ValueKey('album-wall'));
    final phases = <Map<String, Object?>>[];
    final report = <String, Object?>{
      'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
      'platform': Platform.operatingSystem,
      'photoGroups': _groups,
      'jpegWidth': 1600,
      'jpegHeight': 1200,
      'scope':
          'Actual AlbumPage with native decoding and production workers; '
          'separate-isolate loopback WebDAV and generated JPEGs. '
          'Linux software rendering does not establish phone/TV FPS, NAS '
          'throughput or battery improvement. Maintenance is deliberately held '
          'during the pressure phase to reproduce a saturated derivative queue.',
      'phases': phases,
    };
    late AlbumImageService service;
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: wall, matching: find.byType(Scrollable)).first,
        )
        .position;
    Future<void> ready(String label) async {
      await _until(() {
        final state = _visible(tester, wall);
        return state.visible > 0 && state.missing == 0;
      }, label);
      await _until(() => service.pendingCount == 0, '$label source queue');
    }

    Future<void> measure(String name, Future<void> Function() action) async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final frames = <ui.FrameTiming>[];
      void collect(List<ui.FrameTiming> values) => frames.addAll(values);
      WidgetsBinding.instance.addTimingsCallback(collect);
      final watch = Stopwatch()..start();
      try {
        await action();
        watch.stop();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      } finally {
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      phases.add({
        'phase': name,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
        'buildUs': [
          for (final frame in frames) frame.buildDuration.inMicroseconds,
        ],
        'rasterUs': [
          for (final frame in frames) frame.rasterDuration.inMicroseconds,
        ],
      });
    }

    try {
      expect(fixture.workerId, isNot(Isolate.current.hashCode));
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: AlbumPage(
            model: model,
            source: fixture.source,
            initialPath: 'album/',
            initialName: 'Return profile',
          ),
        ),
      );
      await _until(
        () => find.byType(AlbumThumbnail).evaluate().isNotEmpty,
        'album thumbnails mounted',
      );
      service = tester
          .widget<AlbumThumbnail>(find.byType(AlbumThumbnail).first)
          .service;
      service.setMaintenanceHeld(true);
      await ready('initial original frames');
      final initial = _visible(tester, wall);
      final firstEntries = tester
          .widgetList<AlbumThumbnail>(find.byType(AlbumThumbnail))
          .map((thumbnail) => (thumbnail.entry, thumbnail.edge))
          .toList(growable: false);
      final initialPaths = {
        for (final item in firstEntries)
          item.$1.path: service
              .peekPrepared(item.$1, targetEdge: item.$2)
              ?.path,
      };
      service.setMaintenanceHeld(false);
      await _until(
        () => service.derivativePendingCount == 0,
        'first durable thumbnails',
      );
      expect(
        firstEntries
            .where(
              (item) =>
                  service
                      .peekPrepared(item.$1, targetEdge: item.$2)
                      ?.encodedSource ==
                  false,
            )
            .length,
        greaterThan(0),
        reason: 'Exercise original-to-derived paths before recycling cells.',
      );
      final replacedPaths = firstEntries.where((item) {
        final before = initialPaths[item.$1.path];
        final after = service.peekPrepared(item.$1, targetEdge: item.$2)?.path;
        return before != null && after != null && before != after;
      }).length;
      expect(replacedPaths, greaterThan(0));
      report['initialPathsReplacedByDerivatives'] = replacedPaths;
      final viewport = position().viewportDimension;
      position().jumpTo(viewport * 2.2);
      await WidgetsBinding.instance.endOfFrame;
      await ready('two pages away');
      await _until(
        () => service.derivativePendingCount == 0,
        'second-page thumbnails',
      );
      final beforeReturn = await fixture.stats();
      await measure('first-return-after-derivative-path-change', () async {
        final watch = Stopwatch()..start();
        position().jumpTo(0);
        await WidgetsBinding.instance.endOfFrame;
        final firstFrame = _visible(tester, wall);
        report['firstReturn'] = {
          'elapsedMs': watch.elapsedMicroseconds / 1000,
          'visible': firstFrame.visible,
          'missing': firstFrame.missing,
          'sourceGetsBefore': beforeReturn['gets'],
        };
        expect(firstFrame.visible, initial.visible);
        expect(
          firstFrame.missing,
          0,
          reason: 'Recycled cells reuse decoded original frames.',
        );
        await ready('first return settled');
      });
      final afterReturn = await fixture.stats();
      expect(afterReturn['gets'], beforeReturn['gets']);
      report['networkAfterFirstReturn'] = afterReturn;

      // Move beyond the warmed strip, then let >32 originals accumulate while
      // persistence is held. This models browsing that repeatedly interrupts
      // optional CPU work, without making timing depend on host CPU speed.
      service.setMaintenanceHeld(true);
      final beforePressure = await fixture.stats();
      await measure('browse-with-thumbnail-persistence-held', () async {
        for (var page = 4; page <= 10; page++) {
          position().jumpTo(viewport * page);
          await WidgetsBinding.instance.endOfFrame;
          await ready('pressure page $page');
        }
      });
      final afterPressure = await fixture.stats();
      expect(
        (afterPressure['gets'] as int) - (beforePressure['gets'] as int),
        greaterThan(40),
        reason: 'The pressure phase must exceed the 32-item derivative queue.',
      );
      expect(service.derivativePendingCount, lessThanOrEqualTo(32));
      report['pressure'] = {
        'before': beforePressure,
        'after': afterPressure,
        'pendingDerivatives': service.derivativePendingCount,
        'memoryCacheBytes':
            PaintingBinding.instance.imageCache.currentSizeBytes,
        'memoryCacheLimitBytes':
            PaintingBinding.instance.imageCache.maximumSizeBytes,
      };
      service.setMaintenanceHeld(false);
      await _until(
        () => service.derivativePendingCount == 0,
        'pressure thumbnails settled',
      );
      final beforePressureReturn = await fixture.stats();
      await measure('return-to-early-pressure-page', () async {
        position().jumpTo(viewport * 4);
        await WidgetsBinding.instance.endOfFrame;
        await ready('pressure return');
      });
      final afterPressureReturn = await fixture.stats();
      expect(afterPressureReturn['gets'], beforePressureReturn['gets']);
      report['pressureReturn'] = {
        'before': beforePressureReturn,
        'after': afterPressureReturn,
      };

      await _until(() => service.derivativePendingCount == 0, 'pre-pause idle');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Deliberately no pump and no request for a frame after paused.
      final beforePause = await fixture.stats();
      final pending = service.pendingCount;
      final derivatives = service.derivativePendingCount;
      await Future<void>.delayed(const Duration(milliseconds: 650));
      final afterPause = await fixture.stats();
      expect(afterPause['gets'], beforePause['gets']);
      expect(service.pendingCount, pending);
      expect(service.derivativePendingCount, derivatives);
      expect(service.derivativeActiveCount, 0);
      expect(ArtworkDecodeQueue.instance.pendingCount, 0);
      report['pausedWithoutPump'] = {
        'before': beforePause,
        'after': afterPause,
      };
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await WidgetsBinding.instance.endOfFrame;
      await ready('resumed page');
      report['runStatus'] = 'complete';
      binding.reportData = await compute(_writeReport, report);
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await model.flushMetadataTasks();
      store.dispose();
      await fixture.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _until(bool Function() condition, String label) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $label');
    await Future<void>.delayed(const Duration(milliseconds: 8));
  }
}

({int visible, int missing}) _visible(WidgetTester tester, Finder wall) {
  if (wall.evaluate().isEmpty) return (visible: 0, missing: 0);
  final bounds = tester
      .getRect(wall)
      .intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  var visible = 0, missing = 0;
  for (final element in find.byType(AlbumThumbnail).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    if (!(box.localToGlobal(Offset.zero) & box.size).overlaps(bounds)) continue;
    visible++;
    final pixels = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(RawImage),
    );
    if (!tester
        .widgetList<RawImage>(pixels)
        .any((image) => image.image != null)) {
      missing++;
    }
  }
  return (visible: visible, missing: missing);
}

const _groups = 1200;

class _Fixture {
  final Isolate worker;
  final ReceivePort replies;
  final SendPort commands;
  final String root;
  final Map<String, dynamic> source;
  final int workerId;
  Completer<Map<String, Object?>>? pending;
  final stopped = Completer<void>();
  _Fixture(
    this.worker,
    this.replies,
    this.commands,
    this.root,
    this.source,
    this.workerId,
  );

  static Future<_Fixture> start() async {
    final replies = ReceivePort();
    final ready = Completer<List<dynamic>>();
    _Fixture? fixture;
    replies.listen((message) {
      final row = message as List;
      switch (row[0]) {
        case 'ready':
          ready.complete(row);
        case 'stats':
          fixture!.pending!.complete(Map<String, Object?>.from(row[1] as Map));
          fixture.pending = null;
        case 'closed':
          fixture!.stopped.complete();
        case 'error':
          if (!ready.isCompleted) ready.completeError(StateError('${row[1]}'));
      }
    });
    final worker = await Isolate.spawn(_serve, replies.sendPort);
    final row = await ready.future;
    return fixture = _Fixture(
      worker,
      replies,
      row[1] as SendPort,
      row[2] as String,
      Map<String, dynamic>.from(row[3] as Map),
      row[4] as int,
    );
  }

  Future<Map<String, Object?>> stats() {
    if (pending != null) throw StateError('Only one stats request at a time');
    pending = Completer<Map<String, Object?>>();
    commands.send('stats');
    return pending!.future;
  }

  Future<void> close() async {
    commands.send('close');
    await stopped.future;
    replies.close();
    worker.kill();
  }
}

Future<void> _serve(SendPort reply) async {
  final commands = ReceivePort();
  Directory? root;
  HttpServer? server;
  try {
    root = Directory.systemTemp.createTempSync('album-return-profile-');
    final pixels = raster.Image(width: 1600, height: 1200);
    for (final pixel in pixels) {
      pixel.setRgb(
        (pixel.x ~/ 3) % 256,
        (pixel.y ~/ 2) % 256,
        ((pixel.x + pixel.y) ~/ 4) % 256,
      );
    }
    final bytes = raster.encodeJpg(pixels, quality: 85);
    const modified = 'Sun, 01 Nov 2026 12:00:00 GMT';
    final listing = StringBuffer('<d:multistatus xmlns:d="DAV:">');
    for (var index = -1; index < _groups; index++) {
      final path = index < 0
          ? '/dav/album/'
          : '/dav/album/${index.toString().padLeft(5, '0')}.jpg';
      listing.write(
        '<d:response><d:href>$path</d:href><d:propstat><d:prop>'
        '<d:resourcetype>${index < 0 ? '<d:collection/>' : ''}</d:resourcetype>'
        '<d:getcontentlength>${index < 0 ? 0 : bytes.length}</d:getcontentlength>'
        '<d:getlastmodified>$modified</d:getlastmodified>'
        '</d:prop></d:propstat></d:response>',
      );
    }
    listing.write('</d:multistatus>');
    final xml = utf8.encode('$listing');
    var gets = 0, heads = 0, propfinds = 0;
    final perPath = <String, int>{};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.method == 'PROPFIND' && request.uri.path == '/dav/album/') {
          propfinds++;
          request.response.statusCode = 207;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.add(xml);
        } else if (RegExp(r'^/dav/album/\d{5}\.jpg$')
            .hasMatch(request.uri.path)) {
          request.response.headers.set('last-modified', modified);
          request.response.headers.set('accept-ranges', 'bytes');
          if (request.method == 'HEAD') {
            heads++;
            request.response.contentLength = bytes.length;
          } else if (request.method == 'GET') {
            gets++;
            perPath.update(
              request.uri.path,
              (value) => value + 1,
              ifAbsent: () => 1,
            );
            final range = RegExp(r'^bytes=(\d+)-(\d+)$')
                .firstMatch(request.headers.value('range') ?? '');
            final start = range == null ? 0 : int.parse(range[1]!);
            final end = math.min(
              bytes.length - 1,
              range == null ? bytes.length - 1 : int.parse(range[2]!),
            );
            if (range != null) {
              request.response.statusCode = 206;
              request.response.headers.set(
                'content-range',
                'bytes $start-$end/${bytes.length}',
              );
            }
            request.response.contentLength = end - start + 1;
            request.response.add(Uint8List.sublistView(bytes, start, end + 1));
          } else {
            request.response.statusCode = 405;
          }
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      } on HttpException {
        // Production cancellation may close an in-flight request.
      } on SocketException {
        // Same bounded cancellation path.
      }
    });
    final source = <String, dynamic>{
      'id': 'album-return-profile',
      'kind': 'webdav',
      'label': 'Return album',
      'url': 'http://127.0.0.1:${server.port}/dav/',
    };
    final store = AppStore('${root.path}/library.db');
    store.setLocal('settings', {
      'autoIdentifyOnFolderOpen': false,
      'autoDiscover': false,
    });
    store.setLocal('sources', [source]);
    store.dispose();
    reply.send([
      'ready',
      commands.sendPort,
      root.path,
      source,
      Isolate.current.hashCode,
    ]);
    await for (final command in commands) {
      if (command == 'close') break;
      if (command == 'stats') {
        reply.send([
          'stats',
          {
            'gets': gets,
            'heads': heads,
            'propfinds': propfinds,
            'uniqueImages': perPath.length,
            'duplicateGets': perPath.values.fold<int>(
              0,
              (sum, count) => sum + count - 1,
            ),
          },
        ]);
      }
    }
  } catch (error, stack) {
    reply.send(['error', '$error\n$stack']);
  } finally {
    await server?.close(force: true);
    commands.close();
    if (root != null) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
    reply.send(['closed']);
  }
}

Map<String, Object?> _writeReport(Map<String, Object?> report) {
  for (final phase in report['phases'] as List) {
    for (final prefix in ['build', 'raster']) {
      final values = (phase.remove('${prefix}Us') as List).cast<int>()..sort();
      phase['${prefix}Ms'] = values.isEmpty
          ? {'count': 0}
          : {
              'count': values.length,
              'p50': values[(values.length * .5).ceil() - 1] / 1000,
              'p95': values[(values.length * .95).ceil() - 1] / 1000,
              'max': values.last / 1000,
            };
    }
  }
  const output = String.fromEnvironment(
    'ALBUM_RETURN_ARTIFACT_DIR',
    defaultValue: '../artifacts',
  );
  Directory(output).createSync(recursive: true);
  File('$output/album-scroll-return-performance.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  return report;
}
