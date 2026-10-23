import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/search_header.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final _lightSkin = GlassColors.light.copyWith(
  canvas: const Color(0xfff6eee6),
  surface: const Color(0xfffff8f1),
  glass: const Color(0xe6f7e4d0),
  text: const Color(0xff423021),
  muted: const Color(0xff80634e),
  accent: const Color(0xff9a521b),
  field: const Color(0xfff1ddc8),
  selected: const Color(0xffecd0b2),
  danger: const Color(0xffa02a47),
  success: const Color(0xff427943),
);

final _darkSkin = GlassColors.dark.copyWith(
  canvas: const Color(0xff1b1223),
  surface: const Color(0xff2c1b39),
  glass: const Color(0xeb3a244a),
  text: const Color(0xfffae7ff),
  muted: const Color(0xffc9a4d7),
  accent: const Color(0xffe8a2ff),
  field: const Color(0xff24172e),
  selected: const Color(0xff4d2e61),
  danger: const Color(0xffffa7bb),
  success: const Color(0xffa6eac2),
);

ThemeData _lightTheme() =>
    AppTheme.theme(colors: _lightSkin, fontFamily: 'TestLightSkin');

ThemeData _darkTheme() => AppTheme.theme(
  brightness: Brightness.dark,
  colors: _darkSkin,
  fontFamily: 'TestDarkSkin',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    for (final family in ['NotoSansSC', 'TestLightSkin', 'TestDarkSkin']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
          .load();
    }
  });

  testWidgets(
    'a runtime skin change reaches shared library controls and an open dialog',
    (tester) async {
      final theme = ValueNotifier(_lightTheme());
      addTearDown(theme.dispose);
      await tester.pumpWidget(_themed(theme, const _SharedControls()));
      await tester.pumpAndSettle();

      expect(_textStyle(tester, '我的影视库').color, _lightSkin.text);
      expect(_textStyle(tester, '我的影视库').fontFamily, 'TestLightSkin');
      expect(_textStyle(tester, '共两部作品').color, _lightSkin.muted);
      expect(_surfaceFill(tester, find.byKey(_surfaceKey)), _lightSkin.glass);

      await tester.tap(find.byType(GlassSelect<String>));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(_dialogMaterial(tester).color, _lightSkin.surface);

      theme.value = _darkTheme();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(_dialogMaterial(tester).color, _darkSkin.surface);
      expect(
        _textStyle(tester, '选择项目', within: find.byType(Dialog)).fontFamily,
        'TestDarkSkin',
      );
      expect(
        _textStyle(tester, '选择项目', within: find.byType(Dialog)).color,
        _darkSkin.text,
      );
      await tester.tap(find.widgetWithText(ListTile, '第二项'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.text('第二项'), findsOneWidget);
      expect(_textStyle(tester, '我的影视库').color, _darkSkin.text);
      expect(_textStyle(tester, '共两部作品').color, _darkSkin.muted);
      expect(_surfaceFill(tester, find.byKey(_surfaceKey)), _darkSkin.glass);

      await tester.tap(find.byTooltip('搜索作品'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '保留搜索内容');
      theme.value = AppTheme.theme(brightness: Brightness.dark);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留搜索内容',
      );
      expect(
        _surfaceFill(tester, find.byKey(_surfaceKey)),
        GlassColors.dark.glass,
      );
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pumpAndSettle();
      expect(_textStyle(tester, '我的影视库').color, GlassColors.dark.text);

      await tester.tap(find.text('完成操作'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Icon>(find.byIcon(Icons.check_circle_rounded)).color,
        GlassColors.dark.success,
      );
      expect(_textStyle(tester, '已完成').color, GlassColors.dark.text);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('source forms adopt a new skin without losing unsaved input', (
    tester,
  ) async {
    final theme = ValueNotifier(_lightTheme());
    addTearDown(theme.dispose);
    await tester.pumpWidget(_themed(theme, const SourceEditorPage()));
    await tester.pumpAndSettle();
    final name = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == '显示名称（可选）',
    );
    await tester.enterText(name, '未保存的 NAS');
    final originalState = tester.state(find.byType(SourceEditorPage));
    expect(tester.widget<TextField>(name).style!.color, _lightSkin.text);
    expect(tester.widget<TextField>(name).style!.fontFamily, 'TestLightSkin');

    theme.value = _darkTheme();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(SourceEditorPage)), same(originalState));
    expect(tester.widget<TextField>(name).controller!.text, '未保存的 NAS');
    expect(tester.widget<TextField>(name).style!.color, _darkSkin.text);
    expect(tester.widget<TextField>(name).style!.fontFamily, 'TestDarkSkin');
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      _darkSkin.canvas,
    );

    final sourceType = find.byWidgetPredicate(
      (widget) => widget is GlassSelect<String> && widget.label == '来源类型',
    );
    await tester.ensureVisible(sourceType);
    await tester.tap(sourceType);
    await tester.pumpAndSettle();
    expect(_dialogMaterial(tester).color, _darkSkin.surface);
    await tester.tap(find.widgetWithText(ListTile, 'WebDAV'));
    await tester.pumpAndSettle();
    expect(find.text('HTTPS 加密'), findsOneWidget);
    expect(tester.widget<TextField>(name).controller!.text, '未保存的 NAS');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'settings panels and preference controls follow the current skin',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-theme-');
      final store = AppStore(':memory:');
      final model = AppModel(store, root);
      final theme = ValueNotifier(_lightTheme());
      try {
        await tester.pumpWidget(
          _themed(theme, Scaffold(body: SettingsPage(model: model))),
        );
        await tester.pumpAndSettle();
        expect(_textStyle(tester, '外观与文件').color, _lightSkin.text);
        expect(_textStyle(tester, '外观与文件').fontFamily, 'TestLightSkin');
        final panel = find.ancestor(
          of: find.text('外观与文件'),
          matching: find.byType(GlassSurface),
        );
        expect(_surfaceFill(tester, panel), _lightSkin.glass);
        final settingsState = tester.state(find.byType(SettingsPage));

        theme.value = _darkTheme();
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(SettingsPage)), same(settingsState));
        expect(_textStyle(tester, '外观与文件').color, _darkSkin.text);
        expect(_textStyle(tester, '外观与文件').fontFamily, 'TestDarkSkin');
        expect(_surfaceFill(tester, panel), _darkSkin.glass);

        final previous = model.preferences.hideHiddenFiles;
        await tester.tap(find.text('不显示隐藏文件和文件夹'));
        await tester.pumpAndSettle();
        expect(model.preferences.hideHiddenFiles, !previous);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        theme.dispose();
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  test('animated theme transitions preserve custom semantic status colors', () {
    final light = _lightTheme();
    final dark = _darkTheme();
    final transition = ThemeData.lerp(light, dark, .5);
    final colors = transition.extension<GlassColors>()!;

    expect(
      colors.success,
      Color.lerp(_lightSkin.success, _darkSkin.success, .5),
    );
    expect(colors.danger, Color.lerp(_lightSkin.danger, _darkSkin.danger, .5));
    expect(colors.glass, Color.lerp(_lightSkin.glass, _darkSkin.glass, .5));
    expect(colors.text, Color.lerp(_lightSkin.text, _darkSkin.text, .5));
    expect(transition.colorScheme.error, colors.danger);
    expect(dark.colorScheme.error, _darkSkin.danger);
    expect(dark.colorScheme.onSurface, _darkSkin.text);
    expect(
      _lightSkin.copyWith(accent: _darkSkin.accent).success,
      _lightSkin.success,
    );
    expect(
      _lightSkin.copyWith(accent: _darkSkin.accent).danger,
      _lightSkin.danger,
    );
  });
}

