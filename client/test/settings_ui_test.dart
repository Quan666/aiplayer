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
  for (final size in [const Size(390, 844), const Size(1366, 900)]) {
    testWidgets('settings search and bounded selectors at $size', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-settings-');
      final store = AppStore(':memory:');
      final model = AppModel(store, root);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索设置'));
        await tester.pumpAndSettle();
        final search = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == '搜索设置',
        );
        await tester.enterText(search, '倍速');
        await tester.pumpAndSettle();
        expect(find.text('默认倍速'), findsOneWidget);
        final selector = find.byWidgetPredicate(
          (w) => w is GlassSelect<double> && w.label == '默认倍速',
        );
        await tester.ensureVisible(selector);
        await tester.pumpAndSettle();
        await tester.tap(selector);
        await tester.pumpAndSettle();
        final choice = find.widgetWithText(ListTile, '2.25×');
        await tester.ensureVisible(choice);
        await tester.pumpAndSettle();
        expect(tester.getRect(choice).bottom, lessThanOrEqualTo(size.height));
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(model.preferences.playbackRate, 2.25);
        expect(find.text('2.25×'), findsOneWidget);
        await tester.ensureVisible(search);
        await tester.enterText(search, '字幕');
        await tester.pumpAndSettle();
        await tester.tap(find.text('默认显示字幕'));
        await tester.pumpAndSettle();
        expect(model.preferences.subtitlesEnabled, false);
        await tester.ensureVisible(search);
        await tester.enterText(search, '标题');
        await tester.pumpAndSettle();
        expect(find.text('字幕、剧集标题和影视简介共用 API、模型与目标语言。'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'API 地址',
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(search);
        await tester.enterText(search, '日志');
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('运行日志'));
        await tester.tap(find.text('运行日志'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('搜索日志'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.ensureVisible(search);
        await tester.enterText(search, '不存在的设置');
        await tester.pumpAndSettle();
        expect(find.text('没有匹配的设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(store.pending, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      }
    });
  }

  testWidgets('shortcut capture saves a custom modifier combination', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('aiplayer-shortcuts-');
    final store = AppStore(':memory:');
    final model = AppModel(store, root);
    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      final chip = find.widgetWithText(ChoiceChip, '播放');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(ListTile, '播放 / 暂停'),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('settings-playback')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '播放 / 暂停'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Ctrl+P'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(model.preferences.shortcuts['playPause'], 'Ctrl+P');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });
}
