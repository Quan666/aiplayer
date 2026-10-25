import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/library_sort.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RefreshModel extends AppModel {
  int libraryRefreshes = 0, detailsLoads = 0;
  CancelToken? libraryCancel, detailsCancel;
  Completer<void>? libraryGate, snapshotGate;
  VoidCallback? refreshed;

  _RefreshModel(super.store, super.documents) : super(backgroundWork: false);

  @override
  Future<void> refreshLibrarySources({CancelToken? cancel}) async {
    libraryRefreshes++;
    libraryCancel = cancel;
    await libraryGate?.future;
    cancel?.check();
    refreshed?.call();
    changed();
  }

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    final gate = snapshotGate;
    snapshotGate = null;
    await gate?.future;
    return super.loadLibrarySnapshot(query: query, cancel: cancel);
  }

  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async {
    detailsLoads++;
    detailsCancel = cancel;
    return store.all('media');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _RefreshModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('library-pull-refresh-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _RefreshModel(store, directory);
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  void episode(int number, {String title = 'Example'}) {
    store.save('media', 'episode-$number', {
      'series': title,
      'title': '$title S01E$number.mkv',
      'season': '1',
      'episode': '$number',
    });
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
  }

  final libraryScroll = find.byKey(const PageStorageKey('library-scroll'));
  final refresh = find.byKey(const ValueKey('library-refresh'));

  for (final device in [
    (
      name: 'desktop mouse',
      size: const Size(1280, 900),
      platform: TargetPlatform.macOS,
      kind: PointerDeviceKind.mouse,
    ),
    (
      name: 'mobile touch',
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      kind: PointerDeviceKind.touch,
    ),
  ]) {
    Future<void> doubleTapLibrary(WidgetTester tester) async {
      final tab = find.byKey(const ValueKey('nav-item-0'));
      await tester.tap(tab, kind: device.kind);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(tab, kind: device.kind);
      await tester.pump();
    }

    testWidgets(
      '${device.name} library tab selects immediately and double tap refreshes',
      (tester) async {
        episode(1);
        await mount(tester, size: device.size);
        model.refreshed = () => episode(2, title: 'Example Two');
        await tester.tap(
          find.byKey(const ValueKey('nav-item-2')),
          kind: device.kind,
        );
        await tester.pumpAndSettle();
        final tab = find.byKey(const ValueKey('nav-item-0'));

        await tester.tap(tab, kind: device.kind);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.widget<PageView>(find.byType(PageView).first).controller!.page,
          0,
        );
        expect(model.libraryRefreshes, 0);
        await tester.pump(const Duration(milliseconds: 84));
        await tester.tap(tab, kind: device.kind);
        await tester.pumpAndSettle();
        expect(model.libraryRefreshes, 1);
        expect(find.byKey(const ValueKey('play:episode-2')), findsOneWidget);

        await tester.tap(tab, kind: device.kind);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(minutes: 10));
        expect(model.libraryRefreshes, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(device.platform),
    );

    testWidgets(
      '${device.name} double refresh shares work and cancels without a frame',
      (tester) async {
        await mount(tester, size: device.size);
        model.libraryGate = Completer<void>();
        await doubleTapLibrary(tester);
        expect(model.libraryRefreshes, 1);
        final firstCancel = model.libraryCancel;
        await tester.pump(const Duration(milliseconds: 350));
        await doubleTapLibrary(tester);
        expect(model.libraryRefreshes, 1);
        expect(identical(model.libraryCancel, firstCancel), isTrue);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(firstCancel!.cancelled, isTrue);
        model.libraryGate!.complete();
        await tester.idle();
        expect(model.libraryRefreshes, 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(model.libraryRefreshes, 1);
        model.libraryGate = null;
        await doubleTapLibrary(tester);
        await tester.pumpAndSettle();
        expect(model.libraryRefreshes, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(device.platform),
    );
  }

  testWidgets('empty library pulls sources once and stays idle afterward', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('暂无视频'), findsOneWidget);
    expect(model.libraryRefreshes, 0);

    await tester.drag(libraryScroll, const Offset(0, 360));
    await tester.pumpAndSettle();
    expect(model.libraryRefreshes, 1);
    await tester.pump(const Duration(minutes: 10));
    expect(model.libraryRefreshes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pulling a short library updates content and retains search and sorting',
    (tester) async {
      episode(1);
      const sorting = LibrarySort(field: 'name', descending: false);
      await model.setLibrarySorting(sorting);
      await mount(tester);
      await tester.tap(find.byTooltip('搜索作品或文件名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Example');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(of: libraryScroll, matching: find.byType(Scrollable))
            .first,
      );
      model.refreshed = () => episode(2, title: 'Example Two');

      await tester.drag(libraryScroll, const Offset(0, 360));
      await tester.pumpAndSettle();
      expect(model.libraryRefreshes, 1);
      expect(find.byKey(const ValueKey('play:episode-2')), findsOneWidget);
      expect(field.controller!.text, 'Example');
      expect(model.librarySorting, sorting);
      expect(scroll.position.pixels, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'library refresh deduplicates and cancels on pause without a frame',
    (tester) async {
      await mount(tester);
      model.libraryGate = Completer<void>();
      final indicator = tester.widget<RefreshIndicator>(refresh);
      final first = indicator.onRefresh();
      final duplicate = indicator.onRefresh();
      expect(model.libraryRefreshes, 1);
      expect(model.libraryCancel!.cancelled, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Android may not render again after paused. Cancellation is immediate.
      expect(model.libraryCancel!.cancelled, isTrue);
      model.libraryGate!.complete();
      await tester.idle();
      await Future.wait([first, duplicate]);
      expect(model.libraryRefreshes, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(model.libraryRefreshes, 1);
      model.libraryGate = null;
      await tester.widget<RefreshIndicator>(refresh).onRefresh();
      await tester.pumpAndSettle();
      expect(model.libraryRefreshes, 2);
      expect(model.libraryCancel!.cancelled, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('switching tabs cancels a pending library refresh', (
    tester,
  ) async {
    await mount(tester);
    model.libraryGate = Completer<void>();
    final pending = tester.widget<RefreshIndicator>(refresh).onRefresh();
    await tester.tap(find.byKey(const ValueKey('nav-item-1')));
    await tester.pumpAndSettle();
    expect(model.libraryCancel!.cancelled, isTrue);
    model.libraryGate!.complete();
    await pending;
    await tester.tap(find.byKey(const ValueKey('nav-item-0')));
    await tester.pumpAndSettle();
    expect(model.libraryRefreshes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'details snapshot completed while paused does not start a source request',
    (tester) async {
      episode(1);
      await mount(tester);
      final snapshotGate = model.snapshotGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(model.snapshotGate, isNull);
      expect(model.detailsLoads, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      snapshotGate.complete();
      await tester.idle();
      expect(model.detailsLoads, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(model.detailsLoads, 1);
      expect(model.detailsCancel!.cancelled, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