const _surfaceKey = ValueKey('themed-shared-surface');

Widget _themed(ValueNotifier<ThemeData> theme, Widget home) =>
    ValueListenableBuilder<ThemeData>(
      valueListenable: theme,
      child: home,
      builder: (_, value, child) => MaterialApp(
        theme: value,
        themeAnimationDuration: Duration.zero,
        home: child,
      ),
    );

TextStyle _textStyle(WidgetTester tester, String label, {Finder? within}) {
  final text = within == null
      ? find.text(label)
      : find.descendant(of: within, matching: find.text(label));
  return tester
      .widget<RichText>(
        find.descendant(of: text, matching: find.byType(RichText)).first,
      )
      .text
      .style!;
}

Color _surfaceFill(WidgetTester tester, Finder surface) => tester
    .widgetList<DecoratedBox>(
      find.descendant(of: surface, matching: find.byType(DecoratedBox)),
    )
    .map((box) => box.decoration)
    .whereType<BoxDecoration>()
    .firstWhere((decoration) => decoration.gradient != null)
    .gradient!
    .colors
    .last;

Material _dialogMaterial(WidgetTester tester) => tester
    .widgetList<Material>(
      find.descendant(of: find.byType(Dialog), matching: find.byType(Material)),
    )
    .firstWhere((material) => material.type == MaterialType.card);

class _SharedControls extends StatefulWidget {
  const _SharedControls();

  @override
  State<_SharedControls> createState() => _SharedControlsState();
}

class _SharedControlsState extends State<_SharedControls> {
  String value = 'first';

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SearchHeader(
            title: '我的影视库',
            subtitle: '共两部作品',
            hint: '搜索作品',
            onChanged: (_) {},
          ),
          GlassSurface(
            key: _surfaceKey,
            blur: 0,
            padding: const EdgeInsets.all(12),
            child: GlassSelect<String>(
              label: '选择项目',
              value: value,
              options: const [
                GlassOption('first', '第一项'),
                GlassOption('second', '第二项'),
              ],
              onChanged: (next) => setState(() => value = next),
            ),
          ),
          FilledButton(
            onPressed: () => showGlassSuccess(context, '已完成'),
            child: const Text('完成操作'),
          ),
        ],
      ),
    ),
  );
}
