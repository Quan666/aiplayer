import 'dart:async';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/ui/player_controls_settings.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

List<Color> _glassColors(WidgetTester tester, Finder glass) {
  final decoration = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: glass,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).gradient != null,
          ),
        )
        .first,
  );
  return (decoration.decoration as BoxDecoration).gradient!.colors;
}

void main() {
  testWidgets(
    'advanced settings fit each active tab and scroll in a short window',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _SettingsSession();
      addTearDown(session.dispose);
      addTearDown(session.model.dispose);
      await _openQuickSettings(tester, session);
      final heights = <String, double>{};
      for (final name in ['播放', '字幕', '弹幕', '诊断', '字幕']) {
        await tester.tap(find.widgetWithText(Tab, name));
        await tester.pumpAndSettle();
        heights[name] = tester.getSize(find.byType(PlayerGlass)).height;
        expect(heights[name], lessThan(PlayerTheme.advancedSettingsMaxHeight));
        expect(tester.takeException(), isNull);
      }
      expect(heights['诊断'], lessThan(heights['字幕']!));
      tester.view.physicalSize = const Size(844, 260);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(PlayerQuickSettings),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(scroll.maxScrollExtent, greaterThan(0));
      scroll.jumpTo(scroll.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('字幕偏移').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings drafts survive tab changes and late saves', (
    tester,
  ) async {
    final session = _SettingsSession();
    addTearDown(session.dispose);
    addTearDown(session.model.dispose);
    await _openQuickSettings(tester, session);
    await tester.tap(find.widgetWithText(Tab, '字幕'));
    await tester.pumpAndSettle();
    Slider scale() => tester.widget<Slider>(find.byType(Slider).first);
    scale().onChanged!(1.5);
    scale().onChangeEnd!(1.5);
    await tester.pump();
    await tester.tap(find.widgetWithText(Tab, '诊断'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '字幕'));
    await tester.pumpAndSettle();
    expect(scale().value, 1.5);
    scale().onChanged!(2.0);
    await tester.pump();
    session.saves.first.complete();
    await tester.pump();
    expect(scale().value, 2.0);
    scale().onChangeEnd!(2.0);
    session.saves.last.complete();
    await tester.pumpAndSettle();
    expect(session.model.preferences.subtitleScale, 2.0);
    expect(scale().value, 2.0);
    // Disposing a panel must not revive its draft listeners on completion.
    scale().onChanged!(2.5);
    scale().onChangeEnd!(2.5);
    await tester.pumpWidget(const SizedBox());
    session.saves.last.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final selected in [0, 600, 999]) {
    testWidgets(
      'choice menu opens centered on option $selected without building preceding rows',
      (tester) async {
        final built = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 240,
                height: 280,
                child: PlayerMenuList(
                  selectedIndex: selected,
                  itemExtent: PlayerTheme.choiceRowHeight,
                  itemCount: 1000,
                  itemBuilder: (_, index) {
                    built.add(index);
                    return PlayerChoiceTile(
                      key: ValueKey(index),
                      title: Text('选项 $index'),
                      selected: index == selected,
                      onTap: () {},
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey(selected)), findsOneWidget);
        expect(built.length, lessThan(30));
        final viewport = tester.getRect(find.byType(ListView));
        final item = tester.getRect(find.byKey(ValueKey(selected)));
        expect(item.height, PlayerTheme.choiceRowHeight);
        final title = find.text('选项 $selected');
        final titleRect = tester.getRect(title);
        expect(titleRect.left, closeTo(item.left + 8, .1));
        expect(titleRect.center.dy, closeTo(item.center.dy, .1));
        expect(
          tester
              .renderObject<RenderParagraph>(
                find.descendant(of: title, matching: find.byType(RichText)),
              )
              .textAlign,
          TextAlign.start,
        );
        if (selected == 0) {
          expect(item.top, viewport.top);
        } else if (selected == 999) {
          expect(item.bottom, viewport.bottom);
        } else {
          expect(item.center.dy, closeTo(viewport.center.dy, .1));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final lines in [1, 2]) {
    testWidgets(
      'compact $lines-line selectors fit text at accessibility scales',
      (tester) async {
        final title = lines == 1 ? '1.25×' : '第一行\n第二行';
        for (final (scaler, factor) in [
          (TextScaler.linear(1), 1.0),
          (TextScaler.linear(1.5), 1.5),
          (TextScaler.linear(2.5), 2.5),
          (const _MenuTextScaler(), 2.5),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: scaler),
                child: child!,
              ),
              home: PlayerTheme.surface(
                Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 240,
                      child: PlayerSelect<String>(
                        label: '选择',
                        maxLines: lines,
                        value: 'one',
                        options: [GlassOption('one', title)],
                        onChanged: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byType(PlayerSelect<String>));
          await tester.pumpAndSettle();
          final choice = find.descendant(
            of: find.byType(PlayerSheet),
            matching: find.widgetWithText(PlayerChoiceTile, title),
          );
          final row = tester.getRect(choice);
          final text = tester.getRect(
            find.descendant(of: choice, matching: find.text(title)),
          );
          expect(row.height, (lines == 1 ? 32 : 40) * factor);
          expect(text.top, greaterThanOrEqualTo(row.top + 3));
          expect(text.bottom, lessThanOrEqualTo(row.bottom - 3));
          expect(text.center.dy, closeTo(row.center.dy, .1));
          expect(tester.takeException(), isNull);
          await tester.tap(choice);
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  }

  testWidgets(
    'compact playlist rows keep progress readable and the selection centered at large text sizes',
    (tester) async {
      for (final scale in [1.0, 1.5, 2.5]) {
        final built = <int>[];
        const selected = 600;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: PlayerTheme.surface(
                Builder(
                  builder: (context) => Center(
                    child: SizedBox(
                      width: 360,
                      height: 280,
                      child: PlayerMenuList(
                        key: ValueKey(scale),
                        selectedIndex: selected,
                        itemExtent: PlayerTheme.choiceExtent(
                          context,
                          twoLines: true,
                        ),
                        itemCount: 1000,
                        itemBuilder: (_, index) {
                          built.add(index);
                          return PlayerChoiceTile(
                            key: ValueKey(index),
                            selected: index == selected,
                            title: Text(
                              '第 $index 集',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PlayerTheme.of(
                                context,
                              ).playlistItemStyle(selected: index == selected),
                            ),
                            subtitle: index.isEven
                                ? Text(
                                    '12:34 / 24:00 · 52%',
                                    key: ValueKey('progress-$index'),
                                    style: PlayerTheme.of(
                                      context,
                                    ).playlistProgressStyle,
                                  )
                                : null,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(built.length, lessThan(30));
        final viewport = tester.getRect(find.byType(ListView));
        final row = tester.getRect(find.byKey(const ValueKey(selected)));
        final previous = tester.getRect(
          find.byKey(const ValueKey(selected - 1)),
        );
        final title = tester.getRect(find.text('第 $selected 集'));
        final progress = tester.getRect(
          find.byKey(const ValueKey('progress-$selected')),
        );
        expect(row.height, 40 * scale);
        expect(previous.height, row.height);
        expect(row.center.dy, closeTo(viewport.center.dy, .1));
        expect(title.top, greaterThanOrEqualTo(row.top + 4));
        expect(title.bottom, lessThanOrEqualTo(progress.top));
        expect(progress.bottom, lessThanOrEqualTo(row.bottom - 4));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'player controls retain glass styling without filtering live video',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerTheme.surface(
            const Center(
              child: PlayerGlass(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('播放控件'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(_glassColors(tester, find.byType(PlayerGlass)), hasLength(3));
      expect(find.byType(ClipRRect), findsOneWidget);
    },
  );

  testWidgets(
    'replacing the app theme updates player glass and nested choices without resetting form state',
    (tester) async {
      const firstTokens = PlayerTokens(
        foreground: Color(0xffd6ffd0),
        tint: Color(0xff163a28),
        highlight: Color(0xff326748),
        shade: Color(0xff092719),
        glassRadius: 10,
        controlRadius: 8,
        panelRadius: 18,
      );
      const secondTokens = PlayerTokens(
        foreground: Color(0xffffd7ec),
        tint: Color(0xff46243a),
        highlight: Color(0xff754360),
        shade: Color(0xff2a1221),
        glassRadius: 26,
        controlRadius: 20,
        panelRadius: 30,
        opacity: .7,
      );
      const appearances = [
        (
          tokens: firstTokens,
          danger: Color(0xffc24b25),
          font: 'CustomPlayerOne',
          captionSize: 15.0,
        ),
        (
          tokens: secondTokens,
          danger: Color(0xffb02b6e),
          font: 'CustomPlayerTwo',
          captionSize: 17.0,
        ),
      ];
      ThemeData themeFor(int index) {
        final appearance = appearances[index];
        return AppTheme.theme(
          colors: GlassColors.light.copyWith(danger: appearance.danger),
          player: appearance.tokens,
          fontFamily: appearance.font,
          textTheme: TextTheme(
            bodySmall: TextStyle(fontSize: appearance.captionSize),
          ),
        );
      }

      final activeTheme = ValueNotifier(themeFor(0));
      addTearDown(activeTheme.dispose);
      const fieldKey = ValueKey('theme-draft');
      const glassKey = ValueKey('theme-preview-glass');
      var selected = 'contain';
      await tester.pumpWidget(
        ValueListenableBuilder<ThemeData>(
          valueListenable: activeTheme,
          builder: (context, theme, _) => MaterialApp(
            theme: theme,
            themeAnimationDuration: Duration.zero,
            home: PlayerTheme.surface(
              StatefulBuilder(
                builder: (context, setState) => Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 320,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const PlayerGlass(
                            key: glassKey,
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('自定义播放器'),
                            ),
                          ),
                          const TextField(
                            key: fieldKey,
                            decoration: InputDecoration(labelText: '未保存内容'),
                          ),
                          FilledButton(
                            onPressed: () {},
                            child: const Text('保存'),
                          ),
                          PlayerSelect<String>(
                            label: '画面适配',
                            value: selected,
                            options: const [
                              GlassOption('contain', '完整显示'),
                              GlassOption('cover', '填满画面'),
                            ],
                            onChanged: (value) =>
                                setState(() => selected = value),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(fieldKey), '切换主题后保留这段文字');
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      for (var index = 0; index < appearances.length; index++) {
        if (index > 0) {
          activeTheme.value = themeFor(index);
          await tester.pumpAndSettle();
        }
        final appearance = appearances[index];
        final tokens = appearance.tokens;
        final glass = find.byKey(glassKey);
        final theme = Theme.of(tester.element(find.text('自定义播放器')));
        expect(theme.brightness, Brightness.dark);
        expect(theme.extension<PlayerTokens>(), tokens);
        expect(theme.colorScheme.primary, tokens.foreground);
        expect(theme.colorScheme.error, appearance.danger);
        expect(theme.textTheme.bodyMedium!.fontFamily, appearance.font);
        expect(theme.textTheme.bodySmall!.fontSize, appearance.captionSize);
        expect(
          theme.filledButtonTheme.style!.foregroundColor!.resolve({}),
          tokens.foreground,
        );
        expect(
          (theme.inputDecorationTheme.border! as OutlineInputBorder)
              .borderRadius,
          BorderRadius.circular(tokens.controlRadius),
        );
        expect(
          tester
              .widget<ClipRRect>(
                find.descendant(of: glass, matching: find.byType(ClipRRect)),
              )
              .borderRadius,
          BorderRadius.circular(tokens.glassRadius),
        );
        final gradient = _glassColors(tester, glass);
        expect(gradient.map((color) => color.withAlpha(255)), [
          tokens.highlight,
          tokens.tint,
          tokens.shade,
        ]);
        expect(gradient[1].a, closeTo(184 / 255 * tokens.opacity, .005));
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editable),
        );
        expect(editable.widget.controller.text, '切换主题后保留这段文字');

        final selectedLabel = selected == 'contain' ? '完整显示' : '填满画面';
        await tester.tap(find.text(selectedLabel));
        await tester.pumpAndSettle();
        final selectedTile = find.widgetWithText(
          PlayerChoiceTile,
          selectedLabel,
        );
        final nestedTheme = Theme.of(tester.element(selectedTile));
        expect(tester.widget<PlayerChoiceTile>(selectedTile).selected, isTrue);
        expect(nestedTheme.extension<PlayerTokens>(), tokens);
        expect(nestedTheme.extension<GlassColors>()!.danger, appearance.danger);
        expect(nestedTheme.textTheme.bodyMedium!.fontFamily, appearance.font);
        expect(
          nestedTheme.textTheme.bodySmall!.fontSize,
          appearance.captionSize,
        );
        expect(nestedTheme.listTileTheme.selectedColor, tokens.foreground);
        expect(
          nestedTheme.listTileTheme.selectedTileColor,
          tokens.foreground.withAlpha(24),
        );
        final choiceGlass = find.ancestor(
          of: selectedTile,
          matching: find.byType(PlayerGlass),
        );
        expect(_glassColors(tester, choiceGlass), gradient);
        expect(
          tester
              .widget<ClipRRect>(
                find.descendant(
                  of: choiceGlass,
                  matching: find.byType(ClipRRect),
                ),
              )
              .borderRadius,
          BorderRadius.circular(tokens.panelRadius),
        );
        await tester.tap(
          find.widgetWithText(
            PlayerChoiceTile,
            selected == 'contain' ? '填满画面' : '完整显示',
          ),
        );
        await tester.pumpAndSettle();
        expect(selected, index == 0 ? 'cover' : 'contain');
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final popover in [false, true]) {
    testWidgets(
      'an open ${popover ? 'player popover' : 'PlayerSelect sheet'} follows app theme replacement',
      (tester) async {
        const initial = PlayerTokens(
          foreground: Color(0xffd2ffe6),
          tint: Color(0xff14352b),
          panelRadius: 16,
        );
        const replacement = PlayerTokens(
          foreground: Color(0xffffe0ca),
          tint: Color(0xff45251d),
          panelRadius: 28,
        );
        const danger = Color(0xffc8346e);
        final activeTheme = ValueNotifier(AppTheme.theme(player: initial));
        addTearDown(activeTheme.dispose);
        final anchor = GlobalKey();
        const draftKey = ValueKey('open-popup-draft');
        await tester.pumpWidget(
          ValueListenableBuilder<ThemeData>(
            valueListenable: activeTheme,
            builder: (context, theme, _) => MaterialApp(
              theme: theme,
              themeAnimationDuration: Duration.zero,
              home: PlayerTheme.surface(
                Scaffold(
                  body: Builder(
                    builder: (context) => Align(
                      alignment: Alignment.bottomRight,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: SizedBox(
                          width: 240,
                          child: popover
                              ? TextButton(
                                  key: anchor,
                                  onPressed: () => showPlayerPopover<void>(
                                    context: context,
                                    anchor: anchor,
                                    builder: (_) => const Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextField(key: draftKey),
                                        ListTile(
                                          title: Text('原始音轨'),
                                          selected: true,
                                        ),
                                      ],
                                    ),
                                  ),
                                  child: const Text('原始音轨'),
                                )
                              : PlayerSelect<String>(
                                  label: '音轨',
                                  value: 'original',
                                  options: const [
                                    GlassOption('original', '原始音轨'),
                                    GlassOption('alternate', '其他音轨'),
                                  ],
                                  onChanged: (_) {},
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('原始音轨'));
        await tester.pumpAndSettle();
        final selected = find.widgetWithText(
          popover ? ListTile : PlayerChoiceTile,
          '原始音轨',
        );
        expect(
          Theme.of(tester.element(selected)).extension<PlayerTokens>(),
          initial,
        );
        final route = ModalRoute.of(tester.element(selected));
        EditableTextState? editable;
        if (popover) {
          await tester.enterText(find.byKey(draftKey), '弹窗中的未保存内容');
          editable = tester.state<EditableTextState>(find.byType(EditableText));
          FocusManager.instance.primaryFocus?.unfocus();
        }

        activeTheme.value = AppTheme.theme(
          player: replacement,
          colors: GlassColors.light.copyWith(danger: danger),
          fontFamily: 'ReplacementPlayerFont',
          textTheme: const TextTheme(bodySmall: TextStyle(fontSize: 16)),
        );
        await tester.pumpAndSettle();

        expect(ModalRoute.of(tester.element(selected)), same(route));
        final theme = Theme.of(tester.element(selected));
        expect(theme.extension<PlayerTokens>(), replacement);
        expect(theme.colorScheme.primary, replacement.foreground);
        expect(theme.colorScheme.error, danger);
        expect(theme.textTheme.bodyMedium!.fontFamily, 'ReplacementPlayerFont');
        expect(theme.textTheme.bodySmall!.fontSize, 16);
        expect(
          popover
              ? tester.widget<ListTile>(selected).selected
              : tester.widget<PlayerChoiceTile>(selected).selected,
          isTrue,
        );
        expect(theme.listTileTheme.selectedColor, replacement.foreground);
        expect(
          theme.listTileTheme.selectedTileColor,
          replacement.foreground.withAlpha(24),
        );
        final glass = find.byType(PlayerGlass);
        expect(_glassColors(tester, glass)[1].withAlpha(255), replacement.tint);
        expect(
          tester
              .widget<ClipRRect>(
                find.descendant(of: glass, matching: find.byType(ClipRRect)),
              )
              .borderRadius,
          BorderRadius.circular(replacement.panelRadius),
        );
        if (popover) {
          expect(
            tester.state<EditableTextState>(find.byType(EditableText)),
            same(editable),
          );
          expect(editable!.widget.controller.text, '弹窗中的未保存内容');
        }
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(selected)).pop();
        await tester.pumpAndSettle();
      },
    );
  }

  for (final highContrast in [false, true]) {
    testWidgets(
      'all player surfaces share ${highContrast ? 'opaque high-contrast' : 'translucent'} glass with or without blur',
      (tester) async {
        final anchor = GlobalKey();
        const controlsKey = ValueKey('controls-glass');
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(highContrast: highContrast),
              child: child!,
            ),
            home: PlayerTheme.surface(
              Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const PlayerGlass(
                          key: controlsKey,
                          blur: true,
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('播放器控件'),
                          ),
                        ),
                        TextButton(
                          onPressed: () => showModalBottomSheet<void>(
                            context: context,
                            backgroundColor: Colors.transparent,
                            barrierColor: PlayerTheme.barrierColor,
                            isScrollControlled: true,
                            builder: (_) => const PlayerSheet(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Text('面板内容'),
                              ),
                            ),
                          ),
                          child: const Text('设置面板'),
                        ),
                        TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => PlayerTheme.surface(
                              const PlayerDialog(
                                title: Text('诊断'),
                                content: Text('面板内容'),
                              ),
                            ),
                          ),
                          child: const Text('诊断弹窗'),
                        ),
                        TextButton(
                          key: anchor,
                          onPressed: () => showPlayerPopover<void>(
                            context: context,
                            anchor: anchor,
                            builder: (_) => const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('面板内容'),
                            ),
                          ),
                          child: const Text('按钮菜单'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final controls = find.byKey(controlsKey);
        final colors = _glassColors(tester, controls);
        for (final color in colors) {
          expect(color.a, highContrast ? equals(1) : inExclusiveRange(0, 1));
        }
        expect(
          tester
              .widget<BackdropFilter>(
                find.descendant(
                  of: controls,
                  matching: find.byType(BackdropFilter),
                ),
              )
              .enabled,
          !highContrast,
        );
        for (final label in ['设置面板', '诊断弹窗', '按钮菜单']) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          final content = find.text('面板内容');
          final glass = find.ancestor(
            of: content,
            matching: find.byType(PlayerGlass),
          );
          expect(glass, findsOneWidget);
          expect(_glassColors(tester, glass), colors, reason: label);
          expect(
            find.descendant(of: glass, matching: find.byType(BackdropFilter)),
            findsNothing,
          );
          final theme = Theme.of(tester.element(content));
          expect(theme.brightness, Brightness.dark);
          expect(
            theme.dialogTheme.backgroundColor!.a,
            highContrast ? equals(1) : lessThan(1),
          );
          Navigator.of(tester.element(content)).pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('player popup follows its button and retains dark controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final anchor = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: IconButton(
                  key: anchor,
                  icon: const Icon(Icons.playlist_play),
                  onPressed: () => showPlayerPopover<void>(
                    context: context,
                    anchor: anchor,
                    builder: (_) => const Padding(
                      padding: EdgeInsets.all(16),
                      child: TextField(
                        decoration: InputDecoration(labelText: '搜索字幕'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final button = tester.getRect(find.byKey(anchor));
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(Theme.of(tester.element(field)).brightness, Brightness.dark);
    expect(
      Theme.of(tester.element(field)).inputDecorationTheme.fillColor,
      PlayerTheme.fieldColor,
    );
    final popup = tester.getRect(find.byType(PlayerGlass));
    expect(popup.bottom, lessThan(button.top));
    expect(popup.right, closeTo(button.right, .1));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist width follows content and stays inside the viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final widths = <double>[];
    for (final label in ['第 1 集 · 出发', '第 12 集 · 一段很长的单集小标题，需要更多宽度显示清楚']) {
      final anchor = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerTheme.surface(
            Scaffold(
              body: Builder(
                builder: (context) => Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: IconButton(
                      key: anchor,
                      icon: const Icon(Icons.playlist_play),
                      onPressed: () => showPlayerPopover<void>(
                        context: context,
                        anchor: anchor,
                        width: playerMenuWidth(context, [label]),
                        builder: (_) => ListView(
                          shrinkWrap: true,
                          children: [
                            ListTile(
                              title: Text(
                                label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(anchor));
      await tester.pumpAndSettle();
      final popup = tester.getRect(find.byType(PlayerGlass));
      widths.add(popup.width);
      expect(popup.width, lessThanOrEqualTo(400));
      expect(popup.left, greaterThanOrEqualTo(12));
      expect(
        popup.right,
        closeTo(tester.getRect(find.byKey(anchor)).right, .1),
      );
      Navigator.of(tester.element(find.byType(PlayerGlass))).pop();
      await tester.pumpAndSettle();
    }
    expect(widths.first, lessThan(widths.last));
    expect(widths.first, lessThan(300));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'player popup consumes the screen safe area before laying out tiles',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final (size, safePadding) in const [
        (Size(844, 390), EdgeInsets.only(left: 59, right: 24)),
        (Size(844, 390), EdgeInsets.only(left: 24, right: 59)),
        (Size(390, 844), EdgeInsets.only(top: 47, bottom: 34)),
      ]) {
        tester.view.physicalSize = size;
        final anchor = GlobalKey();
        const title = '第 12 集 · 一段较长的剧集标题';
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: safePadding, viewPadding: safePadding),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(80),
                    child: IconButton(
                      key: anchor,
                      icon: const Icon(Icons.playlist_play),
                      onPressed: () => showPlayerPopover<void>(
                        context: context,
                        anchor: anchor,
                        width: 280,
                        builder: (_) => ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(8),
                          children: const [
                            ListTile(
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              title: Text(title, maxLines: 2),
                              trailing: Icon(Icons.equalizer_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(anchor));
        await tester.pumpAndSettle();
        final popup = tester.getRect(find.byType(PlayerGlass));
        final text = tester.getRect(find.text(title));
        final playing = tester.getRect(find.byIcon(Icons.equalizer_rounded));
        expect(text.left - popup.left, closeTo(16, .1));
        expect(popup.right - playing.right, closeTo(16, .1));
        expect(popup.left, greaterThanOrEqualTo(safePadding.left + 12));
        expect(
          popup.right,
          lessThanOrEqualTo(size.width - safePadding.right - 12),
        );
        expect(popup.top, greaterThanOrEqualTo(safePadding.top + 12));
        expect(
          popup.bottom,
          lessThanOrEqualTo(size.height - safePadding.bottom - 12),
        );
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(PlayerGlass))).pop();
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'opted-in blur keeps its backdrop render object and cached filter during updates',
    (tester) async {
      Widget surface(String text) => MaterialApp(
        home: PlayerTheme.surface(
          Center(
            child: PlayerGlass(
              blur: true,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(text),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(surface('音量 50%'));
      final backdrop = find.byType(BackdropFilter);
      final element = tester.element(backdrop);
      final filter = tester.widget<BackdropFilter>(backdrop).filter;
      final renderObject = element.findRenderObject();
      await tester.pumpWidget(surface('音量 65%'));
      expect(tester.element(backdrop), same(element));
      expect(tester.widget<BackdropFilter>(backdrop).filter, same(filter));
      expect(tester.element(backdrop).findRenderObject(), same(renderObject));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested player choices and confirmations share glass styling', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerTheme.surface(
          Scaffold(
            body: Center(
              child: PlayerSelect<String>(
                label: '画面适配',
                value: 'contain',
                options: const [
                  GlassOption('contain', '完整显示'),
                  GlassOption('cover', '填满画面'),
                ],
                onChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('完整显示'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerGlass), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      Theme.of(
        tester.element(find.widgetWithText(PlayerChoiceTile, '填满画面')),
      ).brightness,
      Brightness.dark,
    );
    await tester.tap(find.widgetWithText(PlayerChoiceTile, '填满画面'));
    await tester.pumpAndSettle();
    expect(selected, 'cover');
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerTheme.surface(
          const PlayerDialog(
            title: Text('播放诊断'),
            content: Text('视频状态'),
            actions: [TextButton(onPressed: null, child: Text('关闭'))],
          ),
        ),
      ),
    );
    expect(find.byType(PlayerGlass), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.widget<Dialog>(find.byType(Dialog)).backgroundColor,
      Colors.transparent,
    );
    expect(tester.takeException(), isNull);
  });

  for (final sheet in [false, true]) {
    testWidgets(
      '${sheet ? 'sheet' : 'popover'} builds only visible rows in a long player menu',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final anchor = GlobalKey();
        final built = <int>{};
        int? selected;
        Widget menu(BuildContext context) => PlayerMenuList(
          itemCount: 1000,
          itemBuilder: (_, index) {
            built.add(index);
            return ListTile(
              minTileHeight: 48,
              title: Text('剧集 $index'),
              onTap: () => Navigator.pop(context, index),
            );
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: IconButton(
                      key: anchor,
                      icon: const Icon(Icons.playlist_play),
                      onPressed: () async {
                        selected = sheet
                            ? await showModalBottomSheet<int>(
                                context: context,
                                isScrollControlled: true,
                                builder: (c) => PlayerSheet(child: menu(c)),
                              )
                            : await showPlayerPopover<int>(
                                context: context,
                                anchor: anchor,
                                builder: menu,
                              );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(anchor));
        await tester.pumpAndSettle();
        expect(built.length, lessThan(40));
        expect(find.text('剧集 999'), findsNothing);
        expect(find.byType(BackdropFilter), findsNothing);
        final list = find.descendant(
          of: find.byType(PlayerMenuList),
          matching: find.byType(Scrollable),
        );
        final scroll = tester.state<ScrollableState>(list).position;
        expect(scroll.maxScrollExtent, greaterThan(10000));
        scroll.jumpTo(scroll.viewportDimension);
        await tester.pumpAndSettle();
        expect(built.length, lessThan(80));
        scroll.jumpTo(scroll.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('剧集 999'), findsOneWidget);
        await tester.tap(find.text('剧集 999'));
        await tester.pumpAndSettle();
        expect(selected, 999);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('long player choices stay lazy and select the final option', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerTheme.surface(
          Scaffold(
            body: Center(
              child: PlayerSelect<int>(
                label: '选择音轨',
                value: 0,
                options: [
                  for (var i = 0; i < 500; i++) GlassOption(i, '音轨 $i'),
                ],
                onChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('音轨 0'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerChoiceTile).evaluate().length, lessThan(30));
    expect(find.text('音轨 499'), findsNothing);
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(PlayerMenuList),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.text('音轨 499'));
    await tester.pumpAndSettle();
    expect(selected, 499);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard can consume the player sheet without handle overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(844, 390),
              viewInsets: EdgeInsets.only(bottom: 370),
            ),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: PlayerSheet(child: ListView(children: const [Text('字幕')])),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openQuickSettings(
  WidgetTester tester,
  _SettingsSession session,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => PlayerSheet(
                child: PlayerQuickSettings(
                  session: session,
                  onDanmaku: () {},
                  onDiagnostics: () {},
                ),
              ),
            ),
            child: const Text('打开高级设置'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开高级设置'));
  await tester.pumpAndSettle();
}

class _SettingsModel extends ChangeNotifier implements AppModel {
  final values = <String, dynamic>{};
  void applyChanges(Map<String, dynamic> changes) {
    values.addAll(changes);
    notifyListeners();
  }

  @override
  AppPreferences get preferences => AppPreferences(values);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MenuTextScaler extends TextScaler {
  const _MenuTextScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize < 10 ? 1 : 2.5);

  @override
  double get textScaleFactor => 2.5;
}

class _SettingsPlayer extends Fake implements Player {}

class _SettingsSession extends ChangeNotifier implements PlaybackSession {
  @override
  final _SettingsModel model = _SettingsModel();
  @override
  final player = _SettingsPlayer();
  final saves = <Completer<void>>[];
  @override
  Future<void> updateSettings(Map<String, dynamic> changes) async {
    final saved = Completer<void>();
    saves.add(saved);
    await saved.future;
    model.applyChanges(changes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
