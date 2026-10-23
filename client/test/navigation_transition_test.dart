import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [1280.0, 800.0]) {
    testWidgets(
      'macOS navigation at width $width selects the destination without flashing intermediate tabs',
      (tester) async {
        final fixture = _Fixture(tester, width: width);
        await fixture.mount();

        await tester.tap(fixture.tab(2));
        await tester.pump();
        expect(fixture.selected(2), isTrue);
        expect(fixture.page, 2);
        for (var frame = 0; frame < 24; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(fixture.selected(1), isFalse);
          expect(fixture.selected(2), isTrue);
          expect(fixture.page, 2);
        }
        expect(tester.takeException(), isNull);
        await fixture.close();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'macOS navigation at width $width honors a rapid return to the original tab',
      (tester) async {
        final fixture = _Fixture(tester, width: width);
        await fixture.mount();

        await tester.tap(fixture.tab(2));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.tap(fixture.tab(0));
        await tester.pump();
        expect(fixture.selected(0), isTrue);
        expect(fixture.page, 0);
        await tester.pumpAndSettle();
        expect(fixture.selected(0), isTrue);
        expect(fixture.selected(1), isFalse);
        expect(fixture.selected(2), isFalse);
        expect(fixture.page, 0);
        expect(tester.takeException(), isNull);
        await fixture.close();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets('desktop selection moves continuously and reverses in place', (
    tester,
  ) async {
    final fixture = _Fixture(tester);
    await fixture.mount();
    final start = tester.getCenter(fixture.indicator).dy;
    final destination = tester.getCenter(fixture.tab(2)).dy;

    await tester.tap(fixture.tab(2));
    await tester.pump();
    expect(tester.getCenter(fixture.indicator).dy, closeTo(start, .01));
    await tester.pump(const Duration(milliseconds: 60));
    final moving = tester.getCenter(fixture.indicator).dy;
    expect(moving, greaterThan(start));
    expect(moving, lessThan(destination));
    expect(fixture.selected(1), isFalse);

    await tester.tap(fixture.tab(0));
    await tester.pump();
    expect(tester.getCenter(fixture.indicator).dy, closeTo(moving, .01));
    await tester.pump(const Duration(milliseconds: 60));
    final returning = tester.getCenter(fixture.indicator).dy;
    expect(returning, greaterThan(start));
    expect(returning, lessThan(moving));
    await tester.pumpAndSettle();
    expect(tester.getCenter(fixture.indicator).dy, closeTo(start, .01));
    expect(tester.takeException(), isNull);
    await fixture.close();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('desktop selection respects system reduced motion', (
    tester,
  ) async {
    final fixture = _Fixture(tester, reducedMotion: true);
    await fixture.mount();

    await tester.tap(fixture.tab(2));
    await tester.pump();
    expect(fixture.page, 2);
    expect(fixture.selected(2), isTrue);
    expect(
      tester.getCenter(fixture.indicator).dy,
      closeTo(tester.getCenter(fixture.tab(2)).dy, .01),
    );
    expect(tester.takeException(), isNull);
    await fixture.close();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('desktop selection remains aligned with enlarged text', (
    tester,
  ) async {
    final fixture = _Fixture(tester, textScale: 2);
    await fixture.mount();
    for (final index in [2, 1, 0]) {
      await tester.tap(fixture.tab(index));
      await tester.pumpAndSettle();
      final indicator = tester.getRect(fixture.indicator);
      final item = tester.getRect(fixture.tab(index));
      expect(indicator.center.dy, closeTo(item.center.dy, .01));
      expect(indicator.height, closeTo(item.height, .01));
      expect(tester.takeException(), isNull);
    }
    await fixture.close();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('phone navigation retains horizontal swiping', (tester) async {
    final fixture = _Fixture(tester, width: 390);
    await fixture.mount();

    await tester.dragFrom(const Offset(350, 300), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(fixture.page, 1);
    expect(fixture.selected(1), isTrue);
    await tester.dragFrom(const Offset(40, 300), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(fixture.page, 0);
    expect(fixture.selected(0), isTrue);
    expect(tester.takeException(), isNull);
    await fixture.close();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

class _Fixture {
  final WidgetTester tester;
  final directory = Directory.systemTemp.createTempSync('aiplayer-nav-motion-');
  final store = AppStore(':memory:');
  late final AppModel model;
  bool _closed = false;

  _Fixture(
    this.tester, {
    double width = 1280,
    bool reducedMotion = false,
    double textScale = 1,
  }) {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: reducedMotion);
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    model = AppModel(store, directory);
    addTearDown(() async {
      await close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    });
  }

  Finder tab(int index) => find.byKey(ValueKey('nav-item-$index'));
  Finder get indicator =>
      find.byKey(const ValueKey('desktop-navigation-indicator'));
  double get page =>
      tester.widget<PageView>(find.byType(PageView).first).controller!.page!;

  bool selected(int index) => tester
      .widgetList<Semantics>(
        find.ancestor(of: tab(index), matching: find.byType(Semantics)),
      )
      .any((widget) => widget.properties.selected == true);

  Future<void> mount() async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  }
}
