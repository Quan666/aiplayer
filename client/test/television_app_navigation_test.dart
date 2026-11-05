import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const platform = TargetPlatformVariant({TargetPlatform.android});
  testWidgets('real app detects television and switches all tabs using keys', (
    tester,
  ) async {
    final fixture = _AppFixture(tester);
    await fixture.mount();
    expect(fixture.deviceInfoCalls, 1);
    expect(
      TelevisionMode.read(tester.element(find.byType(LibraryPage))),
      isTrue,
    );
    expect(find.byKey(const ValueKey('bottom-navigation')), findsOneWidget);

    await fixture.openNavigation();
    expect(fixture.tab(0).hasFocus, isTrue);
    await fixture.press(LogicalKeyboardKey.arrowRight);
    expect(fixture.tab(1).hasFocus, isTrue);
    await fixture.press(LogicalKeyboardKey.select);
    expect(find.text('本地视频'), findsOneWidget);
    expect(fixture.tab(1).hasFocus, isFalse);

    await fixture.openNavigation();
    expect(fixture.tab(1).hasFocus, isTrue);
    await fixture.press(LogicalKeyboardKey.arrowRight);
    expect(fixture.tab(2).hasFocus, isTrue);
    await fixture.press(LogicalKeyboardKey.select);
    expect(find.text('外观与文件'), findsOneWidget);
    expect(fixture.tab(2).hasFocus, isFalse);

    await fixture.openNavigation();
    expect(fixture.tab(2).hasFocus, isTrue);
    await fixture.press(LogicalKeyboardKey.arrowLeft);
    await fixture.press(LogicalKeyboardKey.arrowLeft);
    expect(fixture.tab(0).hasFocus, isTrue);
    await fixture.press(LogicalKeyboardKey.select);
    expect(find.text('我的影视库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platform);

  testWidgets('down reaches bottom navigation in the real empty app', (
    tester,
  ) async {
    final fixture = _AppFixture(tester);
    await fixture.mount();
    for (var i = 0; i < 20 && !fixture.tab(0).hasFocus; i++) {
      await fixture.press(LogicalKeyboardKey.arrowDown);
    }
    expect(fixture.tab(0).hasFocus, isTrue);
    await fixture.press(LogicalKeyboardKey.arrowRight);
    await fixture.press(LogicalKeyboardKey.select);
    expect(find.text('本地视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platform);

  testWidgets(
    'menu can recover bottom navigation after primary focus is lost',
    (tester) async {
      final fixture = _AppFixture(tester);
      await fixture.mount();
      await fixture.clearFocus();
      await fixture.openNavigation();
      expect(fixture.tab(0).hasFocus, isTrue);
      await fixture.press(LogicalKeyboardKey.arrowRight);
      await fixture.press(LogicalKeyboardKey.select);
      expect(find.text('本地视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: platform,
  );

  testWidgets('two menu presses tolerate focus movement within the shell', (
    tester,
  ) async {
    final fixture = _AppFixture(tester);
    await fixture.mount();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    final firstFocus = FocusManager.instance.primaryFocus;
    firstFocus?.nextFocus();
    await tester.pump(const Duration(milliseconds: 450));
    expect(FocusManager.instance.primaryFocus, isNot(firstFocus));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(fixture.tab(0).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: platform);

  testWidgets('menu repeats do not open navigation, two presses do', (
    tester,
  ) async {
    final fixture = _AppFixture(tester);
    await fixture.mount();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.contextMenu);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(fixture.tab(0).hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 800));
    await fixture.openNavigation();
    expect(fixture.tab(0).hasFocus, isTrue);
    final beforeBack = find.text('我的影视库');
    expect(beforeBack, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fixture.tab(0).hasFocus, isFalse);
    expect(beforeBack, findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platform);

  testWidgets('lost focus inside a modal cannot open the shell navigation', (
    tester,
  ) async {
    final fixture = _AppFixture(tester);
    await fixture.mount();
    final context = tester.element(find.byType(LibraryPage));
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('弹层保持操作权'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭弹层'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await fixture.clearFocus();
    await fixture.openNavigation();
    expect(find.text('弹层保持操作权'), findsOneWidget);
    expect(fixture.tab(0).hasFocus, isFalse);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await fixture.openNavigation();
    expect(fixture.tab(0).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: platform);
}

class _AppFixture {
  final WidgetTester tester;
  final directory = Directory.systemTemp.createTempSync('aiplayer-tv-app-');
  final store = AppStore(':memory:');
  late final model = AppModel(store, directory);
  int deviceInfoCalls = 0;
  static const _deviceInfo = MethodChannel('app.aiplayer/device_info');

  _AppFixture(this.tester) {
    FlutterSecureStorage.setMockInitialValues({});
    store.setLocal('settings', {'metadataStrategy': 'off'});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _deviceInfo,
      (call) async {
        if (call.method == 'getDeviceInfo') {
          deviceInfoCalls++;
          return {'isTelevision': true};
        }
        return null;
      },
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _deviceInfo,
        null,
      );
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  FocusNode tab(int index) => tester
      .widget<InkWell>(
        find
            .ancestor(
              of: find.byKey(ValueKey('nav-item-$index')),
              matching: find.byType(InkWell),
            )
            .first,
      )
      .focusNode!;

  Future<void> mount() async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    expect(
      TelevisionMode.read(tester.element(find.byType(LibraryPage))),
      isTrue,
    );
  }

  Future<void> press(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> clearFocus() async {
    for (
      var i = 0;
      i < 12 &&
          FocusManager.instance.primaryFocus != FocusManager.instance.rootScope;
      i++
    ) {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    }
    expect(FocusManager.instance.primaryFocus, FocusManager.instance.rootScope);
  }

  Future<void> openNavigation() async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
  }
}
