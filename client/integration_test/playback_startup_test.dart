import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('first open and switching between local and LAN HTTP video', (
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
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
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
      try {
        if (request.method != 'HEAD') {
          await response.addStream(
            fixture.openRead(range.start, range.end + 1),
          );
        }
        await response.close();
      } on HttpException {
        // A decoder cancels its read-ahead when switching to the next file.
      } on SocketException {
        // Same cancellation on platforms reporting a closed socket instead.
      }
    });
    final root = await Directory.systemTemp.createTemp('aiplayer-startup-');
    final model = AppModel(
      AppStore('${root.path}/test.db'),
      root,
      enableThumbnails: false,
    );
    await model.updatePreferences({
      'enterFullscreen': false,
      'hardwareDecoding': false,
      'metadataStrategy': 'off',
      'autoPlay': true,
    });
    final localId = await model.importFile(fixture.path);
    model.store.setLocal('sources', [
      {
        'id': 'lan',
        'kind': 'http',
        'url': 'http://127.0.0.1:${server.port}/video.mkv',
      },
    ]);
    final networkId = model.addMedia(
      'lan',
      SourceEntry(name: 'LAN video.mkv', path: '', size: size),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await PlayerPage.waitForDisposals();
      await model.flushPlaybackPreviews();
      await server.close(force: true);
      model.dispose();
      model.store.dispose();
      await root.delete(recursive: true);
    });
    final clock = Stopwatch()..start();
    final controller = PlayerPageController();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          model: model,
          media: model.store.get('media', localId)!,
          controller: controller,
        ),
      ),
    );
    final page = tester.state(find.byType(PlayerPage)) as dynamic;
    Future<void> awaitFrame(String name) async {
      final session = page.session as PlaybackSession;
      await (session.player.platform as NativePlayer).setProperty('ao', 'null');
      for (var i = 0; i < 200 && !session.firstFrameRendered; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(session.error, isEmpty);
      expect(session.firstFrameRendered, isTrue);
      expect(session.video.rect.value!.width, greaterThan(1));
      expect(session.video.rect.value!.height, greaterThan(1));
      // Report timings without an environment-dependent performance deadline.
      debugPrint('$name first frame: ${clock.elapsedMilliseconds} ms');
      expect(find.byKey(const ValueKey('player-buffering')), findsNothing);
    }

    await awaitFrame('local open');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('播放器设置'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('player-settings-popup')), findsOneWidget);
    await tester.tapAt(const Offset(20, 200), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byTooltip('锁定控件'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('解除锁定'), findsOneWidget);
    expect(find.byTooltip('播放器设置').hitTestable(), findsNothing);
    await tester.tap(find.byTooltip('解除锁定'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('播放器设置').hitTestable(), findsOneWidget);

    for (final (name, id) in [
      ('LAN switch', networkId),
      ('local switch', localId),
    ]) {
      final previous = page.session as PlaybackSession;
      clock.reset();
      final previousVideo = tester.element(find.byType(Video));
      final switching = controller.selectMedia(model.store.get('media', id)!);
      for (var i = 0; i < 100 && identical(page.session, previous); i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      // A paused native texture keeps the exact outgoing frame and aspect.
      expect(find.byType(Video), findsNWidgets(2));
      expect(find.byType(Video).evaluate(), contains(previousVideo));
      expect(previous.closed, isFalse);
      expect(previous.player.state.playing, isFalse);
      await awaitFrame(name);
      await tester.pump();
      await tester.pump();
      expect(await switching, isTrue);
      expect(previous.closed, isTrue);
      final session = page.session as PlaybackSession;
      final before = session.player.state.position;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.player.state.position, greaterThan(before));
    }
  });
}
