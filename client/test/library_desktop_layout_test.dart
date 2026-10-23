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

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync(
      'aiplayer-library-desktop-',
    );
    store = AppStore(':memory:');
    model = AppModel(store, directory);
    for (var index = 0; index < 12; index++) {
      final id = '$index';
      store.save('media', id, {
        'title': '视频 $index.mp4',
        'series': '视频 $index',
        'size': 100,
        'duration': 120,
      });
      store.save('progress', model.progressKey(store.get('media', id)!), {
        'position': 30,
        'duration': 120,
        'updatedAt': DateTime.utc(2026, 10, 22, 0, index).toIso8601String(),
      });
    }
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  ScrollPosition position(WidgetTester tester, Finder finder) => tester
      .state<ScrollableState>(
        find.descendant(of: finder, matching: find.byType(Scrollable)).first,
      )
      .position;

  Finder arrow(String tooltip) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == tooltip,
  );

  testWidgets('wide navigation folds to icons and retains the selection', (
    tester,
  ) async {
    size(tester, const Size(1440, 1000));
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('nav-item-0'));
    final expandedWidth = tester.getSize(first).width;
    await tester.tap(find.byKey(const ValueKey('toggle-desktop-navigation')));
    await tester.pumpAndSettle();
    expect(tester.getSize(first).width, lessThan(expandedWidth));
    expect(
      find.descendant(of: first, matching: find.byType(Text)),
      findsNothing,
    );
    expect(store.local('desktopNavigationCollapsed'), true);
    await tester.tap(find.byKey(const ValueKey('nav-item-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-item-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('toggle-desktop-navigation')));
    await tester.pumpAndSettle();
    expect(tester.getSize(first).width, expandedWidth);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone history has no scrollbar and no header status messages', (
    tester,
  ) async {
    size(tester, const Size(390, 844));
    model.status = '同步完成';
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    expect(find.text('同步完成'), findsNothing);
    final carousel = find.byKey(
      const PageStorageKey('library-continue-scroll'),
    );
    expect(
      find.ancestor(of: carousel, matching: find.byType(Scrollbar)),
      findsNothing,
    );
    await tester.drag(carousel, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(position(tester, carousel).pixels, greaterThan(0));
    model.status = '已发现 20 个视频';
    model.changed();
    await tester.pumpAndSettle();
    expect(find.text('已发现 20 个视频'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'desktop history supports mouse wheel, dragging and arrow buttons',
    (tester) async {
      size(tester, const Size(1440, 1000));
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      final carousel = find.byKey(
        const PageStorageKey('library-continue-scroll'),
      );
      final horizontal = position(tester, carousel);
      final vertical = position(
        tester,
        find.byKey(const PageStorageKey('library-scroll')),
      );
      expect(tester.widget<IconButton>(arrow('向左滚动')).onPressed, isNull);
      expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNotNull);
      final scrollbar = tester.widget<Scrollbar>(
        find.ancestor(of: carousel, matching: find.byType(Scrollbar)).first,
      );
      expect(scrollbar.thumbVisibility, true);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(carousel),
          scrollDelta: const Offset(0, 160),
        ),
      );
      await tester.pumpAndSettle();
      expect(horizontal.pixels, 160);
      expect(vertical.pixels, 0);
      await tester.drag(
        carousel,
        const Offset(-240, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(horizontal.pixels, greaterThan(300));
      expect(vertical.pixels, 0);
      final beforeArrow = horizontal.pixels;
      await tester.tap(arrow('向右滚动'));
      await tester.pumpAndSettle();
      expect(horizontal.pixels, greaterThan(beforeArrow));
      horizontal.jumpTo(horizontal.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(arrow('向右滚动')).onPressed, isNull);
      expect(tester.widget<IconButton>(arrow('向左滚动')).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('expanded history uses a responsive grid and keeps every item', (
    tester,
  ) async {
    size(tester, const Size(1440, 1000));
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续观看'));
    await tester.pumpAndSettle();
    final grid = find.byKey(const PageStorageKey('library-history-grid'));
    expect(tester.widget<GridView>(grid).semanticChildCount, 12);
    final first = find.byKey(const ValueKey('history:11'));
    final second = find.byKey(const ValueKey('history:10'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(
      tester.getTopLeft(second).dx,
      greaterThan(tester.getTopLeft(first).dx),
    );
    expect(tester.getSize(first).width, lessThan(450));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(first).dx, tester.getTopLeft(second).dx);
    expect(
      tester.getTopLeft(second).dy,
      greaterThan(tester.getBottomLeft(first).dy),
    );
    expect(tester.getSize(first).width, 366);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'remote history identifies its device and local history stays concise',
    (tester) async {
      size(tester, const Size(1440, 1000));
      final media = store.get('media', '11')!;
      final previous = store.get('progress', model.progressKey(media))!;
      store.acknowledge(previous, previous);
      store.applyRemote(
        SyncRecord(
          kind: 'progress',
          id: model.progressKey(media),
          version: 2,
          deviceId: 'living-room',
          deviceName: '客厅 Mac mini · macOS',
          data: {
            'position': 35,
            'duration': 120,
            'updatedAt': '2026-10-23T00:00:00Z',
          },
        ),
      );
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      expect(find.text('客厅 Mac mini · macOS'), findsOneWidget);
      expect(find.text(store.deviceName), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
