import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _HistoryReturnModel extends AppModel {
  _HistoryReturnModel(super.store, super.documents)
    : super(backgroundWork: false, enableThumbnails: false);

  @override
  Future<void> ensureMediaPreview(String id) async {}
}

void main() {
  late Directory directory;
  late AppStore store;
  late _HistoryReturnModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('history-return-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _HistoryReturnModel(store, directory);
    for (var index = 0; index < 24; index++) {
      final id = 'series-$index';
      store.save('media', id, {
        'title': '作品 $index S01E01.mkv',
        'series': '作品 $index',
        'season': '1',
        'episode': '1',
        'size': 100,
        'poster': '${directory.path}/poster-$index.jpg',
      });
      store.save('progress', '$id:100', {
        'position': 30,
        'duration': 120,
        'updatedAt': DateTime.utc(2026, 10, 24, 0, index).toIso8601String(),
      });
    }
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  final mobile = ValueVariant<TargetPlatform>({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });
  final library = find.byKey(const PageStorageKey('library-scroll'));
  final carousel = find.byKey(const PageStorageKey('library-continue-scroll'));
  final history = find.byKey(const PageStorageKey('library-history-grid'));
  final captureKey = GlobalKey();
  const artifactDirectory = String.fromEnvironment(
    'HISTORY_RETURN_ARTIFACT_DIR',
  );

  ScrollPosition position(WidgetTester tester, Finder surface) => tester
      .state<ScrollableState>(
        find.descendant(of: surface, matching: find.byType(Scrollable)).first,
      )
      .position;

  Future<void> showLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (artifactDirectory.isNotEmpty) {
      final font = FontLoader('NotoSansSC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'));
      await font.load();
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: GlassPalette.theme().copyWith(platform: mobile.currentValue),
          home: LibraryPage(model: model),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(String stage) async {
    if (artifactDirectory.isEmpty) return;
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory(artifactDirectory);
    await directory.create(recursive: true);
    await File(
      '${directory.path}/${mobile.currentValue!.name}-$stage.png',
    ).writeAsBytes(
      bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }

  void expectLibraryLayout(WidgetTester tester, Rect initialHeader) {
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('全部视频').hitTestable(), findsOneWidget);
    expect(tester.getRect(find.text('全部视频')), initialHeader);
    final carouselRect = tester.getRect(carousel);
    expect(carouselRect.height, 164);
    expect(initialHeader.top, greaterThan(carouselRect.bottom));
    expect(initialHeader.top - carouselRect.bottom, lessThan(60));
    final progress = find.descendant(
      of: carousel,
      matching: find.byType(LinearProgressIndicator),
    );
    expect(progress, findsWidgets);
    for (final element in progress.evaluate()) {
      final rect = tester.getRect(find.byElementPredicate((e) => e == element));
      expect(rect.height, 2);
      expect(rect.top, greaterThan(carouselRect.top));
      expect(rect.bottom, lessThanOrEqualTo(carouselRect.bottom));
    }
  }

  testWidgets('mobile history return preserves carousel and all-video layout', (
    tester,
  ) async {
    await showLibrary(tester);
    await capture('initial');
    final initialHeader = tester.getRect(find.text('全部视频'));
    expectLibraryLayout(tester, initialHeader);
    position(tester, carousel).jumpTo(316);
    await tester.pumpAndSettle();

    for (var visit = 0; visit < 3; visit++) {
      await tester.tap(find.text('继续观看'));
      await tester.pumpAndSettle();
      expect(history, findsOneWidget);
      await tester.drag(history, const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(position(tester, history).pixels, greaterThan(0));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await capture('returned-$visit');
      expectLibraryLayout(tester, initialHeader);
      expect(position(tester, carousel).pixels, 316);
      expect(position(tester, library).pixels, 0);
    }

    // The carousel remains alive while its containing sliver leaves the
    // viewport. Returning to it must not lose the following grid/header.
    final vertical = position(tester, library);
    vertical.jumpTo(vertical.maxScrollExtent);
    await tester.pumpAndSettle();
    vertical.jumpTo(0);
    await tester.pumpAndSettle();
    await capture('scrolled-back');
    expectLibraryLayout(tester, initialHeader);
    expect(position(tester, carousel).pixels, 316);
    await tester.pumpWidget(const SizedBox());
  }, variant: mobile);

  testWidgets(
    'mobile history return applies covered progress without damaging layout',
    (tester) async {
      await showLibrary(tester);
      await capture('progress-initial');
      final initialHeader = tester.getRect(find.text('全部视频'));
      await tester.tap(find.text('继续观看'));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(tester.getCenter(history));
      await gesture.moveBy(const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 30));
      store.save('progress', 'series-23:100', {
        'position': 60,
        'duration': 120,
        'updatedAt': '2026-10-24T00:23:00Z',
      });
      model.changed();
      await tester.pump();
      await gesture.up();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await capture('progress-returned');
      expectLibraryLayout(tester, initialHeader);
      final first = find.byKey(const ValueKey('history:series-23'));
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.descendant(
                of: first,
                matching: find.byType(LinearProgressIndicator),
              ),
            )
            .value,
        .5,
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: mobile,
  );

  testWidgets(
    'mobile history can return during its push transition and a carousel fling',
    (tester) async {
      await showLibrary(tester);
      final initialHeader = tester.getRect(find.text('全部视频'));
      for (var visit = 0; visit < 3; visit++) {
        final horizontal = position(tester, carousel);
        horizontal.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.fling(carousel, const Offset(-300, 0), 1500);
        await tester.pump(const Duration(milliseconds: 16));
        expect(horizontal.isScrollingNotifier.value, isTrue);
        await tester.tap(find.text('继续观看'));
        await tester.pump(const Duration(milliseconds: 16));
        final enteringHistory = find.byKey(
          const PageStorageKey('library-history-grid'),
          skipOffstage: false,
        );
        expect(tester.takeException(), isNull);
        expect(enteringHistory, findsOneWidget);
        final route = ModalRoute.of(tester.element(enteringHistory))!;
        expect(route.animation!.value, lessThan(1));
        Navigator.of(tester.element(enteringHistory)).pop();
        await tester.pumpAndSettle();
        await capture('rapid-fling-returned-$visit');
        expectLibraryLayout(tester, initialHeader);
        expect(horizontal.isScrollingNotifier.value, isFalse);
      }
      await tester.pumpWidget(const SizedBox());
    },
    variant: mobile,
  );

  testWidgets(
    'mobile retained carousel survives history return without background frames',
    (tester) async {
      await showLibrary(tester);
      final initialHeader = tester.getRect(find.text('全部视频'));
      final vertical = position(tester, library);
      vertical.jumpTo(900);
      await tester.pumpAndSettle();
      expect(find.text('继续观看').hitTestable(), findsNothing);
      await tester.fling(library, const Offset(0, 500), 1800);
      expect(vertical.isScrollingNotifier.value, isTrue);
      for (
        var frame = 0;
        frame < 30 && find.text('继续观看').hitTestable().evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('继续观看').hitTestable(), findsOneWidget);
      await tester.tap(find.text('继续观看'));
      await tester.pumpAndSettle();
      expect(history, findsOneWidget);
      final navigator = Navigator.of(tester.element(history));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // The system can stop drawing immediately after paused. Pop and data
      // changes must remain safe without pumping a frame until foreground.
      navigator.pop();
      store.save('progress', 'series-23:100', {
        'position': 60,
        'duration': 120,
        'updatedAt': '2026-10-24T00:23:00Z',
      });
      model.changed();
      await tester.idle();
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await capture('frameless-returned');
      expectLibraryLayout(
        tester,
        initialHeader.shift(Offset(0, -vertical.pixels)),
      );
      expect(vertical.isScrollingNotifier.value, isFalse);
      vertical.jumpTo(0);
      await tester.pumpAndSettle();
      expectLibraryLayout(tester, initialHeader);
      await tester.pumpWidget(const SizedBox());
    },
    variant: mobile,
  );
}
