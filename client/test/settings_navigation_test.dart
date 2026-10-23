import 'dart:io';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RefreshModel extends AppModel {
  int refreshes = 0;
  _RefreshModel(super.store, super.documents);
  @override
  Future<void> refreshMetadata() async {
    refreshes++;
  }
}

void main() {
  testWidgets(
    'settings swipe between groups, persist hidden preference and private TMDB key',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-setting-pages-',
      );
      final store = AppStore(':memory:');
      store.setLocal('sources', [
        {'id': 'nas', 'kind': 'smb'},
        {'id': 'web', 'kind': 'webdav'},
      ]);
      store.setLocal('directory-preview:nas', {'sourceId': 'nas'});
      store.setLocal('directory-preview:web', {'sourceId': 'web'});
      store.setLocal('directory-preview:other', {'sourceId': 'other'});
      final model = AppModel(store, root);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(body: SettingsPage(model: model)),
          ),
        );
        await tester.pumpAndSettle();
        expect(model.preferences.hideHiddenFiles, true);
        await tester.tap(find.text('不显示隐藏文件和文件夹'));
        await tester.pumpAndSettle();
        expect(model.preferences.hideHiddenFiles, false);
        expect(find.text('作品资料'), findsOneWidget);
        final key = find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText == 'TMDB API Key / 读取令牌',
        );
        await tester.ensureVisible(key);
        await tester.enterText(key, 'private-test-key');
        final save = find.widgetWithText(FilledButton, '保存');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(
          await model.secrets.read(key: 'tmdb.apiKey'),
          'private-test-key',
        );
        expect(model.settings.toString(), isNot(contains('private-test-key')));
        expect(store.local('directory-preview:nas'), isNull);
        expect(store.local('directory-preview:web'), isNull);
        expect(store.local('directory-preview:other'), isNotNull);
        expect(store.local('metadataCredentialsRevision'), isA<int>());
        expect(store.pending, isEmpty);
        expect(find.widgetWithText(SnackBar, '资料配置已保存'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SettingsPage),
            matching: find.text('资料配置已保存'),
          ),
          findsNothing,
        );
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text('资料配置已保存'), findsNothing);
        final pages = find.byKey(const ValueKey('settings-pages'));
        await tester.dragFrom(
          tester.getTopLeft(pages) + const Offset(700, 12),
          const Offset(-600, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('默认倍速'), findsOneWidget);
        await tester.dragFrom(
          tester.getTopLeft(pages) + const Offset(40, 12),
          const Offset(600, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('作品资料'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'joint metadata search keeps Bangumi available and AI fallback is opt-in',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-settings-metadata-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataProvider': 'tmdb'});
      final model = _RefreshModel(store, root);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(body: SettingsPage(model: model)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('资料来源'), findsNothing);
        expect(find.text('TMDB 译名辅助'), findsNothing);
        expect(find.textContaining('Bangumi + TMDB 联合检索'), findsNothing);
        expect(model.preferences.aiMetadataEnabled, isFalse);
        await tester.ensureVisible(find.text('AI 自动识别信息'));
        await tester.tap(find.text('AI 自动识别信息'));
        await tester.pumpAndSettle();
        expect(model.preferences.aiMetadataEnabled, isTrue);
        await tester.ensureVisible(find.text('识别未匹配的视频'));
        await tester.tap(find.text('识别未匹配的视频'));
        await tester.pumpAndSettle();
        expect(model.refreshes, 1);
        expect(find.textContaining('请先填写并保存 TMDB'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('danmaku and sync forms save independently after regrouping', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'danmuToken': 'saved-danmaku-token',
      'syncToken': 'saved-sync-token-with-24-characters',
    });
    final root = Directory.systemTemp.createTempSync('aiplayer-settings-save-');
    final store = AppStore(':memory:');
    final model = AppModel(store, root);
    await model.setSettings({
      'danmuOrigin': 'https://danmaku.example',
      'refreshInterval': 60,
      'syncOrigin': 'https://sync.example',
    });
    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    Future<void> group(String label) async {
      final chip = find.widgetWithText(ChoiceChip, label);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }

    Future<void> revealDanmaku(Finder target) async {
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('settings-danmaku')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(body: SettingsPage(model: model)),
        ),
      );
      await tester.pumpAndSettle();
      await group('弹幕');
      expect(find.text('局域网'), findsNothing);
      await revealDanmaku(field('更新间隔 / 秒'));
      await tester.enterText(field('更新间隔 / 秒'), '5');
      await tester.enterText(field('Token'), 'draft-danmaku-token');
      await group('同步');
      await tester.enterText(field('同步服务地址'), 'https://new-sync.example');
      await tester.tap(find.text('保存同步配置'));
      await tester.pumpAndSettle();
      expect(model.settings['syncOrigin'], 'https://new-sync.example');
      expect(find.widgetWithText(SnackBar, '同步配置已保存'), findsOneWidget);
      expect(model.preferences.refreshInterval, 60);
      expect(
        await model.secrets.read(key: 'danmuToken'),
        'saved-danmaku-token',
      );
      await group('弹幕');
      await revealDanmaku(field('更新间隔 / 秒'));
      expect(tester.widget<TextField>(field('更新间隔 / 秒')).controller!.text, '5');
      await tester.enterText(field('更新间隔 / 秒'), '120');
      await revealDanmaku(find.text('保存弹幕服务'));
      await tester.tap(find.text('保存弹幕服务'));
      await tester.pumpAndSettle();
      expect(model.preferences.refreshInterval, 120);
      expect(find.widgetWithText(SnackBar, '弹幕服务配置已保存'), findsOneWidget);
      expect(find.text('同步配置已保存'), findsNothing);
      expect(
        await model.secrets.read(key: 'danmuToken'),
        'draft-danmaku-token',
      );
      expect(model.settings['syncOrigin'], 'https://new-sync.example');
      expect(
        await model.secrets.read(key: 'syncToken'),
        'saved-sync-token-with-24-characters',
      );
      expect(model.settings.toString(), isNot(contains('token')));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });
}
