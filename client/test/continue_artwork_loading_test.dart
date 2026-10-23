import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/continue_watching_presentation.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _HistoryModel extends AppModel {
  _HistoryModel(super.store, super.documents) : super(backgroundWork: false);

  final previews = <String>{};
  final previewRequests = <String>[];
  int presentationReads = 0;

  @override
  Future<Map<String, ContinueWatchingPresentation>>
  loadContinueWatchingPresentations(
    List<SyncRecord> items, {
    CancelToken? cancel,
  }) {
    presentationReads++;
    return super.loadContinueWatchingPresentations(items, cancel: cancel);
  }

  @override
  void ensureMediaPreview(String id) {
    previews.add(id);
    previewRequests.add(id);
  }
}

class _CountingStore extends AppStore {
  _CountingStore(super.path);
  int recordReads = 0, localReads = 0;

  @override
  SyncRecord? get(String kind, String id) {
    recordReads++;
    return super.get(kind, id);
  }

  @override
  dynamic local(String key) {
    localReads++;
    return super.local(key);
  }
}

Finder _card(String id) =>
    find.byKey(ValueKey('history:$id'), skipOffstage: false);

Finder _cover(String id) => find.descendant(
  of: _card(id),
  matching: find.byType(MediaArtwork, skipOffstage: false),
  skipOffstage: false,
);

bool _decoded(Finder cover) => find
    .descendant(
      of: cover,
      matching: find.byType(RawImage, skipOffstage: false),
      skipOffstage: false,
    )
    .evaluate()
    .any((element) => (element.widget as RawImage).image != null);

ScrollPosition _position(WidgetTester tester, Finder list) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: list,
            matching: find.byType(Scrollable, skipOffstage: false),
            skipOffstage: false,
          )
          .first,
    )
    .position;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String failure,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail(failure);
}

