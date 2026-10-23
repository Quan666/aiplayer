import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/subtitle_fonts.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Run with flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/playback_startup_performance_test.dart
// --dart-define=PLAYBACK_ARTIFACT_DIR=/absolute/artifact/path
// The fixture server owns its sockets and file reads in a separate isolate.
// Xvfb/software rendering measures this environment, not device frame rates.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('measure HTTP playback startup, repeated switches and reopen', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = File(
      const String.fromEnvironment(
        'MEDIA_FIXTURE',
        defaultValue: '/tmp/aiplayer-media-fixture/Example S01E01.mkv',
      ),
    );
    final size = await fixture.length();
    final server = await _FixtureServer.start(fixture.path);
    final root = await Directory.systemTemp.createTemp('startup-profile-');
    final store = AppStore('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    await model.updatePreferences({
      'enterFullscreen': false,
      'hardwareDecoding': false,
      'metadataStrategy': 'off',
      'autoPlay': true,
      'danmuVisible': false,
      'autoLoadExternalSubtitles': false,
    });
    await preparePlaybackFonts(root);
    store.setLocal('sources', [
      {'id': 'lan', 'kind': 'http', 'url': server.uri},
    ]);
    final firstId = model.addMedia(
      'lan',
      SourceEntry(name: 'First.mkv', path: '/first.mkv', size: size),
    );
    final secondId = model.addMedia(
      'lan',
      SourceEntry(name: 'Second.mkv', path: '/second.mkv', size: size),
    );
    final frames = <ui.FrameTiming>[];
    void collect(List<ui.FrameTiming> values) => frames.addAll(values);
    WidgetsBinding.instance.addTimingsCallback(collect);
    final phases = <Map<String, Object?>>[];
    final controller = PlayerPageController();
    try {
      for (final (phase, id, newPage) in [
        ('first-open', firstId, true),
        ('switch-1', secondId, false),
        ('switch-2', firstId, false),
        ('switch-3', secondId, false),
        ('reopen', firstId, true),
      ]) {
        if (newPage && phase != 'first-open') {
          await tester.pumpWidget(const SizedBox());
          await PlayerPage.waitForDisposals();
        }
        await server.request('reset');
        final clock = Stopwatch()..start();
        final start = developer.Timeline.now;
        Future<bool>? switching;
        if (newPage) {
          await tester.pumpWidget(
            MaterialApp(
              home: PlayerPage(
                model: model,
                media: store.get('media', id)!,
                controller: controller,
              ),
            ),
          );
        } else {
          switching = controller.selectMedia(store.get('media', id)!);
        }
        PlaybackSession? session;
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (session == null || !session.firstFrameRendered) {
          if (DateTime.now().isAfter(deadline)) {
            fail('$phase first frame timed out: ${session?.error}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
          final page = tester.state(find.byType(PlayerPage)) as dynamic;
          final candidate = page.session as PlaybackSession;
          if (candidate.media.id == id && session != candidate) {
            session = candidate;
            await (session.player.platform as NativePlayer).setProperty(
              'ao',
              'null',
            );
          }
        }
        final firstFrameMs = clock.elapsedMicroseconds / 1000;
        final upstream = await server.request('snapshot');
        expect(session.error, isEmpty);
        expect(session.video.rect.value!.width, greaterThan(1));
        expect(session.video.rect.value!.height, greaterThan(1));
        await tester.pump();
        await tester.pump();
        final presentedMs = clock.elapsedMicroseconds / 1000;
        final end = developer.Timeline.now;
        if (switching != null) expect(await switching, isTrue);
        // Engine timing callbacks arrive in batches. Filter by the measured
        // interval after the delivery grace period, excluding idle frames.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await tester.pump();
        final measured = frames.where((frame) {
          final time = frame.timestampInMicroseconds(ui.FramePhase.buildStart);
          return time >= start && time <= end;
        }).toList();
        phases.add({
          'phase': phase,
          'firstFrameMs': firstFrameMs,
          'presentedMs': presentedMs,
          'startupStagesMs': _startupTimings(session),
          'upstream': upstream,
          'frames': measured.length,
          'buildMs': _distribution(
            measured.map((frame) => frame.buildDuration),
          ),
          'rasterMs': _distribution(
            measured.map((frame) => frame.rasterDuration),
          ),
        });
        debugPrint('PLAYBACK_STARTUP ${jsonEncode(phases.last)}');
      }
      final report = <String, Object?>{
        'mode': kProfileMode
            ? 'profile'
            : kReleaseMode
            ? 'release'
            : 'debug',
        'platform': Platform.operatingSystem,
        'environment':
            'Actual PlayerPage; loopback HTTP; software video decode; preinstalled font; delayed HEAD 100 ms',
        'limitation':
            'Controlled host measurements; not physical LAN, SMB, mobile hardware decode or user device frame rates.',
        'fixtureBytes': size,
        'phases': phases,
      };
      binding.reportData = report;
      const artifact = String.fromEnvironment('PLAYBACK_ARTIFACT_DIR');
      if (artifact.isNotEmpty) {
        await Directory(artifact).create(recursive: true);
        await File(
          '$artifact/playback-startup.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
    } finally {
      WidgetsBinding.instance.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      await model.flushPlaybackPreviews();
      await server.close();
      model.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  });
}

Map<String, num> _distribution(Iterable<Duration> durations) {
  final values = durations.map((value) => value.inMicroseconds / 1000).toList()
    ..sort();
  if (values.isEmpty) return {'p50': 0, 'p95': 0, 'max': 0};
  double percentile(double value) =>
      values[((values.length - 1) * value).round()];
  return {'p50': percentile(.5), 'p95': percentile(.95), 'max': values.last};
}

Map<String, int>? _startupTimings(PlaybackSession session) {
  // Keep the benchmark runnable against revisions before stage diagnostics.
  try {
    return (session as dynamic).startupTimings as Map<String, int>;
  } on NoSuchMethodError {
    return null;
  }
}

class _FixtureServer {
  final SendPort commands;
  final String uri;
  _FixtureServer(this.commands, this.uri);

  static Future<_FixtureServer> start(String path) async {
    final ready = ReceivePort();
    await Isolate.spawn(_serveFixture, (ready.sendPort, path));
    final message = await ready.first as (SendPort, String);
    ready.close();
    return _FixtureServer(message.$1, message.$2);
  }

  Future<Map<String, Object?>> request(String method) async {
    final replies = ReceivePort();
    commands.send((method, replies.sendPort));
    final result = await replies.first as Map<String, Object?>;
    replies.close();
    return result;
  }

  Future<void> close() async => request('close');
}

Future<void> _serveFixture((SendPort, String) configuration) async {
  final file = File(configuration.$2);
  final size = await file.length();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final commands = ReceivePort();
  final requests = <Map<String, Object?>>[];
  final connections = <int>{};
  commands.listen((dynamic message) async {
    final (method, reply) = message as (String, SendPort);
    if (method == 'reset') {
      requests.clear();
      connections.clear();
    }
    if (method == 'close') {
      await server.close(force: true);
      commands.close();
    }
    reply.send({
      'connections': connections.length,
      'requests': List.of(requests),
    });
  });
  server.listen((request) async {
    connections.add(request.connectionInfo!.remotePort);
    requests.add({
      'method': request.method,
      'range': request.headers.value('range'),
      'port': request.connectionInfo!.remotePort,
    });
    final response = request.response;
    try {
      if (request.method == 'HEAD') {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final header = request.headers.value('range');
      final range = ByteRange.parse(header, size)!;
      response.statusCode = header == null ? 200 : 206;
      response.headers.set('Accept-Ranges', 'bytes');
      response.contentLength = range.length;
      if (header != null) {
        response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/$size',
        );
      }
      if (request.method != 'HEAD') {
        await response.addStream(file.openRead(range.start, range.end + 1));
      }
      await response.close();
    } on HttpException {
      // mpv abandons read-ahead and seeks during file switches.
    } on SocketException {
      // The counterpart closed a canceled range request.
    }
  });
  configuration.$1.send((commands.sendPort, 'http://127.0.0.1:${server.port}'));
}
