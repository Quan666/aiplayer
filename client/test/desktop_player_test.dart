import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/playback/desktop_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('app.aiplayer/window_mode');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final desktopCalls = <MethodCall>[];
  final windowCalls = <MethodCall>[];

  Future<void> native(String method) {
    final complete = Completer<void>();
    messenger.handlePlatformMessage(
      DesktopWindow.channel.name,
      codec.encodeMethodCall(MethodCall(method)),
      (_) => complete.complete(),
    );
    return complete.future;
  }

  setUp(() {
    desktopCalls.clear();
    windowCalls.clear();
    messenger.setMockMethodCallHandler(DesktopWindow.channel, (call) async {
      desktopCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      return (call.arguments as Map)['enabled'];
    });
  });

  tearDown(() {
    DesktopWindow.watchClose(null);
    messenger.setMockMethodCallHandler(DesktopWindow.channel, null);
    messenger.setMockMethodCallHandler(windowChannel, null);
  });

  group('main desktop window', () {
    test('fullscreen works in the main window without a player-window flag', () async {
      expect(await DesktopWindow.setFullscreen(true), isTrue);
      expect(await DesktopWindow.setFullscreen(false), isFalse);
      expect(windowCalls.map((call) => call.method),
          ['setVideoFullscreen', 'setVideoFullscreen']);
      expect(windowCalls.map((call) => call.arguments),
          [{'enabled': true}, {'enabled': false}]);
      expect(desktopCalls, isEmpty);
    });

    test('close requests await cleanup and can be detached', () async {
      final cleanup = Completer<void>();
      var calls = 0;
      DesktopWindow.watchClose(() async {
        calls++;
        await cleanup.future;
      });
      var replied = false;
      final closing = native('closeRequested').then((_) => replied = true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(replied, isFalse);
      cleanup.complete();
      await closing;
      expect(replied, isTrue);
      DesktopWindow.watchClose(null);
      await native('closeRequested');
      expect(calls, 1);
    });

    testWidgets('application close waits for saved previews and runs once', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-close-');
      final store = AppStore('${root.path}/test.db');
      final model = _ClosingModel(store, root);
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pump();
        expect(desktopCalls.map((call) => call.method), ['ready']);
        final closing = native('closeRequested');
        await tester.pump();
        await tester.pump();
        expect(model.flushes, 1);
        expect(desktopCalls.where((call) => call.method == 'closeWindow'), isEmpty);
        await native('closeRequested');
        expect(model.flushes, 1);
        model.saved.complete();
        await tester.pump();
        await closing;
        expect(desktopCalls.map((call) => call.method), ['ready', 'closeWindow']);
        expect(tester.takeException(), isNull);
      } finally {
        if (!model.saved.isCompleted) model.saved.complete();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    });
  }, skip: !DesktopWindow.supported);
}

class _ClosingModel extends AppModel {
  final saved = Completer<void>();
  int flushes = 0;
  _ClosingModel(super.store, super.documents)
      : super(enableThumbnails: false, backgroundWork: false);

  @override
  Future<void> flushPlaybackPreviews() {
    flushes++;
    return saved.future;
  }
}
