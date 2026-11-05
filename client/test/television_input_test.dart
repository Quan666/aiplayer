import 'package:aiplayer/playback/input.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('remote OK activates focused controls only once when held', (
    tester,
  ) async {
    var activated = 0;
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              focusNode: focus,
              autofocus: true,
              onPressed: () => activated++,
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(activated, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(activated, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    expect(activated, 3);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });

  testWidgets('directions traverse controls, text fields retain normal input', (
    tester,
  ) async {
    final first = FocusNode(), second = FocusNode();
    final field = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: Scaffold(
          body: Column(
            children: [
              Row(
                children: [
                  ElevatedButton(
                    focusNode: first,
                    autofocus: true,
                    onPressed: () {},
                    child: const Text('一'),
                  ),
                  ElevatedButton(
                    focusNode: second,
                    onPressed: () {},
                    child: const Text('二'),
                  ),
                ],
              ),
              TextField(controller: field),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(second.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), '相册搜索');
    expect(field.text, '相册搜索');
    final context = tester.element(find.byType(TextField));
    expect(TelevisionMode.read(context), isTrue);
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
    field.dispose();
  });

  test('television player directions are contextual and release is inert', () {
    KeyEvent down(LogicalKeyboardKey key) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowLeft,
      logicalKey: key,
      timeStamp: Duration.zero,
    );
    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
    ]) {
      expect(
        televisionPlaybackAction(down(key), controlsVisible: true),
        'traverse',
      );
    }
    expect(
      televisionPlaybackAction(
        down(LogicalKeyboardKey.arrowLeft),
        controlsVisible: false,
      ),
      'seekBackward',
    );
    expect(
      televisionPlaybackAction(
        down(LogicalKeyboardKey.arrowRight),
        controlsVisible: false,
      ),
      'seekForward',
    );
    expect(
      televisionPlaybackAction(
        down(LogicalKeyboardKey.select),
        controlsVisible: false,
      ),
      'showControls',
    );
    expect(
      televisionPlaybackAction(
        down(LogicalKeyboardKey.select),
        controlsVisible: true,
      ),
      isNull,
    );
    const repeat = KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.select,
      timeStamp: Duration.zero,
    );
    expect(televisionPlaybackAction(repeat, controlsVisible: true), 'consume');
    const release = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.arrowLeft,
      logicalKey: LogicalKeyboardKey.arrowLeft,
      timeStamp: Duration.zero,
    );
    expect(televisionPlaybackAction(release, controlsVisible: false), isNull);
  });
}
