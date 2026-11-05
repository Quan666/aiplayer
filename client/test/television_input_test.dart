import 'package:aiplayer/playback/input.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'synthetic menu release cancels the hold without blocking the next press',
    (tester) async {
      var menus = 0, navigation = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TelevisionInputScope(overrideTelevision: true, child: child!),
          home: TelevisionNavigationHost(
            onNavigation: () => navigation++,
            navigationActive: false,
            child: Scaffold(
              body: TelevisionAction(
                onActivate: () {},
                onMenu: () => menus++,
                builder: (context, focus) => TextButton(
                  focusNode: focus,
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('项目'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      void down() => HardwareKeyboard.instance.handleKeyEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.contextMenu,
          logicalKey: LogicalKeyboardKey.contextMenu,
          timeStamp: Duration.zero,
        ),
      );
      void up({bool synthesized = false}) =>
          HardwareKeyboard.instance.handleKeyEvent(
            KeyUpEvent(
              physicalKey: PhysicalKeyboardKey.contextMenu,
              logicalKey: LogicalKeyboardKey.contextMenu,
              timeStamp: Duration.zero,
              synthesized: synthesized,
            ),
          );
      down();
      up(synthesized: true);
      await tester.pump(const Duration(milliseconds: 700));
      expect(menus, 0);
      down();
      up();
      await tester.pump(const Duration(milliseconds: 450));
      down();
      up();
      expect(navigation, 1);
      expect(menus, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'covering the shell discards a pending menu even after returning',
    (tester) async {
      var menus = 0, navigation = 0;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) =>
              TelevisionInputScope(overrideTelevision: true, child: child!),
          home: TelevisionNavigationHost(
            onNavigation: () => navigation++,
            navigationActive: false,
            child: Scaffold(
              body: TelevisionAction(
                onActivate: () {},
                onMenu: () => menus++,
                builder: (context, focus) => TextButton(
                  focusNode: focus,
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('项目'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      showDialog<void>(
        context: tester.element(find.text('项目')),
        builder: (_) => const AlertDialog(content: Text('弹层')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      expect(menus, 0);
      expect(navigation, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      expect(navigation, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final heldKey in [
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.contextMenu,
  ]) {
    testWidgets(
      'held ${heldKey.debugName} opens a navigable menu and release does not activate it',
      (tester) async {
        var opens = 0;
        var selected = -1;
        var trailing = 0;
        final rowFocus = FocusNode();
        final trailingFocus = FocusNode();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) =>
                TelevisionInputScope(overrideTelevision: true, child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return TelevisionAction(
                    focusNode: rowFocus,
                    onActivate: () => opens++,
                    onMenu: () => showGlassBottomSheet<void>(
                      context: context,
                      builder: (context) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(
                          3,
                          (index) => ListTile(
                            title: Text('操作 $index'),
                            onTap: () {
                              selected = index;
                              Navigator.pop(context);
                            },
                          ),
                        ),
                      ),
                    ),
                    builder: (context, focus) => ListTile(
                      autofocus: true,
                      focusNode: focus,
                      title: const Text('文件夹'),
                      onTap: () => opens++,
                      trailing: IconButton(
                        focusNode: trailingFocus,
                        onPressed: () => trailing++,
                        icon: const Icon(Icons.info),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(heldKey);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(opens, 0);
        expect(find.text('操作 0'), findsOneWidget);
        expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<ListTile>()
              ?.title,
          isA<Text>().having((text) => text.data, 'label', '操作 0'),
        );
        await tester.sendKeyRepeatEvent(heldKey);
        await tester.sendKeyUpEvent(heldKey);
        expect(selected, -1);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(selected, 1);
        expect(rowFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        expect(opens, 1);
        trailingFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        expect(trailing, 1);
        expect(opens, 1);
        await tester.pumpWidget(const SizedBox());
        rowFocus.dispose();
        trailingFocus.dispose();
      },
    );
  }

  testWidgets('menu double press is distinct from single and held menu', (
    tester,
  ) async {
    var menus = 0;
    var navigation = 0;
    var headers = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: TelevisionMenuRegion(
          onMenu: () => headers++,
          onNavigation: () => navigation++,
          child: Scaffold(
            body: TelevisionAction(
              onActivate: () {},
              onMenu: () => menus++,
              builder: (context, focus) => TextButton(
                focusNode: focus,
                autofocus: true,
                onPressed: () {},
                child: const Text('项目'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 350));
    expect(navigation, 1);
    expect(menus, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.contextMenu);
    expect(menus, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    expect(menus, 1);
    await tester.pump(TelevisionInputScope.menuDoublePressInterval);
    expect(menus, 1);
    expect(navigation, 1);
    expect(headers, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(TelevisionInputScope.menuDoublePressInterval);
    expect(headers, 1);
    expect(menus, 1);

    // A pending action must be cancelled synchronously on pause, with no frame.
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.binding.delayed(const Duration(milliseconds: 800));
    expect(menus, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.binding.delayed(const Duration(milliseconds: 700));
    expect(menus, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.binding.delayed(const Duration(milliseconds: 700));
    expect(menus, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('short Menu reaches header and Down restores a lazy list row', (
    tester,
  ) async {
    final header = FocusNode();
    final toolbar = FocusNode();
    final scroll = ScrollController();
    var menus = 0;
    final built = <int>{};
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: Scaffold(
          body: TelevisionHeaderNavigation(
            headerFocusNode: header,
            child: CustomScrollView(
              controller: scroll,
              scrollCacheExtent: const ScrollCacheExtent.pixels(0),
              slivers: [
                SliverToBoxAdapter(
                  child: Focus(
                    focusNode: header,
                    canRequestFocus: false,
                    skipTraversal: true,
                    child: TextButton(
                      focusNode: toolbar,
                      onPressed: () {},
                      child: const Text('工具栏'),
                    ),
                  ),
                ),
                SliverFixedExtentList(
                  itemExtent: 60,
                  delegate: SliverChildBuilderDelegate((context, index) {
                    built.add(index);
                    return TelevisionAction(
                      key: ValueKey(index),
                      onActivate: () {},
                      onMenu: () => menus++,
                      builder: (_, focus) => ListTile(
                        focusNode: focus,
                        title: Text('文件夹 $index'),
                        onTap: () {},
                      ),
                    );
                  }, childCount: 500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    scroll.jumpTo(2400);
    await tester.pump();
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '文件夹 43'),
    );
    tile.focusNode!.requestFocus();
    await tester.pump();
    final offset = scroll.offset;
    final origin = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(TelevisionInputScope.menuDoublePressInterval);
    await tester.pumpAndSettle();
    expect(toolbar.hasFocus, isTrue);
    expect(menus, 0);
    expect(scroll.offset, lessThan(offset));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(origin));
    expect(scroll.offset, offset);
    expect(built.length, lessThan(60));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(const Duration(milliseconds: 550));
    expect(menus, 1);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.contextMenu);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(TelevisionInputScope.menuDoublePressInterval);
    expect(menus, 1);
    expect(FocusManager.instance.primaryFocus, same(origin));
    await tester.pumpWidget(const SizedBox());
    header.dispose();
    toolbar.dispose();
    scroll.dispose();
  });

  testWidgets('traversal keeps a focused row clear of floating navigation', (
    tester,
  ) async {
    const bounds = Rect.fromLTWH(0, 500, 800, 100);
    final scroll = ScrollController();
    final nodes = List.generate(20, (_) => FocusNode());
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            TelevisionInputScope(overrideTelevision: true, child: child!),
        home: TelevisionNavigationHost(
          onNavigation: () {},
          navigationActive: false,
          navigationBounds: () => bounds,
          child: Scaffold(
            body: ListView.builder(
              controller: scroll,
              itemExtent: 60,
              padding: const EdgeInsets.only(bottom: 120),
              itemCount: nodes.length,
              itemBuilder: (_, index) => TextButton(
                focusNode: nodes[index],
                onPressed: () {},
                child: Text('文件夹 $index'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    nodes[6].requestFocus();
    await tester.pump();
    for (var index = 7; index <= 10; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(nodes[index].hasFocus, isTrue);
      expect(nodes[index].rect.bottom, lessThanOrEqualTo(bounds.top));
    }
    expect(scroll.offset, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    for (final node in nodes) {
      node.dispose();
    }
  });

  testWidgets(
    'TV traversal selects fields without opening IME and escapes sliders',
    (tester) async {
      final first = FocusNode();
      final field = FocusNode();
      final slider = FocusNode();
      var value = .5;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              TelevisionInputScope(overrideTelevision: true, child: child!),
          home: Scaffold(
            body: Column(
              children: [
                TextButton(
                  focusNode: first,
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('标题'),
                ),
                TextField(focusNode: field),
                StatefulBuilder(
                  builder: (context, update) => Slider(
                    focusNode: slider,
                    value: value,
                    onChanged: (next) => update(() => value = next),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(field.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(slider.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(value, greaterThan(.5));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(field.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      field.dispose();
      slider.dispose();
    },
  );

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
