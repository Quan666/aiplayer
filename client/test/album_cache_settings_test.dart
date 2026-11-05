import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'advanced cache selectors save capacities and support keyboard selection',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-cache-settings-'),
      ))!;
      final store = AppStore(':memory:');
      final model = AppModel(store, directory, backgroundWork: false);
      Finder control(String label) => find.byWidgetPredicate(
        (widget) => widget is GlassSelect<int> && widget.label == label,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(body: SettingsPage(model: model)),
          ),
        );
        await tester.pumpAndSettle();
        expect(control('相册缩略图磁盘缓存'), findsNothing);
        expect(control('图片内存缓存'), findsNothing);
        final advanced = find.widgetWithText(ChoiceChip, '高级');
        await tester.ensureVisible(advanced);
        await tester.tap(advanced);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const PageStorageKey('settings-advanced')),
          findsOneWidget,
        );
        expect(
          tester.widget<GlassSelect<int>>(control('相册缩略图磁盘缓存')).value,
          512,
        );
        expect(
          tester.widget<GlassSelect<int>>(control('相册大图磁盘缓存')).value,
          1024,
        );
        expect(tester.widget<GlassSelect<int>>(control('图片内存缓存')).value, 100);
        expect(tester.widget<GlassSelect<int>>(control('相册信息缓存')).value, 16);
        expect(tester.widget<GlassSelect<int>>(control('外部打开临时缓存')).value, 512);
        for (final (label, value) in [
          ('图片内存缓存', 256),
          ('相册缩略图磁盘缓存', 8192),
          ('相册大图磁盘缓存', 4096),
          ('相册信息缓存', 64),
          ('外部打开临时缓存', 8192),
        ]) {
          await tester.ensureVisible(control(label));
          final input = find.descendant(
            of: control(label),
            matching: find.byType(InputDecorator),
          );
          Focus.of(tester.element(input)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          final choice = find.widgetWithText(
            ListTile,
            value % 1024 == 0 ? '${value ~/ 1024} GiB' : '$value MiB',
          );
          await tester.ensureVisible(choice);
          Focus.of(
            tester.element(
              find.descendant(of: choice, matching: find.byType(Text)).first,
            ),
          ).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(tester.widget<GlassSelect<int>>(control(label)).value, value);
        }
        expect(store.local('settings')['albumThumbnailCacheMiB'], 8192);
        expect(model.preferences.albumThumbnailCacheBytes, 8589934592);
        expect(store.local('settings')['albumOriginalCacheMiB'], 4096);
        expect(store.local('settings')['decodedImageCacheMiB'], 256);
        expect(store.local('settings')['albumMetadataCacheMiB'], 64);
        expect(store.local('settings')['externalFileCacheMiB'], 8192);
        await tester.tap(find.byTooltip('搜索设置'));
        await tester.pumpAndSettle();
        final search = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '搜索设置',
        );
        await tester.enterText(search, '缩略图');
        await tester.pumpAndSettle();
        expect(control('相册缩略图磁盘缓存'), findsOneWidget);
        expect(find.text('外观'), findsNothing);
        expect(find.text('作品资料'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        await tester.runAsync(model.flushMetadataTasks);
        store.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
