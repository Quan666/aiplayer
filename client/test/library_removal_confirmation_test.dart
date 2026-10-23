import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RemovalModel extends AppModel {
  final bool managed;
  final removed = <String>[];
  _RemovalModel(super.store, super.documents, {required this.managed});

  @override
  Future<bool> isManagedImport(SyncRecord record) async => managed;

  @override
  Future<void> removeMedia(SyncRecord record) async {
    removed.add(record.id);
    store.save('media', record.id, record.data, deleted: true);
    changed();
  }
}

void main() {
  testWidgets(
    'batch deletion selects search results and preserves cancellation',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-batch-remove-',
      );
      final store = AppStore(':memory:');
      final model = _RemovalModel(store, root, managed: true);
      for (final id in ['1', '2', '3']) {
        store.save('media', id, {
          'title': id == '3' ? '其他.mp4' : '作品$id.mp4',
          'series': id == '3' ? '其他' : '作品$id',
          'episode': '',
          'size': 100,
        });
      }
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量删除'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '删除所选'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('select:3')));
        await tester.pumpAndSettle();
        expect(find.text('已选 1 个视频'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('select:3')));
        await tester.tap(find.byTooltip('搜索作品或文件名'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '作品');
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选'));
        await tester.pumpAndSettle();
        expect(find.text('已选 2 个视频'), findsOneWidget);
        await tester.tap(find.text('取消全选'));
        await tester.pumpAndSettle();
        expect(find.text('已选 0 个视频'), findsOneWidget);
        await tester.tap(find.text('全选'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除所选'));
        await tester.pumpAndSettle();
        expect(find.text('移除这 2 个视频？'), findsOneWidget);
        expect(
          find.text('将移除所选视频的库记录，并删除其中 2 个应用导入副本，无法撤销。原始位置的文件不受影响。'),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        expect(model.removed, isEmpty);
        expect(find.text('已选 2 个视频'), findsOneWidget);
        await tester.tap(find.text('删除所选'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '删除视频'));
        await tester.pumpAndSettle();
        expect(model.removed, unorderedEquals(['1', '2']));
        expect(model.media.map((item) => item.id), ['3']);
        expect(find.text('完成'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('all videos can remove a whole series with one confirmation', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('aiplayer-remove-series-');
    final store = AppStore(':memory:');
    final model = _RemovalModel(store, root, managed: false);
    for (var index = 1; index <= 3; index++) {
      store.save('media', '$index', {
        'title': '作品 S01E0$index.mp4',
        'series': '作品',
        'season': '1',
        'episode': '$index',
        'size': 100,
      });
    }
    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('media-actions:1'));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('从影视库移除'));
      await tester.pumpAndSettle();
      expect(find.text('移除这 3 个视频？'), findsOneWidget);
      expect(find.text('仅移除影视库记录，原位置的视频文件会保留。'), findsOneWidget);
      expect(model.removed, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(model.removed, isEmpty);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('从影视库移除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pumpAndSettle();
      expect(model.removed, ['1', '2', '3']);
      expect(model.media, isEmpty);
      expect(find.text('暂无视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      root.deleteSync(recursive: true);
    }
  });

  for (final managed in [true, false]) {
    testWidgets(
      managed
          ? 'import deletion requires explicit confirmation and cancel keeps the video'
          : 'linked video removal explains the original is retained and requires confirmation',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final root = Directory.systemTemp.createTempSync('aiplayer-remove-ui-');
        final store = AppStore(':memory:');
        final model = _RemovalModel(store, root, managed: managed);
        store.save('media', 'sample', {
          'title': '旅行.mp4',
          'series': '旅行',
          'episode': '',
          'season': '',
          'duration': 120,
          'size': 100,
        });
        Future<void> requestRemoval() async {
          await tester.tap(find.byKey(const ValueKey('details:sample')));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(PopupMenuButton<String>).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('从影视库移除'));
          await tester.pumpAndSettle();
        }

        try {
          await tester.pumpWidget(AIPlayerApp(model: model));
          await tester.pumpAndSettle();
          await requestRemoval();
          expect(find.text(managed ? '删除导入的视频？' : '从影视库移除？'), findsOneWidget);
          expect(
            find.text(
              managed
                  ? '将删除应用中导入的视频文件及其库记录，无法撤销。原始位置的文件不受影响。'
                  : '仅移除影视库记录，原位置的视频文件会保留。',
            ),
            findsOneWidget,
          );
          expect(model.removed, isEmpty);
          await tester.tap(find.widgetWithText(TextButton, '取消'));
          await tester.pumpAndSettle();
          expect(model.removed, isEmpty);
          expect(store.get('media', 'sample')?.deleted, false);

          await requestRemoval();
          await tester.tap(
            find.widgetWithText(FilledButton, managed ? '删除视频' : '移除'),
          );
          await tester.pumpAndSettle();
          expect(model.removed, ['sample']);
          expect(store.get('media', 'sample')?.deleted, true);
          expect(find.byKey(const ValueKey('details:sample')), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
          store.dispose();
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}
