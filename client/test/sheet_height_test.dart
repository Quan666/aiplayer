import 'package:aiplayer/sources/directory_sort.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('folder options remain reachable on a short landscape screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(740, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var applied = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDirectoryOptions(
                context,
                const DirectorySort(),
                (_) {},
                onApplyAll: (_) => applied = true,
              ),
              child: const Text('打开排序'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开排序'));
    await tester.pumpAndSettle();
    final scroll = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroll, findsOneWidget);
    await tester.drag(scroll, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用到所有文件夹'));
    await tester.pumpAndSettle();
    expect(applied, isTrue);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
