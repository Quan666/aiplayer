import 'package:aiplayer/ui/player_theme.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'TV player menu selects with arrows and OK, then restores focus',
    (tester) async {
      final anchor = GlobalKey();
      final trigger = FocusNode();
      int? choice;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TelevisionInputScope(overrideTelevision: true, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  key: anchor,
                  focusNode: trigger,
                  autofocus: true,
                  onPressed: () async {
                    choice = await showPlayerPopover<int>(
                      context: context,
                      anchor: anchor,
                      builder: (context) => PlayerMenuList(
                        itemCount: 4,
                        itemExtent: 44,
                        selectedIndex: 2,
                        itemBuilder: (context, index) => PlayerChoiceTile(
                          selected: index == 2,
                          title: Text(index == 0 ? '播放速度' : '$index 倍'),
                          onTap: index == 0
                              ? null
                              : () => Navigator.pop(context, index),
                        ),
                      ),
                    );
                  },
                  child: const Text('速度'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(choice, 3);
      expect(trigger.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      trigger.dispose();
    },
  );

  testWidgets('TV Back closes player popup once, preserving its parent', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              autofocus: true,
              onPressed: () => showPlayerSettingsMenu<void>(
                context: context,
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => PlayerDialog(
                      title: const Text('播放诊断'),
                      content: const Text('详细信息'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('打开诊断'),
                ),
              ),
              child: const Text('设置'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('详细信息'), findsOneWidget);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.text('详细信息'), findsNothing);
    expect(find.text('打开诊断'), findsOneWidget);
    await tester.sendKeyRepeatEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.text('打开诊断'), findsOneWidget);
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.text('打开诊断'), findsOneWidget);
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(find.text('打开诊断'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
