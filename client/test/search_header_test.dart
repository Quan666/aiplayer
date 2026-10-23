import 'package:aiplayer/ui/search_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'compact search replaces trailing action, focuses input and clears on close',
    (tester) async {
      var query = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchHeader(
              title: '影视库',
              hint: '搜索作品',
              onChanged: (value) => query = value,
              trailing: TextButton(onPressed: () {}, child: const Text('导入视频')),
            ),
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('搜索作品'));
      await tester.pumpAndSettle();
      expect(find.text('导入视频'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), 'episode');
      expect(query, 'episode');
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pumpAndSettle();
      expect(query, '');
      expect(find.text('导入视频'), findsOneWidget);
    },
  );
}
