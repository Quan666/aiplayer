import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Native decoder regression, runnable under Linux/Xvfb. Linux selects the mobile
// PlayerPage policy, including model-change callbacks; Android/iOS use the native
// platform default. This verifies libmpv state, not lifecycle delivery or power.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('mobile background policy preserves playback across native open', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    const fixture = String.fromEnvironment(
      'MEDIA_FIXTURE',
      defaultValue: '/tmp/aiplayer-media-fixture/Example S01E01.mkv',
    );
    final server = await _HeldFixture.start(fixture);
    final root = await Directory.systemTemp.createTemp('background-playback-');
    final store = AppStore('${root.path}/library.db');
    final model = AppModel(store, root, backgroundWork: false);
    final results = <Map<String, Object?>>[];
    try {
      await model.updatePreferences({
        'enterFullscreen': false,
        'hardwareDecoding': false,
        'metadataStrategy': 'off',
        'autoPlay': true,
        'danmuVisible': false,
        'autoLoadExternalSubtitles': false,
      });
      store.setLocal('sources', [
        {'id': 'fixture', 'kind': 'http', 'url': server.uri},
      ]);
      for (final (name, pause, rapidResume) in [
        ('background-before-open', true, false),
        ('background-and-resume-before-open', true, true),
        ('explicit-background-playback', false, false),
      ]) {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await model.updatePreferences({'pauseOnBackground': pause});
        await server.command('hold');
        final id = model.addMedia(
          'fixture',
          SourceEntry(name: '$name.mkv', path: '/$name.mkv', size: server.size),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              model: model,
              media: store.get('media', id)!,
              mobilePlaybackLifecycle: Platform.isLinux ? true : null,
            ),
          ),
        );
        final state = tester.state(find.byType(PlayerPage)) as dynamic;
        void changeLifecycle(AppLifecycleState lifecycle) {
          binding.handleAppLifecycleStateChanged(lifecycle);
        }

        final session = state.session as PlaybackSession;
        final native = session.player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await _until(
          () async => (await server.command('status'))['heads'] != 0,
        );
        expect(session.ready, isFalse, reason: 'HEAD response is still held');
        changeLifecycle(AppLifecycleState.paused);
        if (rapidResume) {
          changeLifecycle(AppLifecycleState.resumed);
        }
        await server.command('release');
        // Deliberately no tester.pump: an Android paused app has no new frames.
        await _until(() async => session.ready || session.error.isNotEmpty);
        expect(session.error, isEmpty);
        final remainsPaused = pause && !rapidResume;
        if (remainsPaused) {
          await _until(() async => await native.getProperty('pause') == 'yes');
        } else {
          await _until(() async => await _nativePositionMs(native) >= 500);
        }
        final before = await _nativePositionMs(native);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final after = await _nativePositionMs(native);
        final nativePause = await native.getProperty('pause');
        expect(nativePause, remainsPaused ? 'yes' : 'no');
        if (remainsPaused) {
          expect(after - before, lessThanOrEqualTo(100));
        } else {
          expect(after - before, greaterThan(500));
        }
        changeLifecycle(AppLifecycleState.resumed);
        await _until(
          () async =>
              await native.getProperty('pause') == 'no' &&
              await _nativePositionMs(native) > after + 300,
        );
        results.add({
          'case': name,
          'nativePause': nativePause,
          'positionDeltaMs': after - before,
          'observationMs': 1200,
          'foregroundNativePause': await native.getProperty('pause'),
          'foregroundPositionAdvanced': true,
        });

        if (pause) {
          // A session already playing must stop the actual decoder immediately
          // in the background, then resume the same episode on foreground.
          changeLifecycle(AppLifecycleState.paused);
          await _until(() async => await native.getProperty('pause') == 'yes');
          final stopped = await _nativePositionMs(native);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          expect(
            await _nativePositionMs(native) - stopped,
            lessThanOrEqualTo(150),
          );
          changeLifecycle(AppLifecycleState.resumed);
          await _until(
            () async =>
                await native.getProperty('pause') == 'no' &&
                await _nativePositionMs(native) > stopped + 300,
          );

          // Explicit user pause takes precedence over lifecycle restoration.
          await session.setPlaying(false);
          await _until(() async => await native.getProperty('pause') == 'yes');
          changeLifecycle(AppLifecycleState.paused);
          changeLifecycle(AppLifecycleState.resumed);
          final userPaused = await _nativePositionMs(native);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          expect(await native.getProperty('pause'), 'yes');
          final userPausedAfter = await _nativePositionMs(native);
          expect(userPausedAfter - userPaused, lessThanOrEqualTo(150));
          results.add({
            'case': '$name-user-paused-before-background',
            'nativePause': await native.getProperty('pause'),
            'positionDeltaMs': userPausedAfter - userPaused,
            'observationMs': 600,
          });
        }
        if (name == 'background-before-open') {
          final nextId = model.addMedia(
            'fixture',
            SourceEntry(
              name: 'Held-next.mkv',
              path: '/held-next.mkv',
              size: server.size,
            ),
          );
          final automaticId = model.addMedia(
            'fixture',
            SourceEntry(
              name: 'Queued-auto.mkv',
              path: '/queued-auto.mkv',
              size: server.size,
            ),
          );
          await server.command('hold');
          final switching =
              state.selectMedia(store.get('media', nextId)!) as Future<void>;
          await _until(
            () async => (await server.command('status'))['heads'] != 0,
          );
          final pending = state.session as PlaybackSession;
          final pauseRevision = pending.backgroundPauseRevision;
          final queued =
              state.selectMedia(
                    store.get('media', automaticId)!,
                    autoAdvance: true,
                  )
                  as Future<void>;
          changeLifecycle(AppLifecycleState.paused);
          changeLifecycle(AppLifecycleState.resumed);
          expect(pending.backgroundPauseRevision, greaterThan(pauseRevision));
          expect(pending.backgroundPlaybackBlocked, isFalse);
          await server.command('release');
          await switching;
          await queued;
          final retained = state.session as PlaybackSession;
          expect(retained.media.id, nextId);
          expect((await server.command('status'))['heads'], 1);
          final retainedNative = retained.player.platform as NativePlayer;
          await _until(
            () async =>
                await retainedNative.getProperty('pause') == 'no' &&
                await _nativePositionMs(retainedNative) >= 500,
          );
          results.add({
            'case': 'queued-auto-next-invalidated-by-background-and-resume',
            'nativePause': await retainedNative.getProperty('pause'),
            'retainedEpisodePositionMs': await _nativePositionMs(
              retainedNative,
            ),
            'openedQueuedEpisode': false,
          });
        }
        await tester.pumpWidget(const SizedBox());
        await PlayerPage.waitForDisposals();
      }
      final report = {
        'platform': Platform.operatingSystem,
        'positionSource': 'libmpv time-pos',
        'scope':
            'Real PlayerPage and libmpv; held HTTP HEAD; injected lifecycle; '
            '${Platform.isLinux ? 'simulated mobile pause/restore policy on Linux' : 'platform PlayerPage playback policy'}',
        'limitation':
            'Injected lifecycle does not verify Android lifecycle delivery; '
            'no Android battery measurement',
        'results': results,
      };
      binding.reportData = report;
      debugPrint('BACKGROUND_PLAYBACK ${jsonEncode(report)}');
      const artifact = String.fromEnvironment('ENERGY_ARTIFACT_DIR');
      if (artifact.isNotEmpty) {
        await Directory(artifact).create(recursive: true);
        await File(
          '$artifact/background-playback.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      await model.flushPlaybackPreviews();
      model.dispose();
      store.dispose();
      await server.command('close');
      await root.delete(recursive: true);
    }
  });
}

