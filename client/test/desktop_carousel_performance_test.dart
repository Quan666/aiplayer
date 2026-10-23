import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late AppStore store;
  late AppModel model;

  void saveProgress(int index) {
    store.save('progress', model.progressKey(store.get('media', '$index')!), {
      'position': 30,
      'duration': 120,
      'updatedAt': DateTime.utc(2026, 10, 22, 0, index).toIso8601String(),
    });
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('aiplayer-carousel-perf-');
    store = AppStore(':memory:');
    model = AppModel(
      store,
      directory,
      backgroundWork: false,
      enableThumbnails: false,
    );
    for (var index = 0; index < 30; index++) {
      store.save('media', '$index', {
        'title': '视频 $index.mp4',
        'series': '视频 $index',
        'size': 100 + index,
        'duration': 120,
      });
      if (index < 10) saveProgress(index);
    }
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  final carousel = find.byKey(const PageStorageKey('library-continue-scroll'));
  Finder arrow(String tooltip) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == tooltip,
  );
  ScrollPosition position(WidgetTester tester, Finder target) => tester
      .state<ScrollableState>(
        find.descendant(of: target, matching: find.byType(Scrollable)).first,
      )
      .position;

  Future<void> showLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
  }

  Future<void> wheel(WidgetTester tester, double dy) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(carousel),
        scrollDelta: Offset(0, dy),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('desktop wheel reuses arrows until an edge changes', (
    tester,
  ) async {
    await showLibrary(tester);
    final horizontal = position(tester, carousel);
    final vertical = position(
      tester,
      find.byKey(const PageStorageKey('library-scroll')),
    );
    final retainedList = tester.widget<ListView>(carousel);
    expect(tester.widget<IconButton>(arrow('向左滚动')).onPressed, isNull);
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNotNull);

    await wheel(tester, 80);
    final left = tester.widget<IconButton>(arrow('向左滚动'));
    final right = tester.widget<IconButton>(arrow('向右滚动'));
    expect(left.onPressed, isNotNull);
    for (var index = 0; index < 5; index++) {
      await wheel(tester, 20);
      expect(tester.widget<IconButton>(arrow('向左滚动')), same(left));
      expect(tester.widget<IconButton>(arrow('向右滚动')), same(right));
      expect(tester.widget<ListView>(carousel), same(retainedList));
    }
    expect(horizontal.pixels, 180);
    expect(vertical.pixels, 0);

    horizontal.jumpTo(horizontal.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNull);
    await wheel(tester, -40);
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNotNull);
    expect(vertical.pixels, 0);
    await tester.tap(arrow('向左滚动'));
    await tester.pumpAndSettle();
    expect(horizontal.extentAfter, greaterThan(40));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unchanged scroll metrics do not rebuild desktop history', (
    tester,
  ) async {
    await showLibrary(tester);
    final horizontal = position(tester, carousel);
    final retainedList = tester.widget<ListView>(carousel);
    final retainedArrow = tester.widget<IconButton>(arrow('向右滚动'));
    for (var index = 0; index < 3; index++) {
      ScrollMetricsNotification(
        metrics: horizontal.copyWith(),
        context: tester.element(carousel),
      ).dispatch(tester.element(carousel));
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(carousel), same(retainedList));
      expect(tester.widget<IconButton>(arrow('向右滚动')), same(retainedArrow));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop arrows follow resizing and changed history extents', (
    tester,
  ) async {
    await showLibrary(tester);
    var horizontal = position(tester, carousel);
    horizontal.jumpTo(horizontal.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNull);

    tester.view.physicalSize = const Size(1100, 1000);
    await tester.pumpAndSettle();
    horizontal = position(tester, carousel);
    expect(horizontal.extentAfter, greaterThan(0));
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNotNull);
    await tester.tap(arrow('向右滚动'));
    await tester.pumpAndSettle();
    expect(horizontal.pixels, horizontal.maxScrollExtent);
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNull);

    for (var index = 4; index < 10; index++) {
      model.removePlaybackHistory(store.get('media', '$index')!);
    }
    await tester.pumpAndSettle();
    horizontal = position(tester, carousel);
    expect(horizontal.maxScrollExtent, greaterThan(0));
    expect(horizontal.pixels, horizontal.maxScrollExtent);
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNull);
    expect(tester.widget<IconButton>(arrow('向左滚动')).onPressed, isNotNull);

    for (var index = 1; index < 4; index++) {
      model.removePlaybackHistory(store.get('media', '$index')!);
    }
    await tester.pumpAndSettle();
    expect(arrow('向左滚动'), findsNothing);
    expect(arrow('向右滚动'), findsNothing);

    for (var index = 1; index < 10; index++) {
      saveProgress(index);
    }
    model.changed();
    await tester.pumpAndSettle();
    horizontal = position(tester, carousel);
    expect(horizontal.pixels, 0);
    expect(tester.widget<IconButton>(arrow('向左滚动')).onPressed, isNull);
    expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
