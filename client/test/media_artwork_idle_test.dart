import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _ControlledPosterCache extends PosterCache {
  _ControlledPosterCache() : super(directory: Directory.systemTemp);

  final results = <String, Completer<File?>>{};
  final failures = <String>{};
  final available = ChangeNotifier();
  bool full = false;

  @override
  Listenable get capacity => available;

  @override
  bool hasFailed(String url) => failures.contains(url);

  @override
  Future<File?>? loadVisible(String url) => full ? null : load(url);

  @override
  Future<File?> load(String url) =>
      results.putIfAbsent(url, Completer<File?>.new).future;

  void finish(String url, {File? file, bool failed = false}) {
    if (failed) failures.add(url);
    results[url]!.complete(file);
  }

  @override
  void close() {
    available.dispose();
    super.close();
  }
}

class _BrokenPosterCache extends PosterCache {
  _BrokenPosterCache(this.file) : super(directory: Directory.systemTemp);

  final File file;
  int repairs = 0;

  @override
  Future<File?> load(String url) => SynchronousFuture(file);

  @override
  Future<void> invalidate(
    String url, {
    File? failedFile,
    bool retryImmediately = false,
  }) async {
    repairs++;
  }
}

void main() {
  late Directory directory;
  late File cover;
  late _ControlledPosterCache cache;
  late List<String> previews;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('artwork-idle-');
    cover = File('${directory.path}/cover.png');
    await cover.writeAsBytes(
      images.encodePng(images.Image(width: 24, height: 12)),
    );
    cache = _ControlledPosterCache();
    previews = [];
  });

  tearDown(() async {
    cache.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await directory.delete(recursive: true);
  });

  Widget artwork({String poster = 'poster', String? thumbnail}) => MaterialApp(
    home: Center(
      child: SizedBox(
        width: 100,
        height: 150,
        child: MediaArtwork(
          poster: poster,
          thumbnail: thumbnail,
          cache: cache,
          onRequestPreview: () => previews.add(poster),
        ),
      ),
    ),
  );

  testWidgets('pending and usable posters never start video decoding', (
    tester,
  ) async {
    await tester.pumpWidget(artwork());
    await tester.pumpAndSettle();
    expect(cache.results.keys, ['poster']);
    expect(previews, isEmpty);
    cache.finish('poster', file: cover);
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(artwork());
      await tester.pumpAndSettle();
    }
    expect(previews, isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('full and deferred poster queues never start video decoding', (
    tester,
  ) async {
    cache.full = true;
    await tester.pumpWidget(artwork());
    await tester.pumpAndSettle();
    expect(cache.results, isEmpty);
    expect(previews, isEmpty);
    cache.full = false;
    cache.available.notifyListeners();
    await tester.pumpAndSettle();
    cache.finish('poster');
    await tester.pumpAndSettle();
    expect(previews, isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('actual poster failure requests one visible video fallback', (
    tester,
  ) async {
    await tester.pumpWidget(artwork());
    await tester.pumpAndSettle();
    cache.finish('poster', failed: true);
    await tester.pumpAndSettle();
    expect(previews, ['poster']);
    await tester.pump(const Duration(minutes: 1));
    expect(previews, ['poster']);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late poster failure stays silent while paused without frames', (
    tester,
  ) async {
    await tester.pumpWidget(artwork());
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    cache.finish('poster', failed: true);
    await tester.idle();
    expect(previews, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(previews, ['poster']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late replaced poster failure cannot start video fallback', (
    tester,
  ) async {
    await tester.pumpWidget(artwork(poster: 'old'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(artwork(poster: 'current'));
    await tester.pumpAndSettle();
    cache.finish('old', failed: true);
    await tester.pumpAndSettle();
    expect(previews, isEmpty);
    cache.finish('current', file: cover);
    await tester.pumpAndSettle();
    expect(previews, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final loadWhileScrolling in [false, true]) {
    testWidgets(
      'an unrepaired poster requests fallback and stops waking frames (scroll loading: $loadWhileScrolling)',
      (tester) async {
        await tester.runAsync(() => cover.writeAsString('broken image'));
        final broken = _BrokenPosterCache(cover);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox(
                  width: 100,
                  height: 150,
                  child: MediaArtwork(
                    poster: 'broken',
                    cache: broken,
                    loadWhileScrolling: loadWhileScrolling,
                    onRequestPreview: () => previews.add('broken'),
                  ),
                ),
              ),
            ),
          );
          for (var attempt = 0; attempt < 30 && previews.isEmpty; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(broken.repairs, 1);
          expect(previews, ['broken']);
          await tester.pumpAndSettle();
          expect(previews, ['broken']);
          expect(tester.binding.hasScheduledFrame, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          broken.close();
        }
      },
    );
  }

  testWidgets(
    'video-only artwork still checks its thumbnail for content changes',
    (tester) async {
      await tester.pumpWidget(artwork(poster: '', thumbnail: cover.path));
      await tester.pumpAndSettle();
      expect(previews, ['']);
      await tester.pumpWidget(artwork(poster: ''));
      await tester.pumpAndSettle();
      expect(previews, ['', '']);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
