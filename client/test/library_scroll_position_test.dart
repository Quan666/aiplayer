import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final horizontalOffset in [0.0, 316.0]) {
    testWidgets(
      'continue watching keeps horizontal offset $horizontalOffset after a vertical round trip',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final root = Directory.systemTemp.createTempSync('aiplayer-scroll-');
        final store = AppStore(':memory:');
        final model = AppModel(store, root);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        for (var i = 0; i < 50; i++) {
          final id = 'scroll-$i';
          store.save('media', id, {
            'title': '视频 $i.mp4',
            'series': '未分类',
            'episode': '',
            'season': '',
            'duration': 600,
            'size': i + 100,
          });
          if (i < 10) {
            final record = store.get('media', id)!;
            store.save('progress', model.progressKey(record), {
              'position': 60,
              'duration': 600,
              'updatedAt': '2026-10-22T00:00:${i.toString().padLeft(2, '0')}Z',
            });
          }
        }
        final library = find.byKey(const PageStorageKey('library-scroll'));
        Finder scroll(AxisDirection axis) => find.descendant(
          of: library,
          matching: find.byWidgetPredicate(
            (widget) => widget is Scrollable && widget.axisDirection == axis,
          ),
        );
        try {
          await tester.pumpWidget(AIPlayerApp(model: model));
          await tester.pumpAndSettle();
          final horizontal = tester.state<ScrollableState>(
            scroll(AxisDirection.right),
          );
          horizontal.position.jumpTo(horizontalOffset);
          await tester.pumpAndSettle();
          final vertical = tester.state<ScrollableState>(
            scroll(AxisDirection.down),
          );
          vertical.position.jumpTo(vertical.position.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(scroll(AxisDirection.right), findsNothing);
          // Rebuild the offscreen carousel during the return scroll, before
          // the vertical scroll finishes saving its final offset.
          vertical.position.animateTo(
            0,
            duration: const Duration(seconds: 1),
            curve: Curves.linear,
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
          final restored = tester.state<ScrollableState>(
            scroll(AxisDirection.right),
          );
          expect(restored.position.pixels, closeTo(horizontalOffset, .1));
          expect(vertical.position.pixels, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
          store.dispose();
          root.deleteSync(recursive: true);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }
}
