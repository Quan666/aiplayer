import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/third_party_network.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'enabling third-party networking resumes cold covers without removing resident pixels',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final policy = ThirdPartyNetworkPolicy(enabled: false);
      late Directory directory;
      late HttpServer server;
      late PosterCache cache;
      final responseGate = Completer<void>();
      var requests = 0;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'poster-policy-artwork-',
        );
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final png = await File('assets/branding/app_icon.png').readAsBytes();
        server.listen((request) async {
          requests++;
          await responseGate.future;
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(png);
          await request.response.close();
        });
        cache = PosterCache(
          directory: directory,
          networkPolicy: policy,
          createClient: () =>
              HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp()),
        );
        await cache
            .cachedFile('http://127.0.0.1:${server.port}/warm')
            .writeAsBytes(png);
      });
      final warm = 'http://127.0.0.1:${server.port}/warm';
      final cold = 'http://127.0.0.1:${server.port}/cold';
      Finder artwork(String key, Type type) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(type),
      );
      Future<void> tick() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }

      bool painted(String key) => tester
          .widgetList<RawImage>(artwork(key, RawImage))
          .any((raw) => raw.image != null);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (key, url) in [('warm', warm), ('cold', cold)])
                    SizedBox(
                      width: 128,
                      height: 128,
                      child: MediaArtwork(
                        key: ValueKey(key),
                        poster: url,
                        cache: cache,
                        loadWhileScrolling: true,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        for (var i = 0; i < 150 && !painted('warm'); i++) {
          await tick();
        }
        expect(painted('warm'), isTrue);
        expect(painted('cold'), isFalse);
        expect(requests, 0);
        final element = tester.element(artwork('warm', Image));
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        policy.setEnabled(true);
        for (var i = 0; i < 150 && requests < 2; i++) {
          await tick();
          expect(painted('warm'), isTrue);
          expect(tester.element(artwork('warm', Image)), same(element));
        }
        expect(requests, 2);
        responseGate.complete();
        for (var i = 0; i < 150 && !painted('cold'); i++) {
          await tick();
          expect(painted('warm'), isTrue);
          expect(tester.element(artwork('warm', Image)), same(element));
        }
        expect(painted('cold'), isTrue);
        policy.setEnabled(false);
        await tester.pump();
        expect(painted('warm'), isTrue);
        expect(painted('cold'), isTrue);
        expect(tester.element(artwork('warm', Image)), same(element));
        expect(tester.takeException(), isNull);
      } finally {
        if (!responseGate.isCompleted) responseGate.complete();
        await tester.pumpWidget(const SizedBox());
        cache.close();
        policy.dispose();
        await tester.runAsync(() async {
          await server.close(force: true);
          await directory.delete(recursive: true);
        });
      }
    },
  );
}
