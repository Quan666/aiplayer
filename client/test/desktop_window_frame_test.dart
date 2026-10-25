import 'dart:async';

import 'package:aiplayer/playback/desktop_window.dart';
import 'package:aiplayer/ui/desktop_window_frame.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  final calls = <String>[];

  Future<void> nativeState({bool fullscreen = false, bool maximized = false}) {
    final reply = Completer<void>();
    messenger.handlePlatformMessage(
      DesktopWindow.channel.name,
      codec.encodeMethodCall(
        MethodCall('windowStateChanged', {
          'fullscreen': fullscreen,
          'maximized': maximized,
        }),
      ),
      (_) => reply.complete(),
    );
    return reply.future;
  }

  Widget app(Widget child) => MaterialApp(
    theme: AppTheme.theme(),
    builder: (context, child) => DesktopWindowFrame(child: child!),
    home: Scaffold(body: SafeArea(child: child)),
  );

  setUp(() {
    calls.clear();
    DesktopWindow.watchClose(() async {});
    messenger.setMockMethodCallHandler(DesktopWindow.channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    DesktopWindow.watchClose(null);
    messenger.setMockMethodCallHandler(DesktopWindow.channel, null);
  });

  testWidgets(
    'desktop controls use native actions and reserve safe content',
    (tester) async {
      await tester.pumpWidget(app(const TextField()));
      expect(tester.getTopLeft(find.byType(TextField)).dy, 36);
      expect(tester.getTopLeft(find.byType(Scaffold)).dy, 0);
      await tester.tap(find.byTooltip('最小化'));
      await tester.tap(find.byTooltip('最大化'));
      await tester.tap(find.byTooltip('关闭窗口'));
      expect(calls, ['minimize', 'toggleMaximize', 'requestClose']);
      // The close button must not bypass application cleanup.
      expect(calls, isNot(contains('closeWindow')));
      await nativeState(maximized: true);
      await tester.pump();
      expect(find.byTooltip('还原窗口'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets('fullscreen hides chrome without losing input or page state', (
    tester,
  ) async {
    await tester.pumpWidget(app(const TextField()));
    await tester.enterText(find.byType(TextField), '保留搜索');
    final before = tester.state(find.byType(TextField));
    await nativeState(fullscreen: true);
    await tester.pump();
    expect(find.byKey(const ValueKey('desktop-window-drag')), findsNothing);
    expect(find.byTooltip('关闭窗口'), findsNothing);
    expect(tester.getTopLeft(find.byType(TextField)).dy, 0);
    await nativeState();
    await tester.pump();
    expect(tester.state(find.byType(TextField)), same(before));
    expect(find.text('保留搜索'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(TextField)).dy, 36);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets(
    'macOS reserves native lights and supports drag and double click',
    (tester) async {
      await tester.pumpWidget(app(const Text('内容')));
      final drag = find.byKey(const ValueKey('desktop-window-drag'));
      expect(tester.getTopLeft(drag).dx, 80);
      expect(find.byTooltip('关闭窗口'), findsNothing);
      await tester.drag(
        drag,
        const Offset(80, 0),
        kind: PointerDeviceKind.mouse,
      );
      expect(calls, ['startDrag']);
      calls.clear();
      await tester.tap(drag);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(drag);
      await tester.pump(const Duration(milliseconds: 80));
      expect(calls, ['toggleMaximize']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'mobile layout keeps its existing insets and controls',
    (tester) async {
      await tester.pumpWidget(app(const TextField()));
      expect(find.byKey(const ValueKey('desktop-window-drag')), findsNothing);
      expect(tester.getTopLeft(find.byType(TextField)).dy, 0);
      expect(calls, isEmpty);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('window state is event driven and unchanged events stay silent', (
    tester,
  ) async {
    var notifications = 0;
    void changed() => notifications++;
    DesktopWindow.state.addListener(changed);
    addTearDown(() => DesktopWindow.state.removeListener(changed));
    await tester.pumpWidget(app(const Text('内容')));
    await nativeState();
    expect(notifications, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // No pump: native events still update state while the window has no vsync.
    await nativeState(fullscreen: true);
    await nativeState(fullscreen: true);
    expect(DesktopWindow.state.value.fullscreen, isTrue);
    expect(notifications, 1);
    expect(calls, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byKey(const ValueKey('desktop-window-drag')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
