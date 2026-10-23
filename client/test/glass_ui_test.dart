import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'));
    await font.load();
  });

  testWidgets('glass surfaces respect an opaque sheet blur scope', (
    tester,
  ) async {
    Widget surface(bool enabled) => MaterialApp(
      theme: GlassPalette.theme(),
      home: GlassBlurScope(
        enabled: enabled,
        child: const GlassSurface(
          tint: Color(0x88FFFFFF),
          child: SizedBox(width: 100, height: 100),
        ),
      ),
    );
    await tester.pumpWidget(surface(true));
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.pumpWidget(surface(false));
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final platform in TargetPlatform.values) {
    testWidgets('$platform avoids backdrop filtering by default', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme().copyWith(platform: platform),
          home: const Column(
            children: [
              GlassSurface(
                tint: Color(0x88FFFFFF),
                child: SizedBox(width: 100, height: 100),
              ),
              GlassControlBackground(child: SizedBox(width: 100, height: 40)),
            ],
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final brightness in Brightness.values) {
    test(
      'off switches retain visible boundaries and thumbs in $brightness',
      () {
        final theme = GlassPalette.theme(brightness: brightness);
        final colors = theme.extension<GlassColors>()!;
        final switches = theme.switchTheme;
        final track = switches.trackColor!.resolve({})!;
        final thumb = switches.thumbColor!.resolve({})!;
        final outline = switches.trackOutlineColor!.resolve({})!;
        double contrast(Color a, Color b) {
          final light = a.computeLuminance();
          final dark = b.computeLuminance();
          return light > dark
              ? (light + .05) / (dark + .05)
              : (dark + .05) / (light + .05);
        }

        expect(contrast(thumb, track), greaterThanOrEqualTo(3));
        expect(contrast(outline, colors.surface), greaterThanOrEqualTo(3));
        expect(contrast(outline, colors.canvas), greaterThanOrEqualTo(3));
        expect(
          switches.trackColor!.resolve({WidgetState.selected}),
          isNot(track),
        );
        final adaptive = theme.getAdaptation<SwitchThemeData>()!;
        final ios = theme.copyWith(platform: TargetPlatform.iOS);
        expect(adaptive.adapt(ios, switches).trackColor!.resolve({}), track);
      },
    );
  }

  for (final viewport in <({String name, Size size, double scale, bool dark})>[
    (name: '390px phone', size: const Size(390, 844), scale: 1, dark: false),
    (name: '430px phone', size: const Size(430, 932), scale: 1, dark: false),
    (
      name: 'phone with large text',
      size: const Size(390, 844),
      scale: 1.6,
      dark: false,
    ),
    (
      name: 'phone with accessibility preferences',
      size: const Size(390, 844),
      scale: 1,
      dark: false,
    ),
    (name: 'tablet', size: const Size(768, 1024), scale: 1, dark: false),
    (name: 'desktop', size: const Size(1366, 900), scale: 1, dark: false),
    (name: 'dark phone', size: const Size(390, 844), scale: 1, dark: true),
    (name: 'dark desktop', size: const Size(1366, 900), scale: 1, dark: true),
  ]) {
    testWidgets(
      '${viewport.name}: library search and navigation remain usable',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final root = Directory.systemTemp.createTempSync('aiplayer-glass-ui-');
        final store = AppStore(':memory:');
        final model = AppModel(store, root);
        await model.updatePreferences({'autoDiscover': false});
        expect(model.themeMode, ThemeMode.light);
        if (viewport.dark) model.setThemeMode(ThemeMode.dark);
        _populateLibrary(model);
        tester.view.physicalSize = viewport.size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = viewport.scale;
        if (viewport.name == 'phone with accessibility preferences') {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(
                highContrast: true,
                disableAnimations: true,
                accessibleNavigation: true,
              );
        }
        try {
          await tester.pumpWidget(AIPlayerApp(model: model));
          await tester.pumpAndSettle();
          expect(find.text('我的影视库'), findsOneWidget);
          expect(
            Theme.of(tester.element(find.text('我的影视库'))).brightness,
            viewport.dark ? Brightness.dark : Brightness.light,
          );
          expect(find.text('导入视频'), findsWidgets);
          expect(find.text('继续观看'), findsOneWidget);
          expect(tester.takeException(), isNull);
          final bottomNavigation = find.byKey(
            const ValueKey('bottom-navigation'),
          );
          if (bottomNavigation.evaluate().isNotEmpty) {
            final outer = tester.widget<GlassSurface>(bottomNavigation);
            expect(outer.borderRadius, GlassMetrics.navigationRadius);
            for (var i = 0; i < 3; i++) {
              final item = tester.widget<AnimatedContainer>(
                find.byKey(ValueKey('nav-item-$i')),
              );
              final decoration = item.decoration! as BoxDecoration;
              expect(
                decoration.borderRadius,
                BorderRadius.circular(
                  outer.borderRadius - GlassMetrics.navigationInset,
                ),
              );
            }
          }

          await tester.tap(find.byTooltip('搜索作品或文件名'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).first, '不存在的作品');
          await tester.pumpAndSettle();
          expect(find.text('没有找到匹配的作品'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('关闭搜索'));
          await tester.pumpAndSettle();

          if (viewport.name.endsWith('desktop')) {
            final posterTitle = find.byKey(const ValueKey('details:layout-0'));
            await tester.ensureVisible(posterTitle);
            await tester.tap(posterTitle);
            await tester.pumpAndSettle();
            final detailsAction = find.byTooltip('匹配海报与简介');
            expect(detailsAction, findsOneWidget);
            expect(
              find.descendant(
                of: find.byType(BottomSheet),
                matching: find.text('第 1 集'),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: find.byType(BottomSheet),
                matching: find.text('星海漫游'),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: find.byType(BottomSheet),
                matching: find.textContaining('10:12 / 24:00 · 43%'),
              ),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('series-continue')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            Navigator.of(tester.element(detailsAction)).pop();
            await tester.pumpAndSettle();
            await tester.drag(
              find.byType(CustomScrollView).first,
              const Offset(0, 1000),
            );
            await tester.pumpAndSettle();
            expect(find.text('我的影视库'), findsOneWidget);
            expect(tester.takeException(), isNull);
          }

          final sourceLabel = find.text('来源').evaluate().isNotEmpty
              ? '来源'
              : '视频来源';
          await tester.tap(find.text(sourceLabel).last);
          await tester.pumpAndSettle();
          expect(find.text('本地视频'), findsOneWidget);
          expect(find.byTooltip('添加来源'), findsWidgets);
          expect(tester.takeException(), isNull);

          await tester.tap(find.text('设置').last);
          await tester.pumpAndSettle();
          await chooseSettingsGroup(tester, '弹幕');
          final danmakuSettings = find.byKey(
            const PageStorageKey('settings-danmaku'),
          );
          await tester.scrollUntilVisible(
            find.text('弹幕服务'),
            300,
            scrollable: find
                .descendant(
                  of: danmakuSettings,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(find.text('弹幕服务'), findsOneWidget);
          expect(find.text('Token'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // A downward swipe reveals navigation after reading the lower form.
          await tester.drag(danmakuSettings, const Offset(0, 100));
          await tester.pumpAndSettle();
          await tester.tap(find.text('影视库').last);
          await tester.pumpAndSettle();
          expect(find.text('我的影视库'), findsOneWidget);
          expect(find.text('继续观看'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
          store.dispose();
          root.deleteSync(recursive: true);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
        }
      },
    );
  }

  testWidgets(
    'appearance switches immediately, preserves forms and persists locally',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-appearance-');
      final databasePath = '${root.path}/appearance.db';
      AppStore? store = AppStore(databasePath);
      AppModel? model = AppModel(store, root);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      try {
        expect(model.themeMode, ThemeMode.light);
        await tester.runAsync(() => model!.loadLibrarySnapshot());
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.text('我的影视库'))).brightness,
          Brightness.light,
        );
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        final tokenField = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == 'Token',
        );
        await chooseSettingsGroup(tester, '弹幕');
        await tester.scrollUntilVisible(
          tokenField,
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const PageStorageKey('settings-danmaku')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.enterText(tokenField, 'unsaved-theme-test');
        await chooseSettingsGroup(tester, '常规');
        await tester.ensureVisible(find.text('深色'));
        await chooseSettingsGroup(tester, '常规');
        await tester.tap(find.text('深色'));
        await tester.pumpAndSettle();
        expect(model.themeMode, ThemeMode.dark);
        expect(
          Theme.of(tester.element(find.text('常规').last)).brightness,
          Brightness.dark,
        );
        await chooseSettingsGroup(tester, '弹幕');
        expect(
          tester.widget<TextField>(tokenField).controller!.text,
          'unsaved-theme-test',
        );
        await chooseSettingsGroup(tester, '常规');
        await tester.tap(find.text('浅色'));
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.text('常规').last)).brightness,
          Brightness.light,
        );
        await chooseSettingsGroup(tester, '弹幕');
        expect(
          tester.widget<TextField>(tokenField).controller!.text,
          'unsaved-theme-test',
        );
        await chooseSettingsGroup(tester, '常规');
        await tester.tap(find.text('深色'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(store.local('appearance:theme'), 'dark');
        expect(
          store.pending,
          isEmpty,
          reason: 'appearance is device-local, not a sync record',
        );
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        model = null;
        store.dispose();
        store = AppStore(databasePath);
        model = AppModel(store, root);
        expect(model.themeMode, ThemeMode.dark);
        await tester.runAsync(() => model!.loadLibrarySnapshot());
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.text('我的影视库'))).brightness,
          Brightness.dark,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model?.dispose();
        store?.dispose();
        root.deleteSync(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}

void _populateLibrary(AppModel model) {
  const series = ['星海漫游', '风与森林', '雨后的旧书店', '夏日列车', '月光邮差', '在遥远的天际与你再次相遇'];
  for (var i = 0; i < series.length; i++) {
    final id = 'layout-$i';
    model.store.save('media', id, {
      'title': '${series[i]} 第 ${i + 1} 集',
      'fileName': 'sample-${i + 1}.mkv',
      'series': series[i],
      'season': '1',
      'episode': '${i + 1}',
      'duration': 1440,
      'size': 1000 + i,
    });
    if (i == 0) {
      final record = model.store.get('media', id)!;
      model.store.save('progress', model.progressKey(record), {
        'position': 612,
        'duration': 1440,
        'updatedAt': '2026-10-21T12:00:00Z',
      });
    }
  }
}

Future<void> chooseSettingsGroup(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(ChoiceChip, label);
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}
