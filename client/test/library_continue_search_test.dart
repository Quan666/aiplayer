import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _SearchModel extends AppModel {
  _SearchModel(super.store, super.documents) : super(backgroundWork: false);
  int reads = 0;
  Completer<void>? gate;

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    reads++;
    final snapshot = await super.loadLibrarySnapshot(
      query: query,
      cancel: cancel,
    );
    await gate?.future;
    return snapshot;
  }

  @override
  Future<void> ensureMediaPreview(String id) async {}
}

void main() {
  late Directory directory;
  late AppStore store;
  late _SearchModel model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('continue-search-');
    store = AppStore(':memory:');
    model = _SearchModel(store, directory);
    for (var i = 0; i < 15; i++) {
      store.save('media', 'video-$i', {
        'title': i == 0 ? '远行.mp4' : '影片 $i.mp4',
        'series': '未分类',
        'size': 100,
      });
      store.save('progress', 'video-$i:100', {
        'position': 10,
        'duration': 100,
        'updatedAt': DateTime.utc(2026, 10, 24, 0, i).toIso8601String(),
      });
    }
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> openSearch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索作品或文件名'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'search finds older continue records beyond the ten-card carousel',
    (tester) async {
      await openSearch(tester);
      expect(find.byKey(const ValueKey('history:video-0')), findsNothing);
      await tester.enterText(find.byType(TextField).first, '远行');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history:video-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('history:video-14')), findsNothing);
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.text('搜索结果'), findsOneWidget);
      await tester.tap(find.text('继续观看'));
      await tester.pumpAndSettle();
      final grid = find.byKey(const PageStorageKey('library-history-grid'));
      expect(grid, findsOneWidget);
      expect(find.byKey(const ValueKey('history:video-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('history:video-14')), findsNothing);
      Navigator.of(tester.element(grid)).pop();
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, '远行');
      expect(field.focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'filtered history contains every match and keeps the filter on refresh',
    (tester) async {
      await openSearch(tester);
      await tester.enterText(find.byType(TextField).first, '影片');
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续观看'));
      await tester.pumpAndSettle();
      final grid = find.byKey(const PageStorageKey('library-history-grid'));
      final widget = tester.widget<GridView>(grid);
      expect(widget.childrenDelegate.estimatedChildCount, 14);
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: grid, matching: find.byType(Scrollable)).first,
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history:video-1')), findsOneWidget);
      store.save('progress', 'video-1:100', {}, deleted: true);
      model.changed();
      await tester.pumpAndSettle();
      expect(
        tester.widget<GridView>(grid).childrenDelegate.estimatedChildCount,
        13,
      );
      expect(find.byKey(const ValueKey('history:video-0')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'history does not reuse a snapshot for a previous search while loading',
    (tester) async {
      await openSearch(tester);
      final gate = model.gate = Completer<void>();
      await tester.enterText(find.byType(TextField).first, '远行');
      await tester.pump();
      await tester.tap(find.text('继续观看'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('观看历史'), findsOneWidget);
      expect(
        find.byKey(const PageStorageKey('library-history-grid')),
        findsNothing,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      gate.complete();
      model.gate = null;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('history:video-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('history:video-14')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'active search refreshes local episode titles once after frame-less pause',
    (tester) async {
      await openSearch(tester);
      await tester.enterText(find.byType(TextField).first, '重逢');
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsNothing);
      final reads = model.reads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // No pump: updates must stay suspended even if Android stops rendering.
      store.setLocal('episodeTitle:video-0', '重逢');
      model.changed();
      await tester.idle();
      expect(model.reads, reads);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(model.reads, reads + 1);
      expect(find.byKey(const ValueKey('history:video-0')), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '重逢',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
