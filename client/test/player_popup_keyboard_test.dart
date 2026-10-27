import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final kind in ['sheet', 'dialog', 'popover', 'settings']) {
    for (final focus in ['unfocus', 'editing', 'macOS editing', 'tooltip']) {
      testWidgets(
        '$kind closes with Escape after $focus',
        (tester) async {
          final anchor = GlobalKey();
          final popup = GlobalKey();
          final tooltip = GlobalKey<TooltipState>();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => Align(
                    alignment: Alignment.bottomRight,
                    child: TextButton(
                      key: anchor,
                      onPressed: () {
                        Widget content(BuildContext context) => SizedBox(
                          key: popup,
                          width: 240,
                          height: 120,
                          child: Tooltip(
                            key: tooltip,
                            message: '提示',
                            triggerMode: TooltipTriggerMode.manual,
                            child: const TextField(),
                          ),
                        );
                        switch (kind) {
                          case 'sheet':
                            showModalBottomSheet<void>(
                              context: context,
                              builder: (context) =>
                                  PlayerSheet(child: content(context)),
                            );
                          case 'dialog':
                            showDialog<void>(
                              context: context,
                              builder: (context) => PlayerDialog(
                                title: const Text('播放诊断'),
                                content: content(context),
                              ),
                            );
                          case 'popover':
                            showPlayerPopover<void>(
                              context: context,
                              anchor: anchor,
                              builder: content,
                            );
                          case 'settings':
                            showPlayerSettingsMenu<void>(
                              context: context,
                              builder: content,
                            );
                        }
                      },
                      child: const Text('打开'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byKey(anchor));
          await tester.pumpAndSettle();
          if (focus.endsWith('editing')) {
            await tester.enterText(find.byType(TextField), '保留输入');
          } else if (focus == 'tooltip') {
            tooltip.currentState!.ensureTooltipVisible();
            await tester.pumpAndSettle();
            expect(find.text('提示'), findsOneWidget);
          } else {
            // The danmaku tab dismisses keyboard focus. A route scope may be
            // the primary focus even when no text field has been touched.
            FocusManager.instance.primaryFocus?.unfocus();
          }
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(popup), findsNothing);
          expect(find.byKey(anchor), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          focus == 'macOS editing'
              ? TargetPlatform.macOS
              : TargetPlatform.linux,
        }),
      );
    }
  }

  testWidgets('Escape closes only the nested choice and ignores held repeats', (
    tester,
  ) async {
    var changed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => PlayerSheet(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const TextField(),
                      PlayerSelect<String>(
                        label: '画面适配',
                        value: 'contain',
                        options: const [
                          GlassOption('contain', '完整显示'),
                          GlassOption('cover', '填满画面'),
                        ],
                        onChanged: (_) => changed = true,
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '草稿');
    await tester.tap(find.byType(PlayerSelect<String>));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('填满画面'), findsNothing);
    expect(find.byType(PlayerSelect<String>), findsOneWidget);
    expect(find.text('草稿'), findsOneWidget);
    expect(changed, isFalse);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSelect<String>), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSheet), findsNothing);
    expect(find.text('打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
