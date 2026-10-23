import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _DetailsModel extends AppModel {
  int loads = 0;
  CancelToken? detailsCancel;

  _DetailsModel(super.store, super.documents);

  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async {
    loads++;
    detailsCancel = cancel;
    return store.all('media');
  }
}

class _RouteObserver extends NavigatorObserver {
  final routes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _DetailsModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync(
      'aiplayer-details-navigation-',
    );
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _DetailsModel(store, directory);
    for (var number = 1; number <= 30; number++) {
      final id = 'episode-$number';
      store.save('media', id, {
        'series': '系列作品',
        'title': '系列作品 S01E$number.mkv',
        'season': '1',
        'episode': '$number',
        'bangumiId': '123',
        'metadataTitle': '系列作品',
      });
      store.setLocal('location:$id', {
        'source': 'local',
        'path': '${directory.path}/$id.mkv',
      });
    }
    store.save(
      'progress',
      model.progressKey(store.get('media', 'episode-1')!),
      {
        'position': 30,
        'duration': 120,
        'updatedAt': '2026-10-23T00:00:00.000Z',
      },
    );
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  for (final identified in [false, true]) {
    testWidgets(
      'one ${identified ? 'identified' : 'parsed'} episode opens its series details',
      (tester) async {
        for (var number = 2; number <= 30; number++) {
          store.save('media', 'episode-$number', {}, deleted: true);
        }
        if (!identified) {
          final first = store.get('media', 'episode-1')!;
          store.save('media', first.id, {
            ...first.data,
            'bangumiId': null,
            'metadataTitle': null,
          });
        }
        store.removeLocal('location:episode-1');
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: LibraryPage(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('play:episode-1')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('series-details-list')),
          findsOneWidget,
        );
        expect(find.text('关联此设备上的视频位置'), findsNothing);
        expect(model.loads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('searching one episode retains the complete series details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索作品或文件名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'S01E20');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('play:episode-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-details-list')), findsOneWidget);
    expect(find.textContaining('已收录 30 集'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('details covered during entrance load when shown again', (
    tester,
  ) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        navigatorObservers: [observer],
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('details:episode-1')));
    await tester.pump();
    expect(model.loads, 0);
    unawaited(
      observer.navigator!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    expect(model.loads, 0);
    observer.navigator!.pop();
    await tester.pumpAndSettle();
    expect(model.loads, 1);
    expect(find.textContaining('已收录 30 集'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'partly identified alternate encodes share one episode and a version chooser',
    (tester) async {
      for (var number = 2; number <= 30; number++) {
        store.save('media', 'episode-$number', {}, deleted: true);
      }
      store.save('media', 'alternate', {
        'series': '系列作品',
        'title': '系列作品 S01E1.mp4',
        'season': '1',
        'episode': '1',
      });
      store.setLocal('location:alternate', {
        'source': 'local',
        'path': '${directory.path}/alternate.mp4',
      });
      final observer = _RouteObserver();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          navigatorObservers: [observer],
          home: LibraryPage(model: model),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('play:episode-1')));
      await tester.pumpAndSettle();
      final details = observer.routes.last;
      expect(find.textContaining('已收录 1 集 · 2 个视频'), findsOneWidget);
      final row = find.byType(MediaDetailsEpisodeTile);
      expect(row, findsOneWidget);
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择视频版本'));
      await tester.pumpAndSettle();
      expect(find.text('系列作品 S01E1.mkv'), findsOneWidget);
      expect(find.text('系列作品 S01E1.mp4'), findsOneWidget);
      await tester.tap(find.text('系列作品 S01E1.mp4'));
      await tester.idle();
      expect(observer.routes, hasLength(3));
      expect(observer.routes[1], same(details));
      final route = observer.routes.last as PageRouteBuilder;
      final player =
          route.pageBuilder(
                tester.element(
                  find.byKey(const ValueKey('series-details-list')),
                ),
                route.animation!,
                route.secondaryAnimation!,
              )
              as PlayerPage;
      expect(player.media.id, 'alternate');
      observer.navigator!.pop();
      await tester.pumpAndSettle();
      expect(observer.routes.last, same(details));
      expect(find.byType(MediaDetailsEpisodeTile), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'playing from details preserves its route, scroll position and loaded episodes',
    (tester) async {
      final observer = _RouteObserver();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          navigatorObservers: [observer],
          home: LibraryPage(model: model),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('details:episode-1')));
      await tester.pumpAndSettle();
      final details = observer.routes.last;
      final list = find.byKey(const ValueKey('series-details-list'));
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      );
      final navigator = observer.navigator!;
      expect(model.loads, 1);
      var plays = 0;

      Future<void> returnFromPlayer(Finder play) async {
        final offset = scroll.position.pixels;
        await tester.tap(play);
        // Inspect and close the actual player route before its first frame;
        // native decoder startup is outside this navigation regression.
        await tester.idle();
        expect(observer.routes, hasLength(3));
        expect(observer.routes[1], same(details));
        final playerRoute = observer.routes.last as PageRouteBuilder;
        final player = playerRoute.pageBuilder(
          tester.element(list),
          playerRoute.animation!,
          playerRoute.secondaryAnimation!,
        );
        expect(player, isA<PlayerPage>());
        expect(model.detailsCancel!.cancelled, isFalse);
        final played = (player as PlayerPage).media;
        store.save('progress', model.progressKey(played), {
          'position': 50,
          'duration': 120,
          'updatedAt': '2026-10-23T00:0${++plays}:00.000Z',
        });
        model.changed();
        navigator.pop();
        await tester.pumpAndSettle();
        expect(observer.routes.last, same(details));
        expect(details.isCurrent, isTrue);
        expect(list, findsOneWidget);
        expect(scroll.position.pixels, offset);
        expect(model.loads, 1);
        expect(model.detailsCancel!.cancelled, isFalse);
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<MediaDetailsContinue>(find.byType(MediaDetailsContinue))
              .latest
              ?.id,
          played.id,
        );
      }

      await returnFromPlayer(find.byKey(const ValueKey('series-continue')));
      scroll.position.jumpTo(600);
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(0));
      await returnFromPlayer(
        find.byType(MediaDetailsEpisodeTile).hitTestable().first,
      );
      navigator.pop();
      await tester.pumpAndSettle();
      final completedLoads = model.loads;
      await tester.pump(const Duration(minutes: 1));
      expect(
        model.loads,
        completedLoads,
        reason: 'disposing details stops its automatic source refresh',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