// Native pause acknowledgement can arrive before the last Dart position event.
// Read the decoder clock directly for both stopped and advancing observations.
Future<double> _nativePositionMs(NativePlayer native) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (true) {
    // A paused open can acknowledge readiness before mpv has a clock value.
    // Wait for that value instead of treating an unavailable position as zero.
    final seconds = double.tryParse(await native.getProperty('time-pos'));
    if (seconds != null && seconds.isFinite) {
      return seconds * Duration.millisecondsPerSecond;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('Native playback position did not become available');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native playback condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _HeldFixture {
  final SendPort commands;
  final String uri;
  final int size;
  _HeldFixture(this.commands, this.uri, this.size);

  static Future<_HeldFixture> start(String path) async {
    final ready = ReceivePort();
    await Isolate.spawn(_serve, (ready.sendPort, path));
    final message = await ready.first as (SendPort, String, int);
    ready.close();
    return _HeldFixture(message.$1, message.$2, message.$3);
  }

  Future<Map<String, Object?>> command(String method) async {
    final reply = ReceivePort();
    commands.send((method, reply.sendPort));
    final result = await reply.first as Map<String, Object?>;
    reply.close();
    return result;
  }
}

Future<void> _serve((SendPort, String) configuration) async {
  final file = File(configuration.$2);
  final size = await file.length();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final commands = ReceivePort();
  Completer<void>? release;
  var heads = 0;
  commands.listen((dynamic message) async {
    final (method, reply) = message as (String, SendPort);
    if (method == 'hold') {
      release = Completer<void>();
      heads = 0;
    }
    if ((method == 'release' || method == 'close') &&
        release != null &&
        !release!.isCompleted) {
      release!.complete();
    }
    if (method == 'close') {
      await server.close(force: true);
      commands.close();
    }
    reply.send(<String, Object?>{'heads': heads});
  });
  server.listen((request) async {
    try {
      if (request.method == 'HEAD') {
        heads++;
        await release?.future;
      }
      final response = request.response;
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
      // A canceled read-ahead request may close before the fixture is sent.
    } on SocketException {
      // Session teardown closes the range bridge and its sockets.
    }
  });
  configuration.$1.send((
    commands.sendPort,
    'http://127.0.0.1:${server.port}',
    size,
  ));
}
