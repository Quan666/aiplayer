import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late AppStore store;
  late _CountingModel model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('aiplayer-scroll-perf-');
    store = AppStore(
      ':memory:',
    )..setLocal('settings', {'metadataStrategy': 'off', 'autoDiscover': false});
    model = _CountingModel(store, directory);
    for (var i = 0; i < 120; i++) {
      store.save('media', '$i', {
        'title': '视频 $i.mp4',
        'series': '未分类',
        'size': i,
      });
    }
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  testWidgets('scrolling changes navigation without rebuilding the library', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey('library-scroll'));
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    final extent = scroll.maxScrollExtent;
    model.mediaReads = 0;
    model.preferenceReads = 0;
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedSlide>(find.byKey(const ValueKey('navigation-slide')))
          .offset
          .dy,
      greaterThan(1),
    );
    expect(model.mediaReads, 0);
    expect(model.preferenceReads, 0);
    expect(scroll.maxScrollExtent, extent);
    await tester.drag(list, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AnimatedSlide>(find.byKey(const ValueKey('navigation-slide')))
          .offset,
      Offset.zero,
    );
    expect(model.mediaReads, 0);
    expect(scroll.maxScrollExtent, extent);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'data updates retain app themes and still refresh visible media',
    (tester) async {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      store.save('media', 'new', {'title': '新视频.mp4', 'series': '未分类'});
      for (var i = 0; i < 20; i++) {
        model.changed();
      }
      await tester.pumpAndSettle();
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
      expect(find.text('121'), findsOneWidget);
      model.setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      final dark = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(dark.themeMode, ThemeMode.dark);
      expect(dark.theme, same(app.theme));
      expect(dark.darkTheme, same(app.darkTheme));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final horizontal in [false, true]) {
    testWidgets(
      'background updates wait for ${horizontal ? 'carousel' : 'library'} scrolling to finish',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (horizontal) {
          for (var i = 0; i < 10; i++) {
            final record = store.get('media', '$i')!;
            store.save('progress', model.progressKey(record), {
              'position': 10,
              'updatedAt': '2026-10-22T00:00:00Z',
            });
          }
        }
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        final library = find.byKey(const PageStorageKey('library-scroll'));
        final target = horizontal
            ? find.byKey(const PageStorageKey('library-continue-scroll'))
            : library;
        final gesture = await tester.startGesture(tester.getCenter(target));
        await gesture.moveBy(
          horizontal ? const Offset(-80, 0) : const Offset(0, -80),
        );
        await tester.pump();
        final retained = tester.widget<CustomScrollView>(library);
        model.mediaReads = 0;
        store.save('media', 'new', {'title': '新视频.mp4', 'series': '未分类'});
        for (var i = 0; i < 5; i++) {
          model.changed();
          await tester.pump();
          expect(tester.widget<CustomScrollView>(library), same(retained));
        }
        expect(model.mediaReads, 0);
        await gesture.up();
        await tester.pumpAndSettle();
        // The shared idle grace also covers consecutive desktop wheel ticks.
        await tester.pump(const Duration(milliseconds: 140));
        await tester.pumpAndSettle();
        expect(model.mediaReads, 1);
        expect(tester.widget<CustomScrollView>(library), isNot(same(retained)));
        expect(find.text('121'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('nested scrolling waits for both animations before refreshing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 10; i++) {
      final record = store.get('media', '$i')!;
      store.save('progress', model.progressKey(record), {
        'position': 10,
        'updatedAt': '2026-10-22T00:00:00Z',
      });
    }
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    final library = find.byKey(const PageStorageKey('library-scroll'));
    final carousel = find.byKey(
      const PageStorageKey('library-continue-scroll'),
    );
    ScrollPosition position(Finder target) => tester
        .state<ScrollableState>(
          find.descendant(of: target, matching: find.byType(Scrollable)).first,
        )
        .position;
    final vertical = position(library), horizontal = position(carousel);
    final retained = tester.widget<CustomScrollView>(library);
    model.mediaReads = 0;
    unawaited(
      horizontal.animateTo(
        100,
        duration: const Duration(milliseconds: 300),
        curve: Curves.linear,
      ),
    );
    unawaited(
      vertical.animateTo(
        80,
        duration: const Duration(milliseconds: 900),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    expect(horizontal.isScrollingNotifier.value, isTrue);
    expect(vertical.isScrollingNotifier.value, isTrue);
    store.save('media', 'new', {'title': '新视频.mp4', 'series': '未分类'});
    model.changed();
    await tester.pump();
    expect(tester.widget<CustomScrollView>(library), same(retained));

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(horizontal.isScrollingNotifier.value, isFalse);
    expect(vertical.isScrollingNotifier.value, isTrue);
    expect(tester.widget<CustomScrollView>(library), same(retained));
    expect(model.mediaReads, 0);

    await tester.pumpAndSettle();
    expect(vertical.isScrollingNotifier.value, isFalse);
    await tester.pump(const Duration(milliseconds: 140));
    await tester.pumpAndSettle();
    expect(model.mediaReads, 1);
    expect(tester.widget<CustomScrollView>(library), isNot(same(retained)));
    expect(find.text('121'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending scroll updates wait while another tab is visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    final library = find.byKey(
      const PageStorageKey('library-scroll'),
      skipOffstage: false,
    );
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(of: library, matching: find.byType(Scrollable)).first,
        )
        .position;
    final retained = tester.widget<CustomScrollView>(library);
    model.mediaReads = 0;
    unawaited(
      scroll.animateTo(
        80,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    await tester.pump();
    expect(scroll.isScrollingNotifier.value, isTrue);
    store.save('media', 'new', {'title': '新视频.mp4', 'series': '未分类'});
    model.changed();
    await tester.pump();
    expect(tester.widget<CustomScrollView>(library), same(retained));

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(scroll.isScrollingNotifier.value, isFalse);
    expect(tester.widget<CustomScrollView>(library), same(retained));
    expect(model.mediaReads, 0);

    await tester.tap(find.text('影视库').last);
    await tester.pumpAndSettle();
    expect(model.mediaReads, 1);
    expect(tester.widget<CustomScrollView>(library), isNot(same(retained)));
    expect(find.text('121'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('press and drag cancellation reuse poster content', (
    tester,
  ) async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    final artwork = find.byType(MediaArtwork).first;
    final before = tester.widget<MediaArtwork>(artwork);
    final gesture = await tester.startGesture(tester.getCenter(artwork));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.widget<MediaArtwork>(artwork), same(before));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(tester.widget<MediaArtwork>(artwork), same(before));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'desktop wheel bursts coalesce background updates until idle',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      final library = find.byKey(const PageStorageKey('library-scroll'));
      final retained = tester.widget<CustomScrollView>(library);
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(of: library, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      model.mediaReads = 0;
      for (var i = 0; i < 5; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: tester.getCenter(library),
            scrollDelta: const Offset(0, 40),
          ),
        );
        // Native wheel positions are idle between ticks; the shared activity
        // scope must keep background work paused across the entire burst.
        expect(position.isScrollingNotifier.value, isFalse);
        store.save('media', 'new-$i', {'title': '新增 $i.mp4', 'series': '未分类'});
        model.changed();
        await tester.pump(const Duration(milliseconds: 30));
        expect(tester.widget<CustomScrollView>(library), same(retained));
        expect(model.mediaReads, 0);
      }
      expect(position.pixels, 200);
      await tester.pump(const Duration(milliseconds: 140));
      await tester.pumpAndSettle();
      expect(tester.widget<CustomScrollView>(library), isNot(same(retained)));
      expect(model.mediaReads, 1);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('125'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'desktop hover reuses poster content',
    (tester) async {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      final artwork = find.byType(MediaArtwork).first;
      final retained = tester.widget<MediaArtwork>(artwork);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(artwork));
      await tester.pumpAndSettle();
      expect(tester.widget<MediaArtwork>(artwork), same(retained));
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(tester.widget<MediaArtwork>(artwork), same(retained));
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  test('history sorting reads progress once per candidate', () {
    final items = model.media;
    for (var i = 0; i < items.length; i++) {
      store.save('progress', model.progressKey(items[i]), {
        'position': 10,
        'updatedAt': DateTime.utc(
          2026,
          1,
          1,
        ).add(Duration(minutes: i)).toIso8601String(),
      });
    }
    model.progressReads = 0;
    final recent = model.recentMedia(items: items, groupSeries: false);
    expect(
      recent.map((item) => item.id),
      items.reversed.map((item) => item.id),
    );
    expect(model.progressReads, items.length);
  });

  testWidgets('thumbnail and status updates reuse library groups and history', (
    tester,
  ) async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    model.mediaReads = model.historyReads = 0;
    for (var i = 0; i < 5; i++) {
      store.setLocal('preview:$i', {'path': '/unused/preview-$i.jpg'});
      model.changed();
      await tester.pump();
    }
    expect(model.mediaReads, 0);
    expect(model.historyReads, 0);

    final record = store.get('media', '0')!;
    store.save('progress', model.progressKey(record), {
      'position': 10,
      'updatedAt': '2026-10-22T00:00:00Z',
    });
    model.changed();
    await tester.pumpAndSettle();
    expect(model.mediaReads, 0);
    expect(model.historyReads, 1);
    expect(find.text('继续观看'), findsOneWidget);

    // A changed association changes the progress key even when no media or
    // progress row changed, so cached history must be invalidated as well.
    store.setLocal('location:0', {'size': 999});
    model.changed();
    await tester.pumpAndSettle();
    expect(model.historyReads, 2);
    expect(find.text('继续观看'), findsNothing);
    store.save('media', 'new', {'title': '新增.mp4', 'series': '未分类'});
    model.changed();
    await tester.pumpAndSettle();
    expect(model.mediaReads, 1);
    expect(find.text('121'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retained library stays idle while another tab is visible', (
    tester,
  ) async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final library = find.byKey(
      const PageStorageKey('library-scroll'),
      skipOffstage: false,
    );
    final retained = tester.widget<CustomScrollView>(library);
    store.save('media', 'new', {'title': '新增.mp4', 'series': '未分类'});
    for (var i = 0; i < 5; i++) {
      model.changed();
      await tester.pump();
    }
    expect(tester.widget<CustomScrollView>(library), same(retained));
    await tester.tap(find.text('影视库').last);
    await tester.pumpAndSettle();
    expect(find.text('121'), findsOneWidget);
    expect(tester.widget<CustomScrollView>(library), isNot(same(retained)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('covering routes defer library notifications until returning', (
    tester,
  ) async {
    final record = store.get('media', '0')!;
    store.save('progress', model.progressKey(record), {
      'position': 10,
      'updatedAt': '2026-10-22T00:00:00Z',
    });
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续观看'));
    await tester.pumpAndSettle();
    final library = find.byKey(
      const PageStorageKey('library-scroll'),
      skipOffstage: false,
    );
    final retained = tester.widget<CustomScrollView>(library);
    store.save('media', 'new', {'title': '新增.mp4', 'series': '未分类'});
    for (var i = 0; i < 5; i++) {
      model.changed();
      await tester.pump();
    }
    expect(tester.widget<CustomScrollView>(library), same(retained));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('121'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

class _CountingModel extends AppModel {
  int mediaReads = 0, preferenceReads = 0, progressReads = 0;
  int historyReads = 0;
  _CountingModel(super.store, super.documents);

  @override
  List<SyncRecord> get media {
    mediaReads++;
    return super.media;
  }

  @override
  AppPreferences get preferences {
    preferenceReads++;
    return super.preferences;
  }

  @override
  Map<String, dynamic>? progressFor(SyncRecord record) {
    progressReads++;
    return super.progressFor(record);
  }

  @override
  List<SyncRecord> recentMedia({
    bool groupSeries = true,
    Iterable<SyncRecord>? items,
  }) {
    historyReads++;
    return super.recentMedia(groupSeries: groupSeries, items: items);
  }
}
