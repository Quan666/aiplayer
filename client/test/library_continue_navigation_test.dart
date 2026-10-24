import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _NavigationObserver extends NavigatorObserver {
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
  late AppModel model;
  late _NavigationObserver observer;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('continue-navigation-');
    store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'})
      ..save('media', 'episode', {
        'title': '系列 S01E01.mkv',
        'series': '系列',
        'season': '1',
        'episode': '1',
      })
      ..setLocal('location:episode', {
        'source': 'local',
        'path': '${directory.path}/episode.mkv',
      });
    model = AppModel(store, directory, enableThumbnails: false);
    store.save('progress', model.progressKey(store.get('media', 'episode')!), {
      'position': 30,
      'duration': 120,
      'updatedAt': '2026-10-24T00:00:00.000Z',
    });
    observer = _NavigationObserver();
  });

  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> showLibrary(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        navigatorObservers: [observer],
        home: LibraryPage(model: model),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history:episode')), findsOneWidget);
  }

  const mobile = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  for (final dismissKeyboard in [false, true]) {
    testWidgets(
      'continue playback clears ${dismissKeyboard ? 'hidden' : 'visible'} search keyboard before navigation',
      (tester) async {
        await showLibrary(tester);
        await tester.tap(find.byTooltip('搜索作品或文件名'));
        await tester.pumpAndSettle();
        final search = find.byType(TextField).first;
        await tester.enterText(search, '系列');
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(search);
        expect(field.focusNode!.hasFocus, isTrue);
        if (dismissKeyboard) tester.testTextInput.hide();

        await tester.tap(find.byKey(const ValueKey('history:episode')));
        // This exercises the actual async player-entry path. Close before
        // mounting a native decoder; native playback has an integration test.
        await tester.idle();
        expect(observer.routes, hasLength(2));
        final route = observer.routes.last as PageRouteBuilder;
        final page = route.pageBuilder(
          tester.element(find.byType(LibraryPage)),
          route.animation!,
          route.secondaryAnimation!,
        );
        expect(page, isA<PlayerPage>());
        expect((page as PlayerPage).media.id, 'episode');
        observer.navigator!.pop();
        await tester.pumpAndSettle();
        expect(field.controller!.text, '系列');
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.tap(search);
        await tester.pumpAndSettle();
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: mobile,
    );

    testWidgets(
      'unavailable continue item does not restore ${dismissKeyboard ? 'hidden' : 'visible'} search keyboard after association',
      (tester) async {
        store.removeLocal('location:episode');
        await showLibrary(tester);
        await tester.tap(find.byTooltip('搜索作品或文件名'));
        await tester.pumpAndSettle();
        final search = find.byType(TextField).first;
        await tester.enterText(search, '系列');
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(search);
        expect(field.focusNode!.hasFocus, isTrue);
        if (dismissKeyboard) tester.testTextInput.hide();
        await tester.tap(find.byKey(const ValueKey('history:episode')));
        await tester.pumpAndSettle();
        expect(find.text('关联此设备上的视频位置'), findsOneWidget);
        observer.navigator!.pop();
        await tester.pumpAndSettle();
        expect(field.controller!.text, '系列');
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.tap(search);
        await tester.pumpAndSettle();
        expect(field.focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: mobile,
    );
  }

  testWidgets(
    'opening continue playback cancels a pending search focus request',
    (tester) async {
      await showLibrary(tester);
      // A search tap schedules focus for the next frame. Start playback before
      // that frame arrives, then return without giving it a chance to steal
      // focus from navigation or reopen the keyboard on the library.
      await tester.tap(find.byTooltip('搜索作品或文件名'));
      await tester.tap(find.byKey(const ValueKey('history:episode')));
      await tester.idle();
      expect(observer.routes, hasLength(2));
      observer.navigator!.pop();
      await tester.pumpAndSettle();
      final search = find.byType(TextField).first;
      final field = tester.widget<TextField>(search);
      expect(field.focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: mobile,
  );
}
