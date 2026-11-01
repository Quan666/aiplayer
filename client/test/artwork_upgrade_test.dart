import 'dart:io';

import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _UpgradeCache extends PosterCache {
  _UpgradeCache({this.file}) : super(directory: Directory.systemTemp);

  File? file;
  final updates = ValueNotifier<PosterCacheChange?>(null);
  final allowed = <String, bool Function()?>{};

  @override
  ValueListenable<PosterCacheChange?> get changes => updates;

  @override
  File? resolvedFile(String url) => file;

  @override
  Future<File?>? loadVisible(String url, {bool Function()? canStart}) {
    allowed[url] = canStart;
    return SynchronousFuture(file);
  }

  void upgrade(String url, File replacement) {
    file = replacement;
    updates.value = PosterCacheChange(url, replacement);
  }

  @override
  void close() {
    updates.dispose();
    super.close();
  }
}

Future<(String, String)> _fixtures(String directory) async {
  final fallback = File('$directory/portable.image');
  final source = File('$directory/online.source.image');
  await fallback.writeAsBytes(
    images.encodePng(images.Image(width: 120, height: 180)),
  );
  await source.writeAsBytes(
    images.encodePng(images.Image(width: 1200, height: 1800)),
  );
  return (fallback.path, source.path);
}

Iterable<RawImage> _pixels(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .where((image) => image.image != null);

void main() {
  testWidgets('source upgrade retains portable pixels throughout cold decode', (
    tester,
  ) async {
    const poster = 'https://example.com/upgraded-poster.png';
    late Directory directory;
    late File fallback, source;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('poster-upgrade-');
      final paths = await compute(_fixtures, directory.path);
      fallback = File(paths.$1);
      source = File(paths.$2);
    });
    final cache = _UpgradeCache(file: fallback);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 3),
            child: Center(
              child: SizedBox(
                width: 180,
                height: 270,
                child: MediaArtwork(
                  poster: poster,
                  cache: cache,
                  loadWhileScrolling: true,
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 60 && _pixels(tester).isEmpty; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(_pixels(tester), hasLength(1));
      expect(_pixels(tester).single.image!.height, 180);
      cache.upgrade(poster, source);
      var upgraded = false;
      for (var i = 0; i < 60; i++) {
        await tester.pump();
        final visible = _pixels(tester).toList();
        expect(
          visible,
          isNotEmpty,
          reason:
              'A source update must not replace a decoded poster with a placeholder.',
        );
        if (visible.any((raw) => raw.image!.height >= 810)) {
          upgraded = true;
          break;
        }
        expect(visible.any((raw) => raw.image!.height == 180), isTrue);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(upgraded, isTrue);
      expect(_pixels(tester).last.image!.width, greaterThanOrEqualTo(540));
    } finally {
      await tester.pumpWidget(const SizedBox());
      cache.close();
      PaintingBinding.instance.imageCache.clear();
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets(
    'visible source permission follows route, lifecycle and identity',
    (tester) async {
      final cache = _UpgradeCache();
      final navigator = GlobalKey<NavigatorState>();
      Widget cover(String poster) => MaterialApp(
        navigatorKey: navigator,
        home: Center(
          child: SizedBox(
            width: 100,
            height: 150,
            child: MediaArtwork(
              poster: poster,
              cache: cache,
              loadWhileScrolling: true,
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(cover('old-poster'));
        await tester.pumpAndSettle();
        final oldAllowed = cache.allowed['old-poster'];
        expect(oldAllowed, isNotNull);
        expect(oldAllowed!(), isTrue);
        navigator.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold()),
        );
        await tester.pumpAndSettle();
        expect(oldAllowed(), isFalse);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(oldAllowed(), isTrue);

        // Android may stop producing frames immediately after this signal.
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(oldAllowed(), isFalse);
        await tester.idle();
        expect(oldAllowed(), isFalse);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(oldAllowed(), isTrue);

        await tester.pumpWidget(cover('new-poster'));
        await tester.pumpAndSettle();
        expect(oldAllowed(), isFalse);
        final newAllowed = cache.allowed['new-poster'];
        expect(newAllowed, isNotNull);
        expect(newAllowed!(), isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(newAllowed(), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        cache.close();
      }
    },
  );
}
