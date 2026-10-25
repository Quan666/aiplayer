import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PendingPosterCache extends PosterCache {
  _PendingPosterCache() : super(directory: Directory.systemTemp);

  final posters = <String, Completer<File?>>{};

  @override
  Future<File?> load(String url) =>
      posters.putIfAbsent(url, Completer<File?>.new).future;
}

void main() {
  late _PendingPosterCache cache;

  setUp(() {
    cache = _PendingPosterCache();
  });

  tearDown(() {
    cache.close();
  });

  testWidgets('visible idle work ignores posters and retries only a revision', (
    tester,
  ) async {
    var calls = 0, previews = 0;
    Widget view(int revision) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 100,
          height: 100,
          child: MediaArtwork(
            poster: 'poster',
            cache: cache,
            visibleIdleRevision: revision,
            onVisibleIdle: () => calls++,
            onRequestPreview: () => previews++,
          ),
        ),
      ),
    );

    await tester.pumpWidget(view(0));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(previews, 0);
    for (var index = 0; index < 3; index++) {
      await tester.pumpWidget(view(0));
      await tester.pumpAndSettle();
    }
    expect(calls, 1);
    await tester.pumpWidget(view(1));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(previews, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retained offscreen artwork waits until visible and idle', (
    tester,
  ) async {
    final controller = ScrollController();
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkScrollScope(
          child: SingleChildScrollView(
            controller: controller,
            child: Column(
              children: [
                const SizedBox(height: 750),
                SizedBox(
                  width: 100,
                  height: 100,
                  child: MediaArtwork(
                    poster: 'nearby',
                    cache: cache,
                    loadWhileScrolling: true,
                    visibleIdleRevision: 0,
                    onVisibleIdle: () => calls.add('visible'),
                  ),
                ),
                const SizedBox(height: 750),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    controller.jumpTo(500);
    await tester.pumpAndSettle();
    expect(calls, ['visible']);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, ['visible']);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('paused without frames keeps deferred work pending for resume', (
    tester,
  ) async {
    var calls = 0;
    Widget view(int revision) => MaterialApp(
      home: ArtworkScrollScope(
        child: SingleChildScrollView(
          child: Column(
            children: [
              SizedBox(
                width: 100,
                height: 150,
                child: MediaArtwork(
                  poster: 'poster',
                  cache: cache,
                  visibleIdleRevision: revision,
                  onVisibleIdle: () => calls++,
                ),
              ),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(view(0));
    await tester.pumpAndSettle();
    expect(calls, 1);
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await tester.pumpWidget(view(1));
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    cache.posters['poster']!.complete(null);
    await gesture.up();
    await tester.idle();
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('initial background state waits for lifecycle resume', (
    tester,
  ) async {
    var calls = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: MediaArtwork(onVisibleIdle: () => calls++),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
