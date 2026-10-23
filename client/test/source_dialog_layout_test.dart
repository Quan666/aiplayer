import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'));
    await font.load();
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final size in [const Size(390, 844), const Size(844, 390)]) {
      testWidgets(
        '${brightness.name} source dialog remains usable at $size with keyboard',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          Map<String, dynamic>? saved;
          try {
            // This fixture opens the real dialog without storage or networking.
            await tester.pumpWidget(
              MaterialApp(
                theme: GlassPalette.theme(brightness: brightness),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => Center(
                      child: FilledButton(
                        onPressed: () async {
                          saved = await Navigator.push<Map<String, dynamic>>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SourceEditorPage(),
                            ),
                          );
                        },
                        child: const Text('添加来源'),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('添加来源'));
            await tester.pumpAndSettle();
            expect(
              Theme.of(tester.element(find.byType(SourceDialog))).brightness,
              brightness,
            );
            expect(tester.takeException(), isNull);

            tester.view.viewInsets = const FakeViewPadding(bottom: 240);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            Future<void> fill(String label, String value) async {
              final field = find.byWidgetPredicate(
                (widget) =>
                    widget is TextField &&
                    widget.decoration?.labelText == label,
              );
              await tester.ensureVisible(field);
              await tester.pumpAndSettle();
              await tester.enterText(field, value);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }

            await fill('显示名称（可选）', '我的 NAS');
            await fill('服务器地址', 'nas.local');
            await fill('密码（可选）', 'layout-test-password');

            final save = find.widgetWithText(TextButton, '保存');
            await tester.ensureVisible(save);
            await tester.pumpAndSettle();
            final rect = tester.getRect(save);
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(size.height - 240));
            await tester.tap(save);
            await tester.pumpAndSettle();
            expect(find.byType(SourceDialog), findsNothing);
            expect(saved?['label'], '我的 NAS');
            expect(saved?['host'], 'nas.local');
            expect(saved?['share'], '');
            expect(saved?['password'], 'layout-test-password');
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            tester.view.resetViewInsets();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        },
      );
    }
  }
}
