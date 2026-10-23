import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/webdav_series_refresh_performance_test.dart
// --dart-define=WEBDAV_SERIES_ARTIFACT_DIR=/absolute/artifact/path
// The HTTP fixture runs in another isolate. Actual WebDAV parsing, SQLite
// workers, catalog and AppModel are used; only source adapter creation is wired
// to the local server. Linux Xvfb/software rendering and local HTTP do not
// establish user-device frame rates or the behavior of a real NAS/network.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('profile real WebDAV details completion and automatic refresh', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp(
      'webdav-series-profile-',
    );
    final store = AppStore('${root.path}/library.db');
    final fixture = await _WebDavFixture.start(800);
    final imports = _ImportProbe();
    final model = _ProfileModel(store, root, fixture.address, imports);
    const unrelatedVideos = 3000, firstEpisodes = 800, finalEpisodes = 900;
    const firstId = '000-webdav-series';
    const firstName = 'WebDAV Profile Series S01E001.mkv';
    const seriesKey = 'bangumi:7001:1';
    // Synchronous fixture setup happens before the UI is mounted or measured.
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      store.save('media', firstId, {
        'title': firstName,
        'fileName': firstName,
        'series': 'WebDAV Profile Series',
        'season': '1',
        'episode': '1',
        'size': 101,
        'bangumiId': '7001',
        'metadataTitle': 'WebDAV Profile Series',
        'totalEpisodes': finalEpisodes,
      });
      store.setLocal('location:$firstId', {
        'id': firstId,
        'source': 'profile-nas',
        'path': 'Series/$firstName',
        'size': 101,
      });
      for (var index = 0; index < unrelatedVideos; index++) {
        store.save('media', 'fixture-$index', {
          'title': '视频 $index.mp4',
          'series': '未分类',
          'size': index + 1,
        });
      }
    });

    final frames = <ui.FrameTiming>[];
    final phases = <Map<String, Object?>>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    Future<void> waitFor(bool Function() ready, String label) async {
      final deadline = DateTime.now().add(const Duration(seconds: 50));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) fail('Timed out: $label');
        // fullyLive allows production frame scheduling while this test waits.
        // Do not force idle frames throughout the real 30-second timer wait.
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
    }

    Future<void> measure(String name, Future<void> Function() operation) async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      frames.clear();
      WidgetsBinding.instance.addTimingsCallback(collect);
      final elapsed = Stopwatch()..start();
      try {
        await operation();
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      } finally {
        elapsed.stop();
        WidgetsBinding.instance.removeTimingsCallback(collect);
      }
      expect(frames, isNotEmpty, reason: '$name must capture actual UI frames');
      phases.add({
        'phase': name,
        'elapsedMs': elapsed.elapsedMicroseconds / 1000,
        'frames': frames.length,
        'buildMs': _distribution(frames.map((frame) => frame.buildDuration)),
        'rasterMs': _distribution(frames.map((frame) => frame.rasterDuration)),
      });
    }

    try {
      expect(fixture.isolateId, isNot(Isolate.current.hashCode));
      final before = await model.loadLibrarySnapshot();
      expect(before.media.length, unrelatedVideos + 1);
      expect(before.series[seriesKey], hasLength(1));
      expect(before.preparationIsolate, isNot(Isolate.current.hashCode));
      await tester.pumpWidget(AIPlayerApp(model: model));
      await waitFor(
        () => find
            .byKey(const ValueKey('details:$firstId'))
            .evaluate()
            .isNotEmpty,
        'All Videos series card',
      );
      await tester.pumpAndSettle();
      await measure('open-details-import-799-webdav-episodes', () async {
        await tester.tap(find.byKey(const ValueKey('details:$firstId')));
        await tester.pump();
        await waitFor(
          () =>
              find.textContaining('已收录 $firstEpisodes 集').evaluate().isNotEmpty,
          'initial WebDAV completion to $firstEpisodes episodes',
        );
      });
      final details = find.byKey(const ValueKey('series-details-list'));
      final originalDetails = tester.element(details);
      final originalRoute = ModalRoute.of(originalDetails);
      final first = await model.loadLibrarySnapshot();
      expect(first.media.length, unrelatedVideos + firstEpisodes);
      expect(first.series[seriesKey], hasLength(firstEpisodes));
      expect(imports.windows, hasLength(1));
      expect(imports.windows.first.heartbeatIntervals, isNotEmpty);

      await fixture.setAvailable(finalEpisodes);
      final addedAt = DateTime.now();
      await measure(
        'visible-details-real-30s-poll-imports-100-new-episodes',
        () async {
          await waitFor(
            () => find
                .textContaining('已收录 $finalEpisodes 集')
                .evaluate()
                .isNotEmpty,
            'automatic WebDAV refresh to $finalEpisodes episodes',
          );
        },
      );
      final discoveryDelay = DateTime.now().difference(addedAt);
      expect(tester.element(details), same(originalDetails));
      expect(ModalRoute.of(tester.element(details)), same(originalRoute));
      final updated = await model.loadLibrarySnapshot();
      expect(updated.media.length, unrelatedVideos + finalEpisodes);
      expect(updated.series[seriesKey], hasLength(finalEpisodes));
      expect(updated.preparationIsolate, isNot(Isolate.current.hashCode));
      expect(imports.windows, hasLength(2));
      expect(imports.windows.last.heartbeatIntervals, isNotEmpty);
      expect(store.records('progress'), isEmpty);
      expect(fixture.requests, hasLength(2));
      expect(
        fixture.requests.every(
          (request) =>
              request['method'] == 'PROPFIND' &&
              request['path'] == '/dav/Series/',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : 'debug',
        'platform': Platform.operatingSystem,
        'scope':
            'full AIPlayerApp; disk SQLite; real local WebDAV HTTP server in '
            'a separate isolate; real AppModel/catalog/loaders and database workers; '
            'only adapter construction is overridden; metadata recognition disabled; '
            'no artwork downloads or video playback',
        'limitations':
            'Linux Xvfb with software rendering and localhost HTTP; '
            'not user hardware, a real NAS, or a remote network; these measurements '
            'do not establish user-device frame rates',
        'unrelatedVideos': unrelatedVideos,
        'initialImportedSeriesEpisodes': 1,
        'firstServerEpisodes': firstEpisodes,
        'finalServerEpisodes': finalEpisodes,
        'sameDetailsElementAndRouteAfterRefresh': true,
        'mainIsolate': Isolate.current.hashCode,
        'serverIsolate': fixture.isolateId,
        'snapshotPreparationIsolate': updated.preparationIsolate,
        'configuredRefreshDelayMs': model
            .seriesRefreshDelay(updated.byId[firstId]!)
            .inMilliseconds,
        'observedNewFilesToVisibleDetailsMs': discoveryDelay.inMilliseconds,
        'requests': fixture.requests,
        'importWindows': imports.windows
            .map((window) => window.report)
            .toList(),
        'phases': phases,
      };
      final artifacts = Directory(
        const String.fromEnvironment(
          'WEBDAV_SERIES_ARTIFACT_DIR',
          defaultValue: '../artifacts/webdav-series-refresh-20261023',
        ),
      );
      await artifacts.create(recursive: true);
      await File(
        '${artifacts.path}/webdav-series-refresh-performance.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      binding.reportData = report;
      debugPrint(jsonEncode(report));
    } finally {
      await tester.pumpWidget(const SizedBox());
      imports.dispose();
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      await fixture.close();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _ProfileModel extends AppModel {
  final String address;
  final _ImportProbe probe;
  _ProfileModel(super.store, super.documents, this.address, this.probe)
    : super(backgroundWork: false);

  @override
  Future<SourceAdapter> adapter(String id) async =>
      _ObservedSource(HttpSource(address, webdav: true), probe);
}

/// Observe the existing source lifetime without replacing any network, parsing
/// or import work. AppModel closes the adapter after its database import ends.
class _ObservedSource extends SourceAdapter {
  final SourceAdapter delegate;
  final _ImportProbe probe;
  _ImportWindow? window;
  _ObservedSource(this.delegate, this.probe);

  @override
  Future<List<SourceEntry>> list(String path) async {
    final entries = await delegate.list(path);
    window = probe.start(entries.length);
    return entries;
  }

  @override
  Future<SourceEntry> stat(String path) => delegate.stat(path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      delegate.read(path, start, end);
  @override
  Future<void> close() async {
    window?.finish();
    await delegate.close();
  }
}

class _ImportProbe {
  final windows = <_ImportWindow>[];
  _ImportWindow start(int episodes) {
    final window = _ImportWindow(episodes);
    windows.add(window);
    return window;
  }

  void dispose() {
    for (final window in windows) {
      window.finish();
    }
  }
}

class _ImportWindow {
  final int listedEpisodes;
  final watch = Stopwatch()..start();
  final heartbeatIntervals = <Duration>[];
  late final Timer timer;
  Duration previous = Duration.zero;
  _ImportWindow(this.listedEpisodes) {
    timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final now = watch.elapsed;
      heartbeatIntervals.add(now - previous);
      previous = now;
    });
  }
  void finish() {
    timer.cancel();
    watch.stop();
  }

  Map<String, Object?> get report => {
    'listedEpisodes': listedEpisodes,
    'scope':
        'after the real HTTP listing and XML decode return, until AppModel '
        'closes the adapter after background directory synchronization; '
        'includes orchestration and worker commits, not only SQL execution',
    'elapsedMs': watch.elapsedMicroseconds / 1000,
    'mainIsolateHeartbeat': {
      'requestedPeriodMs': 4,
      'callbacks': heartbeatIntervals.length,
      'intervalMs': _distribution(heartbeatIntervals),
    },
  };
}

class _WebDavFixture {
  final Isolate isolate;
  final ReceivePort events;
  final SendPort commands;
  final int port, isolateId;
  final List<Map<String, Object?>> requests;
  _WebDavFixture(
    this.isolate,
    this.events,
    this.commands,
    this.port,
    this.isolateId,
    this.requests,
  );
  String get address => 'http://127.0.0.1:$port/dav/';

  static Future<_WebDavFixture> start(int count) async {
    final events = ReceivePort();
    final ready = Completer<(SendPort, int, int)>();
    final requests = <Map<String, Object?>>[];
    final watch = Stopwatch()..start();
    events.listen((dynamic event) {
      if (event case (SendPort commands, int port, int isolateId)) {
        ready.complete((commands, port, isolateId));
      } else if (event case (String method, String path, int available)) {
        requests.add({
          'method': method,
          'path': path,
          'availableEpisodes': available,
          'observedAtMs': watch.elapsedMilliseconds,
        });
      }
    });
    final isolate = await Isolate.spawn(_serveWebDav, (events.sendPort, count));
    final (commands, port, isolateId) = await ready.future;
    return _WebDavFixture(isolate, events, commands, port, isolateId, requests);
  }

  Future<void> setAvailable(int count) async {
    final reply = ReceivePort();
    commands.send((count, reply.sendPort));
    await reply.first.timeout(const Duration(seconds: 5));
    reply.close();
  }

  Future<void> close() async {
    final reply = ReceivePort();
    commands.send(('close', reply.sendPort));
    try {
      await reply.first.timeout(const Duration(seconds: 5));
    } finally {
      reply.close();
      events.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

Future<void> _serveWebDav((SendPort, int) arguments) async {
  final (events, initialCount) = arguments;
  var available = initialCount;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final commands = ReceivePort();
  server.listen((request) async {
    final count = available;
    events.send((request.method, request.uri.path, count));
    if (request.method != 'PROPFIND') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
    } else if (request.uri.path == '/dav/Series') {
      request.response.statusCode = HttpStatus.movedPermanently;
      request.response.headers.set('Location', '/dav/Series/');
    } else if (request.uri.path == '/dav/Series/') {
      request.response.statusCode = 207;
      request.response.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.response.write(_seriesListing(count));
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  events.send((commands.sendPort, server.port, Isolate.current.hashCode));
  commands.listen((dynamic command) async {
    if (command case (int count, SendPort reply)) {
      available = count;
      reply.send(true);
    } else if (command case ('close', SendPort reply)) {
      await server.close(force: true);
      commands.close();
      reply.send(true);
      Isolate.exit();
    }
  });
}

String _seriesListing(int count) {
  final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">')
    ..write(
      '<d:response><d:href>/dav/Series/</d:href><d:propstat><d:prop>'
      '<d:resourcetype><d:collection/></d:resourcetype>'
      '</d:prop></d:propstat></d:response>',
    );
  for (var episode = 1; episode <= count; episode++) {
    final filename =
        'WebDAV Profile Series S01E${episode.toString().padLeft(3, '0')}.mkv';
    final path = Uri(path: '/dav/Series/$filename');
    xml.write(
      '<d:response><d:href>$path</d:href><d:propstat><d:prop>'
      '<d:getcontentlength>${episode + 100}</d:getcontentlength>'
      '<d:resourcetype/></d:prop></d:propstat></d:response>',
    );
  }
  return (xml..write('</d:multistatus>')).toString();
}

Map<String, Object> _distribution(Iterable<Duration> values) {
  final sorted = values.map((value) => value.inMicroseconds / 1000).toList()
    ..sort();
  if (sorted.isEmpty) return {'count': 0};
  return {
    'count': sorted.length,
    'p50': sorted[(sorted.length * .5).ceil() - 1],
    'p95': sorted[(sorted.length * .95).ceil() - 1],
    'max': sorted.last,
    'over16_67ms': sorted.where((value) => value > 1000 / 60).length,
  };
}
