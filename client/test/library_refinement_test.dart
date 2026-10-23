import 'dart:io';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/logs_page.dart';
import 'package:aiplayer/core/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'series details show metadata, episode history, and a single latest resume action',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-series-details-',
      );
      final store = AppStore(':memory:');
      final model = AppModel(store, root);
      for (var n = 1; n <= 2; n++) {
        store.save('media', '$n', {
          'title': 'RAW S01E0$n.mkv',
          'series': 'RAW',
          'season': '1',
          'episode': '$n',
          'bangumiId': '12',
          'metadataTitle': '正式作品名称',
          'rating': 8.6,
          'totalEpisodes': 12,
          'airDate': '2026-01-01',
          'size': 100,
        });
        final media = store.get('media', '$n')!;
        store.save('progress', model.progressKey(media), {
          'position': n * 30,
          'duration': 120,
          'updatedAt': '2026-10-2${n}T00:00:00Z',
        });
        store.setLocal('episodeTitle:$n', '第$n集小标题');
      }
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        expect(find.text('00:30 / 02:00 · 25%'), findsNothing);
        expect(find.text('01:00 / 02:00 · 50%'), findsOneWidget);
        final details = find.byKey(const ValueKey('details:1'));
        await tester.ensureVisible(details);
        await tester.tap(details);
        await tester.pumpAndSettle();
        expect(find.textContaining('评分 8.6'), findsOneWidget);
        expect(find.textContaining('共 12 集'), findsOneWidget);
        expect(find.textContaining('00:30 / 02:00 · 25%'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.textContaining('01:00 / 02:00 · 50%'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('series-continue')), findsOneWidget);
        expect(find.textContaining('继续观看 · 第 2 集'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'continue cards show elapsed total and percent; one video opens directly',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-library-');
      final store = AppStore(':memory:');
      final model = AppModel(store, root);
      store.save('media', 'sample', {
        'title': '旅行.mp4',
        'series': '旅行',
        'episode': '',
        'season': '',
        'duration': 120,
        'size': 100,
      });
      final media = store.get('media', 'sample')!;
      store.save('progress', model.progressKey(media), {
        'position': 30,
        'duration': 120,
      });
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        expect(find.text('00:30 / 02:00 · 25%'), findsOneWidget);
        await tester.tap(find.text('继续观看'));
        await tester.pumpAndSettle();
        expect(find.text('观看历史'), findsOneWidget);
        expect(find.text('00:30 / 02:00 · 25%'), findsOneWidget);
        Navigator.of(tester.element(find.text('观看历史'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('play:sample')));
        await tester.pumpAndSettle();
        expect(find.text('关联此设备上的视频位置'), findsOneWidget);
        Navigator.of(tester.element(find.text('关联此设备上的视频位置'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('details:sample')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('匹配海报与简介'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );
  testWidgets(
    'bottom navigation hides on upward swipe and returns on downward swipe',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-scroll-');
      final store = AppStore(':memory:');
      final model = AppModel(store, root);
      for (var i = 0; i < 30; i++) {
        store.save('media', '$i', {
          'title': '视频 $i.mp4',
          'series': '未分类',
          'episode': '',
          'season': '',
          'size': i,
        });
      }
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        final scroll = find.byType(CustomScrollView).first;
        await tester.drag(scroll, const Offset(0, -330));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AnimatedSlide>(
                find.byKey(const ValueKey('navigation-slide')),
              )
              .offset
              .dy,
          greaterThan(1),
        );
        await tester.drag(scroll, const Offset(0, 140));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AnimatedSlide>(
                find.byKey(const ValueKey('navigation-slide')),
              )
              .offset,
          Offset.zero,
        );
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
  testWidgets('log viewer filters, searches and confirms clearing', (
    tester,
  ) async {
    final log = AppLog()
      ..info('连接', '连接成功')
      ..error('字幕', '字幕格式错误');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: LogsView(log: log)),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '错误'));
      await tester.pumpAndSettle();
      expect(find.text('字幕格式错误'), findsOneWidget);
      expect(find.text('连接成功'), findsNothing);
      await tester.tap(find.text('字幕格式错误'));
      await tester.pumpAndSettle();
      expect(copied, contains('字幕格式错误'));
      expect(copied, contains('字幕'));
      await tester.tap(find.byTooltip('日志操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空日志'));
      await tester.pumpAndSettle();
      expect(log.entries.length, 2);
      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();
      expect(log.entries, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      log.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    }
  });
}