void main() {
  late Directory directory;
  late _CountingStore store;
  late _HistoryModel model;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    directory = await Directory.systemTemp.createTemp('continue-artwork-');
    store = _CountingStore('${directory.path}/library.db')
      ..setLocal('settings', {
        'metadataStrategy': 'off',
        'autoDiscover': false,
        'hideNavigationOnScroll': false,
      });
    model = _HistoryModel(store, directory);
  });

  tearDown(() async {
    model.dispose();
    await model.sync.dispose();
    store.dispose();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    int mediaCount = 10,
    bool desktop = false,
  }) async {
    await tester.runAsync(() async {
      for (var index = 1; index <= mediaCount; index++) {
        final name = 'Series ${index.toString().padLeft(2, '0')}';
        store.save('media', '$index', {
          'title': '$name.mp4',
          'fileName': '$name.mp4',
          'series': name,
          'bangumiId': '$index',
          'metadataTitle': name,
          'duration': 120,
        });
        final videoPath = '/videos/$name.mp4';
        store.setLocal('location:$index', {
          'id': '$index',
          'source': 'local',
          'path': videoPath,
          'size': 1024,
        });
        if (index <= 10) {
          store.save(
            'progress',
            model.progressKey(store.get('media', '$index')!),
            {
              'position': 30,
              'duration': 120,
              'updatedAt': DateTime.utc(
                2026,
                10,
                23,
                0,
                index,
              ).toIso8601String(),
            },
          );
        }
        final image = images.Image(width: 96, height: 64);
        images.fill(image, color: images.ColorRgb8(index * 20, 80, 120));
        final file = File('${directory.path}/$index.png');
        await file.writeAsBytes(images.encodePng(image));
        final request = MediaPreviewRequest(
          '$index',
          'local',
          videoPath,
          1024,
          position: 30,
        );
        store.setLocal('preview:$index', {
          'path': file.path,
          'formatVersion': MediaPreview.formatVersion,
          'fingerprint': request.fingerprint,
          'contentFingerprint': request.contentFingerprint,
        });
      }
    });
    tester.view.physicalSize = desktop
        ? const Size(1100, 640)
        : const Size(390, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      // Let non-cancellable native decodes release the shared queue before
      // this test's fake-async zone ends.
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme().copyWith(
          platform: desktop ? TargetPlatform.linux : TargetPlatform.android,
        ),
        home: LibraryPage(model: model),
      ),
    );
    await _waitFor(
      tester,
      () => _decoded(_cover('10')),
      'The initial continue-watching cover did not decode.',
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'continue watching decodes adjacent covers during dragging before entry',
    (tester) async {
      await mount(tester);
      final carousel = find.byKey(
        const PageStorageKey('library-continue-scroll'),
      );
      final viewport = tester.getRect(carousel);
      expect(tester.getRect(_cover('8')).left, greaterThan(viewport.right));
      await _waitFor(
        tester,
        () => _decoded(_cover('8')),
        'The next horizontal cover must decode before becoming visible.',
      );
      expect(model.previews, isNot(contains('8')));
      expect(_card('7'), findsNothing);

      store.recordReads = store.localReads = 0;
      final gesture = await tester.startGesture(tester.getCenter(carousel));
      await gesture.moveBy(const Offset(-20, 0));
      await gesture.moveBy(const Offset(-380, 0));
      await tester.pump();
      expect(tester.getRect(_cover('8')).overlaps(viewport), isTrue);
      expect(_decoded(_cover('8')), isTrue);
      expect(model.previews, isNot(contains('8')));
      expect(tester.getRect(_cover('7')).left, greaterThan(viewport.right));
      await _waitFor(
        tester,
        () => _decoded(_cover('7')),
        'A newly adjacent cover must decode while the drag remains active.',
      );
      expect(model.previews, isNot(contains('7')));

      await gesture.moveBy(const Offset(-300, 0));
      await tester.pump();
      expect(tester.getRect(_cover('7')).overlaps(viewport), isTrue);
      expect(_decoded(_cover('7')), isTrue);
      expect(model.previews, isNot(contains('7')));
      expect(
        store.recordReads,
        0,
        reason:
            'Building newly prefetched cards must not query UI-isolate SQLite.',
      );
      expect(store.localReads, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.previews, contains('7'));

      _position(tester, carousel).jumpTo(0);
      await tester.pump();
      expect(
        _decoded(_cover('10')),
        isTrue,
        reason: 'Reverse scrolling reuses decoded pixels on its first frame.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning vertically to continue watching keeps decoded covers on its first frame',
    (tester) async {
      await mount(tester, mediaCount: 40);
      final carousel = find.byKey(
        const PageStorageKey('library-continue-scroll'),
        skipOffstage: false,
      );
      _position(tester, carousel).jumpTo(316);
      await tester.pumpAndSettle();
      await _waitFor(
        tester,
        () => _decoded(_cover('9')),
        'The saved horizontal position must have a decoded cover before leaving.',
      );
      final library = find.byKey(const PageStorageKey('library-scroll'));
      final vertical = _position(tester, library);
      final gesture = await tester.startGesture(
        tester.getRect(library).bottomCenter - const Offset(0, 100),
      );
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -3000));
      await tester.pump();
      expect(vertical.pixels, greaterThan(1000));
      final previews = model.previews.toSet();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(model.previews, previews);
      // Scrolling a large wall can evict ordinary cached images. The retained
      // carousel must keep the pixels it is displaying, independently of LRU.
      PaintingBinding.instance.imageCache.clear();

      await gesture.moveBy(const Offset(0, 3000));
      await tester.pump();
      expect(vertical.pixels, 0);
      expect(vertical.isScrollingNotifier.value, isTrue);
      expect(_position(tester, carousel).pixels, 316);
      expect(
        _decoded(_cover('9')),
        isTrue,
        reason:
            'A previously visible cover must remain decoded on the first '
            'return frame while the vertical drag is still active.',
      );
      // The first return also lazily rebuilds unrelated wall cards. Measure
      // the retained carousel's subsequent scroll pulse independently of that.
      store.recordReads = store.localReads = 0;
      await tester.pump(const Duration(milliseconds: 80));
      expect(store.recordReads, 0);
      expect(store.localReads, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'vertically hidden continue watching coalesces updates until visible and idle',
    (tester) async {
      await mount(tester, mediaCount: 40);
      final carousel = find.byKey(
        const PageStorageKey('library-continue-scroll'),
        skipOffstage: false,
      );
      _position(tester, carousel).jumpTo(316);
      await tester.pumpAndSettle();
      await _waitFor(
        tester,
        () => _decoded(_cover('9')),
        'The current cover must decode before leaving the carousel.',
      );
      final library = find.byKey(const PageStorageKey('library-scroll'));
      final vertical = _position(tester, library);
      vertical.jumpTo(vertical.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      expect(vertical.pixels, greaterThan(1000));
      expect(vertical.isScrollingNotifier.value, isFalse);
      final reads = model.presentationReads;
      final previews = model.previews.toSet();
      for (var index = 0; index < 20; index++) {
        store.setLocal('episodeTitle:9', 'Updated episode $index');
        model.changed();
        await tester.pump();
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(model.presentationReads, reads);
      expect(model.previews, previews);
      PaintingBinding.instance.imageCache.clear();

      final gesture = await tester.startGesture(
        tester.getRect(library).bottomCenter - const Offset(0, 100),
      );
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(const Offset(0, 3000));
      await tester.pump();
      expect(vertical.pixels, 0);
      expect(vertical.isScrollingNotifier.value, isTrue);
      expect(_position(tester, carousel).pixels, 316);
      expect(_decoded(_cover('9')), isTrue);
      expect(model.presentationReads, reads);
      store.recordReads = store.localReads = 0;
      await tester.pump(const Duration(milliseconds: 80));
      expect(model.presentationReads, reads);
      expect(store.recordReads, 0);
      expect(store.localReads, 0);

      await gesture.up();
      await tester.pumpAndSettle();
      await _waitFor(
        tester,
        () => find
            .descendant(
              of: _card('9'),
              matching: find.text('Updated episode 19'),
            )
            .evaluate()
            .isNotEmpty,
        'Visible idle history must refresh to the latest offscreen revision.',
      );
      expect(model.presentationReads, reads + 1);
      expect(_decoded(_cover('9')), isTrue);
      expect(_position(tester, carousel).pixels, 316);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop scanning status preserves the offscreen continue watching subtree',
    (tester) async {
      await mount(tester, mediaCount: 80, desktop: true);
      final content = find.byKey(
        const ValueKey('library-continue-content'),
        skipOffstage: false,
      );
      final carousel = find.byKey(
        const PageStorageKey('library-continue-scroll'),
        skipOffstage: false,
      );
      _position(tester, carousel).jumpTo(350);
      await tester.pumpAndSettle();
      await _waitFor(
        tester,
        () => _decoded(_cover('9')),
        'The desktop carousel must have a decoded cover before leaving.',
      );
      final contentState = tester.state(content);
      final coverState = tester.state(_cover('9'));
      final library = find.byKey(const PageStorageKey('library-scroll'));
      final vertical = _position(tester, library);
      vertical.jumpTo(vertical.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      expect(vertical.pixels, greaterThan(1000));
      final reads = model.presentationReads;
      List<String> historyPreviewRequests() => model.previewRequests
          .where((id) => int.parse(id) <= 10)
          .toList(growable: false);
      final previews = historyPreviewRequests();

      // On desktop the scanning strip inserts/removes siblings before the
      // retained sliver child. Its identity must not depend on child index.
      for (final scanning in [true, false, true, false]) {
        model.scanning = scanning;
        model.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(contentState.mounted, isTrue);
        expect(tester.state(content), same(contentState));
        expect(tester.state(_cover('9')), same(coverState));
        expect(_position(tester, carousel).pixels, 350);
        expect(model.presentationReads, reads);
        expect(historyPreviewRequests(), previews);
      }
      PaintingBinding.instance.imageCache.clear();

      final gesture = await tester.startGesture(
        tester.getRect(library).bottomCenter - const Offset(0, 100),
      );
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(Offset(0, vertical.pixels + 30));
      await tester.pump();
      expect(vertical.pixels, 0);
      expect(vertical.isScrollingNotifier.value, isTrue);
      expect(tester.state(content), same(contentState));
      expect(tester.state(_cover('9')), same(coverState));
      expect(_position(tester, carousel).pixels, 350);
      expect(_decoded(_cover('9')), isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden continue watching pauses and resumes at its saved offset',
    (tester) async {
      await mount(tester);
      final carousel = find.byKey(
        const PageStorageKey('library-continue-scroll'),
        skipOffstage: false,
      );
      final position = _position(tester, carousel);
      await tester.tap(find.byKey(const ValueKey('nav-item-1')));
      await tester.pumpAndSettle();
      final previews = model.previews.toSet();
      position.jumpTo(1900);
      await tester.pump();
      expect(_cover('4'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(_decoded(_cover('4')), isFalse);
      expect(model.previews, previews);

      await tester.tap(find.byKey(const ValueKey('nav-item-0')));
      await tester.pumpAndSettle();
      await _waitFor(
        tester,
        () => _decoded(_cover('4')),
        'Returning to the library must resume cold continue-watching covers.',
      );
      expect(position.pixels, 1900);
      expect(model.previews, contains('4'));
      position.jumpTo(0);
      await tester.pump();
      expect(_decoded(_cover('10')), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('expanded watching history prepares the next row before entry', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('继续观看'));
    await tester.pumpAndSettle();
    final grid = find.byKey(const PageStorageKey('library-history-grid'));
    final viewport = tester.getRect(grid);
    final covers = find.descendant(
      of: grid,
      matching: find.byType(MediaArtwork, skipOffstage: false),
      skipOffstage: false,
    );
    final next = covers.evaluate().firstWhere(
      (element) =>
          tester
              .getRect(find.byWidget(element.widget, skipOffstage: false))
              .top >=
          viewport.bottom,
    );
    final cover = find.byWidget(next.widget, skipOffstage: false);
    await _waitFor(
      tester,
      () => _decoded(cover),
      'The next history row must decode before entering the viewport.',
    );
    final position = _position(tester, grid);
    position.jumpTo(tester.getRect(cover).top - viewport.bottom + 80);
    await tester.pump();
    expect(tester.getRect(cover).overlaps(viewport), isTrue);
    expect(_decoded(cover), isTrue);
    expect(tester.takeException(), isNull);
  });
}
