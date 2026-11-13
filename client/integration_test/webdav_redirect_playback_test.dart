import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Native decode/seek regression using a local H.264 fixture at least 15s long.
// xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 flutter test --no-pub -d linux
// integration_test/webdav_redirect_playback_test.dart
// --dart-define=MEDIA_FIXTURE=/absolute/path/to/fixture.mp4
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native player decodes and seeks through WebDAV 302 to a CDN', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    final file = File(
      const String.fromEnvironment(
        'MEDIA_FIXTURE',
        defaultValue: '/tmp/aiplayer-redirect-fixture.mp4',
      ),
    );
    final size = await file.length();
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authorization = 'Basic ${base64Encode(utf8.encode('user:password'))}';
    final methods = <String>[];
    final ranges = <int>[];
    origin.listen((request) async {
      expect(request.headers.value('authorization'), authorization);
      expect(request.uri.pathSegments, ['dav', '视频.mp4']);
      methods.add(request.method);
      request.response.statusCode = 302;
      request.response.headers.set(
        'Location',
        'http://127.0.0.1:${cdn.port}/download?signature=a%2Bb%2Fc',
      );
      await request.response.close();
    });
    cdn.listen((request) async {
      expect(request.headers.value('authorization'), isNull);
      expect(request.uri.query, 'signature=a%2Bb%2Fc');
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.contentLength = size;
      if (request.method == 'GET') {
        final range = ByteRange.parse(request.headers.value('range'), size)!;
        ranges.add(range.start);
        request.response.statusCode = 206;
        request.response.contentLength = range.length;
        request.response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/$size',
        );
        try {
          await request.response.addStream(
            file.openRead(range.start, range.end + 1),
          );
        } on HttpException {
          // The decoder may abandon an old range when seeking.
        } on SocketException {
          // The decoder may close a connection before reading its full range.
        }
      }
      await request.response.close();
    });
    final source = HttpSource(
      'http://127.0.0.1:${origin.port}/dav/',
      webdav: true,
      user: 'user',
      password: 'password',
    );
    final player = Player();
    final video = VideoController(player);
    RangeBridge? bridge;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Video(controller: video)),
        ),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('hwdec', 'no');
      bridge = await RangeBridge.open(source, '视频.mp4');
      await player.open(Media(bridge.uri.toString()), play: false);
      await video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 20),
      );
      await _until(() => player.state.duration.inSeconds >= 15);
      await player.play();
      await _until(() => player.state.position.inMilliseconds >= 500);
      await player.seek(const Duration(seconds: 10));
      await _until(() => player.state.position.inMilliseconds >= 10000);
      await player.pause();
      await _until(() async => await native.getProperty('pause') == 'yes');
      final pausedAt = double.parse(await native.getProperty('time-pos'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await native.getProperty('pause'), 'yes');
      expect(
        double.parse(await native.getProperty('time-pos')),
        closeTo(pausedAt, .05),
      );
      expect(methods, containsAll(['HEAD', 'GET']));
      expect(ranges, isNotEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await player.dispose();
      await bridge?.close();
      await source.close();
      await origin.close(force: true);
      await cdn.close(force: true);
    }
  });
}

Future<void> _until(FutureOr<bool> Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!await ready()) {
    if (elapsed.elapsed > const Duration(seconds: 15)) {
      fail('Timed out waiting for native playback');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
