import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';

void main() {
  testWidgets('empty library and settings are usable on a narrow screen', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore(':memory:'),
        directory = Directory.systemTemp.createTempSync('aiplayer-widget-');
    final model = AppModel(store, directory);
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    expect(find.text('我的影视库'), findsOneWidget);
    expect(find.text('导入视频'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('浅色'), findsOneWidget);
    expect(find.byTooltip('搜索设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
