import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/source_folder_first_open_test.dart
// --dart-define=FOLDER_FIRST_OPEN_ARTIFACT_DIR=/absolute/artifact/path
// Full AIPlayerApp, empty media/progress database, actual source navigation and
// a real WebDAV server on an independent isolate. No model/adapter/catalog mocks.
// Linux Xvfb software rendering and localhost HTTP are not a user's NAS/device.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'first source folder visit shows unplayed numeric season details',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await (FontLoader('NotoSansSC')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
          .load();
      final root = await Directory.systemTemp.createTemp('folder-first-open-');
      final fixture = await _FolderWebDav.start();
      final store = AppStore('${root.path}/library.db')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        })
        ..setLocal('sources', [
          {
            'id': 'first-open-webdav',
            'kind': 'webdav',
            'label': '首次打开 WebDAV',
            'url': fixture.address,
          },
        ]);
      final model = AppModel(store, root, backgroundWork: false);
      final boundaryKey = GlobalKey();
      final frames = <ui.FrameTiming>[];
      final phases = <Map<String, Object?>>[];
      void collect(List<ui.FrameTiming> timings) => frames.addAll(timings);

      Future<void> waitFor(bool Function() ready, String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!ready()) {
          if (DateTime.now().isAfter(deadline)) fail('Timed out: $label');
          // fullyLive keeps production frame scheduling active without forcing
          // idle frames from the measurement harness.
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
      }

      Future<void> tapAndWait(Finder target, Finder next, String label) async {
        await waitFor(() => target.evaluate().isNotEmpty, label);
        await tester.ensureVisible(target);
        // Keys identify reorder/opacity wrappers, whose render objects need
        // not participate in hit testing. Tap their visible row text, as a
        // user would, rather than requiring the wrapper itself to be a hit.
        final rowText = find.descendant(
          of: target,
          matching: find.byType(Text),
        );
        await waitFor(
          () =>
              rowText.hitTestable().evaluate().isNotEmpty ||
              target.hitTestable().evaluate().isNotEmpty,
          '$label visible tap target',
        );
        await tester.tap(
          rowText.hitTestable().evaluate().isNotEmpty
              ? rowText.hitTestable().first
              : target.hitTestable(),
        );
        await tester.pump();
        await waitFor(() => next.evaluate().isNotEmpty, '$label destination');
        await tester.pumpAndSettle();
        expect(find.byType(PlayerPage), findsNothing);
      }

      Future<void> measure(
        String name,
        Future<void> Function() operation,
      ) async {
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
        expect(
          frames,
          isNotEmpty,
          reason: '$name must include rendered app frames',
        );
        phases.add({
          'phase': name,
          'elapsedMs': elapsed.elapsedMicroseconds / 1000,
          'frames': frames.length,
          'buildMs': _distribution(frames.map((frame) => frame.buildDuration)),
          'rasterMs': _distribution(
            frames.map((frame) => frame.rasterDuration),
          ),
        });
      }

      try {
        final before = await model.loadLibrarySnapshot();
        expect(before.media, isEmpty);
        expect(store.records('progress'), isEmpty);
        expect(fixture.isolateId, isNot(Isolate.current.hashCode));
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: AIPlayerApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MediaDetailsOverview), findsNothing);
        await measure(
          'navigate-source-root-and-series-with-empty-library',
          () async {
            await tapAndWait(
              find.byKey(const ValueKey('nav-item-1')),
              find.text('首次打开 WebDAV'),
              'sources navigation',
            );
            await tapAndWait(
              find.text('首次打开 WebDAV'),
              find.byKey(const ValueKey('Series/')),
              'WebDAV source root',
            );
            await tapAndWait(
              find.byKey(const ValueKey('Series/')),
              find.byKey(const ValueKey('Series/S02/')),
              'Series directory',
            );
          },
        );
        final beforeSeason = await model.loadLibrarySnapshot();
        expect(
          beforeSeason.media,
          isEmpty,
          reason: 'parent-directory previews must not seed the media library',
        );
        expect(store.records('progress'), isEmpty);
        expect(find.byType(MediaDetailsOverview), findsNothing);

        await measure(
          'first-open-S02-numeric-files-shows-series-details',
          () async {
            await tapAndWait(
              find.byKey(const ValueKey('Series/S02/')),
              find.byType(MediaDetailsOverview),
              'first visit to Series/S02/',
            );
            await waitFor(
              () => find.textContaining('已收录 2 集').evaluate().isNotEmpty,
              'two unplayed episodes in the first-open details',
            );
          },
        );
        final overview = tester.widget<MediaDetailsOverview>(
          find.byType(MediaDetailsOverview),
        );
        expect(overview.details.title, 'Series');
        expect(overview.details.season, '2');
        expect(overview.details.availableEpisodes, 2);
        expect(overview.records.map((item) => item.data['episode']), [
          '1',
          '2',
        ]);
        expect(
          overview.records.every((item) => item.data['season'] == '2'),
          isTrue,
        );
        expect(find.text('第 2 季'), findsOneWidget);
        expect(find.byType(MediaDetailsEpisodeTile), findsNWidgets(2));
        expect(find.byType(PlayerPage), findsNothing);
        expect(store.records('progress'), isEmpty);
        final imported = await model.loadLibrarySnapshot();
        expect(imported.media, hasLength(2));
        expect(imported.preparationIsolate, isNot(Isolate.current.hashCode));
        expect(
          imported.locations.values.map((location) => location['path']).toSet(),
          {'Series/S02/01.mkv', 'Series/S02/02.mkv'},
        );
        expect(
          fixture.requests.every((request) => request['method'] == 'PROPFIND'),
          isTrue,
          reason: 'opening details must not start media transfer or playback',
        );
        expect(tester.takeException(), isNull);

        final artifacts = Directory(
          const String.fromEnvironment(
            'FOLDER_FIRST_OPEN_ARTIFACT_DIR',
            defaultValue: '../artifacts/folder-first-open-20261023',
          ),
        );
        await artifacts.create(recursive: true);
        // Capture the actual app content after frame measurements; readback and
        // PNG encoding must not be counted as navigation/render performance.
        await tester.pump();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final screenshot = await boundary.toImage(pixelRatio: 1);
        final screenshotSize = {
          'width': screenshot.width,
          'height': screenshot.height,
        };
        final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
        screenshot.dispose();
        expect(png, isNotNull);
        const screenshotName = 'source-folder-first-open.png';
        await File('${artifacts.path}/$screenshotName').writeAsBytes(
          png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
        final report = <String, Object?>{
          'mode': kProfileMode ? 'profile' : 'debug',
          'platform': Platform.operatingSystem,
          'scope':
              'full AIPlayerApp; empty media/progress database; disk SQLite; '
              'actual clicks through Sources > WebDAV > Series > S02; numeric '
              '01.mkv and 02.mkv; real AppModel, adapter, catalog and workers; '
              'metadata recognition disabled; no model or source overrides',
          'limitations':
              'Linux Xvfb with software rendering and localhost HTTP; '
              'not user hardware, a real NAS, or a remote network; measurements '
              'do not establish user-device frame rates',
          'initialMediaRecords': before.media.length,
          'mediaRecordsBeforeOpeningSeason': beforeSeason.media.length,
          'mediaRecordsAfterOpeningSeason': imported.media.length,
          'progressRecords': 0,
          'playerPageOpened': false,
          'details': {
            'title': overview.details.title,
            'season': overview.details.season,
            'availableEpisodes': overview.details.availableEpisodes,
            'episodes': overview.records
                .map((item) => item.data['episode'])
                .toList(),
          },
          'mainIsolate': Isolate.current.hashCode,
          'serverIsolate': fixture.isolateId,
          'snapshotPreparationIsolate': imported.preparationIsolate,
          'requests': fixture.requests,
          'phases': phases,
          'screenshot': {'file': screenshotName, ...screenshotSize},
        };
        await File(
          '${artifacts.path}/source-folder-first-open.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        binding.reportData = report;
        debugPrint(jsonEncode(report));
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        await model.sync.dispose();
        store.dispose();
        await fixture.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _FolderWebDav {
  final Isolate isolate;
  final ReceivePort events;
  final SendPort commands;
  final int port, isolateId;
  final List<Map<String, Object?>> requests;
  _FolderWebDav(
    this.isolate,
    this.events,
    this.commands,
    this.port,
    this.isolateId,
    this.requests,
  );
  String get address => 'http://127.0.0.1:$port/dav/';

  static Future<_FolderWebDav> start() async {
    final events = ReceivePort();
    final ready = Completer<(SendPort, int, int)>();
    final requests = <Map<String, Object?>>[];
    events.listen((dynamic event) {
      if (event case (SendPort commands, int port, int isolateId)) {
        ready.complete((commands, port, isolateId));
      } else if (event case (String method, String path)) {
        requests.add({'method': method, 'path': path});
      }
    });
    final isolate = await Isolate.spawn(_serveFolders, events.sendPort);
    final (commands, port, isolateId) = await ready.future.timeout(
      const Duration(seconds: 10),
    );
    return _FolderWebDav(isolate, events, commands, port, isolateId, requests);
  }

  Future<void> close() async {
    final reply = ReceivePort();
    commands.send(reply.sendPort);
    try {
      await reply.first.timeout(const Duration(seconds: 5));
    } finally {
      reply.close();
      events.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

Future<void> _serveFolders(SendPort events) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final commands = ReceivePort();
  server.listen((request) async {
    events.send((request.method, request.uri.path));
    final path = request.uri.path;
    if (request.method != 'PROPFIND') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
    } else if (!path.endsWith('/')) {
      request.response.statusCode = HttpStatus.movedPermanently;
      request.response.headers.set('Location', '$path/');
    } else if (const {
      '/dav/',
      '/dav/Series/',
      '/dav/Series/S02/',
    }.contains(path)) {
      request.response.statusCode = 207;
      request.response.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.response.write(_listing(path));
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
  events.send((commands.sendPort, server.port, Isolate.current.hashCode));
  commands.listen((dynamic command) async {
    if (command is SendPort) {
      await server.close(force: true);
      commands.close();
      command.send(true);
      Isolate.exit();
    }
  });
}

String _listing(String path) {
  final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
  void entry(String href, {bool directory = true}) {
    xml.write(
      '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
      '<d:getcontentlength>${directory ? 0 : 128}</d:getcontentlength>'
      '<d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
      '</d:prop></d:propstat></d:response>',
    );
  }

  entry(path);
  switch (path) {
    case '/dav/':
      entry('/dav/Series/');
    case '/dav/Series/':
      entry('/dav/Series/S02/');
    case '/dav/Series/S02/':
      entry('/dav/Series/S02/01.mkv', directory: false);
      entry('/dav/Series/S02/02.mkv', directory: false);
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
