import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/ui/logs_page.dart';
import 'package:aiplayer/ui/media_file_details.dart';
import 'package:aiplayer/ui/player_theme.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:aiplayer/ui/television_scroll_region.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  builder: (context, child) =>
      TelevisionInputScope(overrideTelevision: true, child: child!),
  home: Scaffold(body: TelevisionFocusScope(child: child)),
);

Future<void> _index(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (find
        .byKey(const ValueKey('media-parameters-indexing'))
        .evaluate()
        .isEmpty) {
      return;
    }
  }
  fail('Media parameter indexing did not complete');
}

bool _moreFocused() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<TextButton>()
        ?.key ==
    const ValueKey('media-parameters-more');

void main() {
  testWidgets(
    'TV scroll viewport preserves layout and exits to toolbar at top',
    (tester) async {
      final scroll = ScrollController();
      final header = FocusNode();
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              TextButton(
                focusNode: header,
                onPressed: () {},
                child: const Text('工具'),
              ),
              Expanded(
                child: TelevisionScrollRegion(
                  controller: scroll,
                  autofocus: true,
                  builder: (context, controller) => ListView.builder(
                    key: const ValueKey('reading-list'),
                    controller: controller,
                    itemExtent: 32,
                    itemCount: 1000,
                    itemBuilder: (context, i) => Text('第 $i 行'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bounds = tester.getRect(find.byKey(const ValueKey('reading-list')));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(
        tester.getRect(find.byKey(const ValueKey('reading-list'))),
        bounds,
      );
      expect(find.text('第 999 行'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(scroll.offset, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(header.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      header.dispose();
    },
  );

  testWidgets(
    'TV can read parameters, expand More, and continue through lazy metadata',
    (tester) async {
      await tester.pumpWidget(
        _app(
          SizedBox(
            height: 280,
            child: MediaFileParameterList(
              sections: [
                MediaParameterSection(
                  values: {for (var i = 0; i < 30; i++) '参数 $i': '值 $i'},
                ),
              ],
              moreSections: [
                MediaParameterSection(
                  values: {for (var i = 0; i < 1000; i++) '标签 $i': '额外值 $i'},
                ),
              ],
            ),
          ),
        ),
      );
      await _index(tester);
      final list = find.descendant(
        of: find.byType(MediaFileParameterList),
        matching: find.byType(ListView),
      );
      final controller = tester.widget<ListView>(list).controller!;
      for (var i = 0; i < 30 && !_moreFocused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(controller.offset, greaterThan(0));
      expect(_moreFocused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _index(tester);
      expect(find.text('收起更多'), findsOneWidget);
      final before = controller.offset;
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(controller.offset, greaterThan(before));
      expect(find.text('额外值 999'), findsNothing);
      // Up can return to the same More control instead of trapping the reader.
      for (var i = 0; i < 20 && !_moreFocused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      expect(_moreFocused(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV scrolls inside an oversized focused log entry', (
    tester,
  ) async {
    final log = AppLog()..info('长日志', List.filled(100, '诊断内容').join('\n'));
    await tester.pumpWidget(_app(LogsView(log: log)));
    await tester.pumpAndSettle();
    final row = find
        .ancestor(
          of: find.textContaining('诊断内容'),
          matching: find.byType(InkWell),
        )
        .first;
    final focus = Focus.of(
      tester.element(
        find.descendant(of: row, matching: find.byType(Text)).first,
      ),
    );
    final region = tester.widget<Focus>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Focus &&
            widget.focusNode?.debugLabel == 'television-scroll-region',
      ),
    );
    region.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('diagnostic-log-list')),
    );
    final before = list.controller!.offset;
    expect(before, 0, reason: 'Entering a tall log must reveal its beginning');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(list.controller!.offset, greaterThan(before));
    expect(focus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
    log.dispose();
  });

  testWidgets('TV reads long player diagnostics before reaching close', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        PlayerDialog(
          remoteScroll: true,
          title: const Text('播放诊断'),
          content: Text(List.filled(100, '视频参数').join('\n')),
          actions: [TextButton(onPressed: () {}, child: const Text('关闭'))],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final view = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(view.controller!.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
