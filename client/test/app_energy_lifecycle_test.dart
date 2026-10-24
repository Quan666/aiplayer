import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingModel extends AppModel {
  int libraryReads = 0;
  final foregroundChanges = <bool>[];

  _CountingModel(super.store, super.documents) : super(backgroundWork: false);

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) {
    libraryReads++;
    return super.loadLibrarySnapshot(query: query, cancel: cancel);
  }

  @override
  void setForeground(bool foreground) {
    foregroundChanges.add(foreground);
    super.setForeground(foreground);
  }
}

void main() {
  late Directory root;
  late AppStore store;
  late _CountingModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('aiplayer-energy-');
    store = AppStore(':memory:');
    model = _CountingModel(store, root);
    store.save('media', 'video', {'title': '视频', 'series': '视频', 'size': 1});
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets(
    'unfocused library defers updates while visible tickers remain on',
    (tester) async {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      final reads = model.libraryReads;
      final library = find.byKey(const PageStorageKey('library-scroll'));
      final original = tester.widget<CustomScrollView>(library);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(
        TickerMode.valuesOf(tester.element(find.byType(LibraryPage))).enabled,
        isTrue,
      );
      for (var i = 0; i < 10; i++) {
        store.save('progress', 'video:1', {'position': i, 'duration': 100});
        model.changed();
        await tester.pump();
      }
      expect(model.libraryReads, reads);
      expect(tester.widget<CustomScrollView>(library), same(original));
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(model.libraryReads, reads + 1);
      expect(tester.widget<CustomScrollView>(library), isNot(same(original)));
      expect(
        TickerMode.valuesOf(tester.element(find.byType(LibraryPage))).enabled,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      expect(model.foregroundChanges.last, isFalse);
    },
  );

  testWidgets('initial hidden lifecycle and model replacement stay suspended', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    final otherStore = AppStore(':memory:');
    final replacement = _CountingModel(otherStore, root);
    try {
      await tester.pumpWidget(AIPlayerApp(model: model));
      tester.binding.scheduleForcedFrame();
      await tester.pumpAndSettle();
      expect(model.libraryReads, 0);
      expect(model.foregroundChanges, [false]);
      expect(
        TickerMode.valuesOf(tester.element(find.byType(LibraryPage))).enabled,
        isFalse,
      );
      await tester.pumpWidget(AIPlayerApp(model: replacement));
      tester.binding.scheduleForcedFrame();
      await tester.pumpAndSettle();
      expect(replacement.libraryReads, 0);
      expect(replacement.foregroundChanges, [false]);
      expect(
        TickerMode.valuesOf(tester.element(find.byType(LibraryPage))).enabled,
        isFalse,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      // The visible initial-loading indicator can animate until focus returns
      // and allows the deferred library snapshot to load.
      await tester.pump();
      expect(replacement.libraryReads, 0);
      expect(replacement.foregroundChanges, [false]);
      expect(
        TickerMode.valuesOf(tester.element(find.byType(LibraryPage))).enabled,
        isTrue,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(replacement.libraryReads, 1);
      expect(model.foregroundChanges.last, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(replacement.foregroundChanges.last, isFalse);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      replacement.dispose();
      otherStore.dispose();
    }
  });

  testWidgets('sort updates while paused wait for resume without another frame', (
    tester,
  ) async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    final reads = model.libraryReads;
    final library = find.byKey(const PageStorageKey('library-scroll'));
    final original = tester.widget<CustomScrollView>(library);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Deliberately do not pump after paused: Android may never draw that frame.
    for (final field in ['size', 'modified', 'updated', 'name']) {
      store.setLocal('settings', {
        'librarySortField': field,
        'librarySortDescending': false,
      });
      model.changed();
      await tester.idle();
    }
    expect(model.libraryReads, reads);
    expect(tester.widget<CustomScrollView>(library), same(original));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(model.libraryReads, reads + 1);
    expect(model.librarySorting.field, 'name');
    expect(model.librarySorting.descending, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unrelated status changes do not rebuild the sources root', (
    tester,
  ) async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-item-1')));
    await tester.pumpAndSettle();
    final sources = find.byKey(const PageStorageKey('sources-scroll'));
    final original = tester.widget<CustomScrollView>(sources);
    for (var i = 0; i < 10; i++) {
      model.status = '同步 $i';
      store.setLocal('syncCursor:test', i);
      model.changed();
      await tester.pump();
    }
    expect(tester.widget<CustomScrollView>(sources), same(original));
    store.setLocal('sources', [
      {'id': 'nas', 'kind': 'webdav', 'label': '新增来源'},
    ]);
    model.changed();
    await tester.pumpAndSettle();
    expect(find.text('新增来源'), findsOneWidget);
    expect(tester.widget<CustomScrollView>(sources), isNot(same(original)));
    await tester.pumpWidget(const SizedBox());
  });
}
