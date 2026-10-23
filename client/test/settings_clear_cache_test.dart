import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _CacheModel extends AppModel {
  final operations = <Completer<void>>[];

  _CacheModel(super.store, super.documents);

  @override
  Future<void> clearCaches() {
    final operation = Completer<void>();
    operations.add(operation);
    return operation.future;
  }
}

void main() {
  late Directory root;
  late AppStore store;
  late _CacheModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('aiplayer-settings-cache-');
    store = AppStore(':memory:');
    model = _CacheModel(store, root);
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  final action = find.byKey(const ValueKey('clear-caches'));
  final search = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.hintText == '搜索设置',
  );
  final keyField = find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'TMDB API Key / 读取令牌',
  );
  const success = '缓存已清除，重新进入文件夹即可重新加载';

  Future<void> mount(
    WidgetTester tester, {
    _CacheModel? replacement,
    bool active = true,
  }) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: Scaffold(
          body: SettingsPage(
            key: const ValueKey('settings'),
            model: replacement ?? model,
            active: active,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> searchFor(WidgetTester tester, String query) async {
    if (search.evaluate().isEmpty) {
      await tester.tap(find.byTooltip('搜索设置'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(search, query);
    await tester.pumpAndSettle();
    await tester.ensureVisible(action);
  }

  testWidgets('cache action is searchable, guarded and preserves drafts', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await tester.ensureVisible(keyField);
    await tester.enterText(keyField, 'unsaved-api-key');

    await searchFor(tester, '缓存');
    expect(find.text('关于与维护'), findsOneWidget);
    expect(find.text('识别、目录与图片缓存；保留来源、影视库、播放记录和手动匹配。'), findsOneWidget);
    final callback = tester.widget<ListTile>(action).onTap!;
    await tester.tap(action);
    // A second event can arrive before Flutter rebuilds the disabled tile.
    callback();
    await tester.pump();
    expect(model.operations, hasLength(1));
    expect(find.text('清理中…'), findsOneWidget);
    expect(tester.widget<ListTile>(action).enabled, isFalse);
    expect(tester.widget<ListTile>(action).onTap, isNull);
    await tester.tap(action);
    expect(model.operations, hasLength(1));

    model.operations.single.complete();
    await tester.pumpAndSettle();
    expect(find.text(success), findsOneWidget);
    expect(tester.widget<ListTile>(action).enabled, isTrue);
    await searchFor(tester, '清理');
    expect(find.text('一键清除缓存'), findsOneWidget);
    await tester.enterText(search, 'TMDB');
    await tester.pumpAndSettle();
    await tester.ensureVisible(keyField);
    expect(
      tester.widget<TextField>(keyField).controller!.text,
      'unsaved-api-key',
    );
    expect(await model.secrets.read(key: 'tmdb.apiKey'), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed cache clearing is reported and can be retried', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await searchFor(tester, '缓存');
    await tester.tap(action);
    model.operations.single.completeError(const AppFailure('缓存清理测试失败'));
    await tester.pumpAndSettle();
    expect(find.text('缓存清理测试失败'), findsOneWidget);
    expect(tester.widget<ListTile>(action).enabled, isTrue);
    await tester.tap(action);
    expect(model.operations, hasLength(2));
    model.operations.last.complete();
    await tester.pumpAndSettle();
    expect(find.text(success), findsOneWidget);
    expect(find.text('缓存清理测试失败'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disposed settings ignore late cache clearing completion', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await searchFor(tester, '缓存');
    await tester.tap(action);
    await tester.pumpWidget(const SizedBox());
    model.operations.single.completeError(const AppFailure('已离开的操作失败'));
    await tester.pumpAndSettle();
    expect(find.text(success), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old model completion cannot reset a new model operation', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final replacementStore = AppStore(':memory:');
    final replacement = _CacheModel(replacementStore, root);
    addTearDown(() {
      replacement.dispose();
      replacementStore.dispose();
    });
    await mount(tester);
    await searchFor(tester, '缓存');
    await tester.tap(action);
    await tester.pump();
    await mount(tester, replacement: replacement);
    expect(tester.widget<ListTile>(action).enabled, isTrue);
    await tester.tap(action);
    await tester.pump();
    expect(replacement.operations, hasLength(1));

    model.operations.single.complete();
    await tester.pumpAndSettle();
    expect(find.text(success), findsNothing);
    expect(tester.widget<ListTile>(action).enabled, isFalse);
    replacement.operations.single.complete();
    await tester.pumpAndSettle();
    expect(find.text(success), findsOneWidget);
    expect(tester.widget<ListTile>(action).enabled, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inactive settings do not show late result on another page', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await searchFor(tester, '缓存');
    await tester.tap(action);
    await mount(tester, active: false);
    model.operations.single.complete();
    await tester.pumpAndSettle();
    expect(find.text(success), findsNothing);
    await mount(tester);
    expect(tester.widget<ListTile>(action).enabled, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
