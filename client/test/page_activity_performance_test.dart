import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AppStore store;
  late AppModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('aiplayer-page-activity-');
    store = AppStore(':memory:');
    model = AppModel(store, root, backgroundWork: false);
    store.save('media', 'video', {'title': '视频', 'series': '视频', 'size': 1});
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> select(WidgetTester tester, int page) async {
    await tester.tap(find.byKey(ValueKey('nav-item-$page')));
    await tester.pumpAndSettle();
  }

  testWidgets('sync bookkeeping does not rebuild the visible library', (
    tester,
  ) async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
    final library = find.byKey(const PageStorageKey('library-scroll'));
    final original = tester.widget<CustomScrollView>(library);
    for (var i = 0; i < 10; i++) {
      store.setLocal('syncCursor:test', i);
      model.status = '同步 $i';
      model.changed();
      await tester.pump();
      expect(tester.widget<CustomScrollView>(library), same(original));
    }
    store.setLocal('episodeTitle:video', '新的单集标题');
    model.changed();
    await tester.pumpAndSettle();
    expect(tester.widget<CustomScrollView>(library), isNot(same(original)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'retained pages suspend tickers and reuse widgets on unrelated updates',
    (tester) async {
      await tester.pumpWidget(AIPlayerApp(model: model));
      await tester.pumpAndSettle();
      await select(tester, 1);
      await select(tester, 2);
      final settings = find.byType(SettingsPage);
      final sources = find.byType(SourcesPage, skipOffstage: false);
      final retainedSettings = tester.widget<SettingsPage>(settings);
      final retainedSources = tester.widget<SourcesPage>(sources);
      final settingsState = tester.state(settings);
      final sourcesState = tester.state(sources);
      expect(TickerMode.valuesOf(tester.element(settings)).enabled, isTrue);
      expect(TickerMode.valuesOf(tester.element(sources)).enabled, isFalse);
      for (var i = 0; i < 10; i++) {
        store.save('progress', 'video:1', {'position': i});
        model.changed();
        await tester.pump();
        expect(tester.widget<SettingsPage>(settings), same(retainedSettings));
        expect(tester.widget<SourcesPage>(sources), same(retainedSources));
      }
      await select(tester, 1);
      expect(tester.state(sources), same(sourcesState));
      expect(TickerMode.valuesOf(tester.element(sources)).enabled, isTrue);
      final hiddenSettings = find.byType(SettingsPage, skipOffstage: false);
      expect(tester.state(hiddenSettings), same(settingsState));
      expect(
        TickerMode.valuesOf(tester.element(hiddenSettings)).enabled,
        isFalse,
      );
      await select(tester, 0);
      expect(find.text('继续观看'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'inactive artwork waits for activation without replacing its state',
    (tester) async {
      var requests = 0;
      Widget page(bool active, {String? thumbnail}) => MaterialApp(
        home: TickerMode(
          enabled: active,
          child: SizedBox(
            width: 200,
            height: 300,
            child: MediaArtwork(
              thumbnail: thumbnail,
              onRequestPreview: () => requests++,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(MediaArtwork));
      expect(requests, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(requests, 0);
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(tester.state(find.byType(MediaArtwork)), same(state));
      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
