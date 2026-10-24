import 'package:aiplayer/ui/search_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dismissal cancels queued focus without closing search', (
    tester,
  ) async {
    final controller = SearchHeaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchHeader(
            title: '影视库',
            hint: '搜索作品',
            controller: controller,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('搜索作品'));
    controller.dismissFocus();
    await tester.pumpAndSettle();
    final search = find.byType(TextField);
    final field = tester.widget<TextField>(search);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.enterText(search, '保留搜索');
    controller.dismissFocus();
    await tester.pumpAndSettle();
    expect(field.controller!.text, '保留搜索');
    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(field.focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a search covered before its entrance cannot take route focus', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: SearchHeader(title: '影视库', hint: '搜索作品', onChanged: (_) {}),
        ),
      ),
    );
    await tester.tap(find.byTooltip('搜索作品'));
    navigator.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Playback'))),
    );
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
