import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/player_loading.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _view({bool visible = true, bool motion = true}) => MaterialApp(
  home: MotionScope(
    enabled: motion,
    child: TickerMode(
      enabled: visible,
      child: PlayerTheme.surface(const Center(child: PlayerLoading())),
    ),
  ),
);

void main() {
  for (final background in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    testWidgets('loading stops on $background without another frame', (
      tester,
    ) async {
      await tester.pumpWidget(_view());
      expect(tester.binding.transientCallbackCount, 1);
      expect(tester.getSize(find.byType(PlayerLoading)), const Size.square(76));
      expect(find.bySemanticsLabel('正在加载视频'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(background);
      // No pump: the background event itself must cancel the pending tick.
      expect(tester.binding.transientCallbackCount, 0);
      await tester.idle();
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(tester.binding.transientCallbackCount, 1);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets('loading respects initial background, visibility and motion', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(_view());
    tester.binding.scheduleForcedFrame();
    await tester.pump();
    expect(find.byType(PlayerLoading), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pumpWidget(_view(visible: false));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_view(motion: false));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(_view());
    expect(tester.binding.transientCallbackCount, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });
}
