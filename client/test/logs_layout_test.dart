import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/ui/logs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'log list fills the available height as navigation space changes',
    (tester) async {
      final log = AppLog();
      for (var index = 0; index < 80; index++) {
        log.info('测试', '日志 $index');
      }
      var inset = 88.0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Padding(
                  padding: EdgeInsets.only(bottom: inset),
                  child: LogsView(log: log),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('diagnostic-log-list'));
      final initial = tester.getRect(list);
      update(() => inset = 0);
      await tester.pumpAndSettle();
      final expanded = tester.getRect(list);
      expect(expanded.bottom - initial.bottom, closeTo(88, 1));
      expect(
        expanded.bottom,
        closeTo(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
          1,
        ),
      );
      expect(find.text('诊断'), findsNothing);
      expect(find.text('日志 79'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      log.dispose();
    },
  );
}
