import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'sorting preserves mobile search and selection without restoring the keyboard',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-library-sort-ui-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = AppModel(store, directory);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final entry in {
        'two': '影片 2.mp4',
        'ten': '影片 10.mp4',
        'other': '其他.mp4',
      }.entries) {
        store.save('media', entry.key, {
          'title': entry.value,
          'series': '未分类',
          'size': 100,
        });
      }
      final sort = find.byKey(const ValueKey('library-sort'));
      List<String> visibleOrder() => tester
          .widgetList<InkWell>(find.byType(InkWell))
          .map((widget) => widget.key)
          .whereType<ValueKey<String>>()
          .map((key) => key.value)
          .where((key) => key.startsWith('play:'))
          .toList();

      Future<void> choose(String label) async {
        await tester.tap(sort);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, label),
        );
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: LibraryPage(model: model),
          ),
        );
        await tester.pumpAndSettle();
        expect(sort, findsOneWidget);
        expect(
          find.descendant(of: sort, matching: find.byType(Text)),
          findsNothing,
        );
        expect(find.text('多选'), findsNothing);

        await tester.tap(find.byTooltip('搜索作品或文件名'));
        await tester.pumpAndSettle();
        final search = find.byType(TextField).first;
        await tester.enterText(search, '影片');
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(search);
        expect(field.focusNode!.hasFocus, isTrue);
        await tester.tap(sort);
        await tester.pumpAndSettle();
        for (final label in [
          '最近播放',
          '名称',
          '修改时间',
          '文件大小',
          '更新时间',
          '升序',
          '降序',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, '名称'),
        );
        await tester.pumpAndSettle();
        expect(model.librarySorting.field, 'name');
        expect(model.librarySorting.descending, isFalse);
        expect(visibleOrder(), ['play:two', 'play:ten']);
        expect(field.controller!.text, '影片');
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.byKey(const ValueKey('play:other')), findsNothing);

        await tester.longPress(find.byKey(const ValueKey('play:two')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('多选'));
        await tester.pumpAndSettle();
        expect(find.text('已选 1 个视频'), findsOneWidget);
        await choose('降序');
        expect(visibleOrder(), ['play:ten', 'play:two']);
        expect(
          tester
              .widget<Checkbox>(find.byKey(const ValueKey('select:two')))
              .value,
          isTrue,
        );
        expect(field.controller!.text, '影片');
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.text('已选 1 个视频'), findsOneWidget);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsNothing);

        // A settings update received outside this menu must refresh the cards.
        store.setLocal('settings', {
          ...model.settings,
          'librarySortDescending': false,
        });
        model.changed();
        await tester.pumpAndSettle();
        expect(visibleOrder(), ['play:two', 'play:ten']);
        expect(field.controller!.text, '影片');
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}
