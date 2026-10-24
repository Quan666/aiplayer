import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/search_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'expanded library search survives lazy eviction and tab navigation without refocusing',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'library-search-retention-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = AppModel(store, directory, backgroundWork: false);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      for (var i = 0; i < 120; i++) {
        store.save('media', 'video-$i', {
          'title': 'Video $i.mp4',
          'series': '未分类',
        });
      }
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: LibraryPage(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索作品或文件名'));
        await tester.pumpAndSettle();
        final search = find.byType(TextField).first;
        await tester.enterText(search, 'Video');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        final headerState = tester.state(find.byType(SearchHeader).first);
        final field = tester.widget<TextField>(search);
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        final library = find.byKey(const PageStorageKey('library-scroll'));
        final scroll = tester.state<ScrollableState>(
          find.descendant(
            of: library,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          ),
        );

        tester.testTextInput.log.clear();
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.byType(SearchHeader).hitTestable(), findsNothing);
        expect(headerState.mounted, isTrue);
        await tester.tap(find.byKey(const ValueKey('nav-item-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('nav-item-0')));
        await tester.pumpAndSettle();
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.byTooltip('关闭搜索'), findsOneWidget);
        expect(
          tester.state(find.byType(SearchHeader).first),
          same(headerState),
        );
        expect(
          tester.widget<TextField>(find.byType(TextField).first).controller,
          same(field.controller),
        );
        expect(field.controller!.text, 'Video');
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );

        // Closing the search releases the header's keep-alive. The rest of the
        // lazy library must not be retained merely to preserve a compact title.
        await tester.tap(find.byTooltip('关闭搜索'));
        await tester.pumpAndSettle();
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(headerState.mounted, isFalse);
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(find.byTooltip('搜索作品或文件名'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}
