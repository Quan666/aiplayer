import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/navigation_reveal.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'TV navigation opens by menu or lower content edge and restores focus',
    (tester) async {
      final fixture = _Fixture(tester);
      tester.view.physicalSize = const Size(1280, 720);
      fixture.store.setLocal('sources', [
        {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
      ]);
      await fixture.mount(television: true);
      expect(find.byKey(const ValueKey('bottom-navigation')), findsOneWidget);
      FocusNode navFocus(int index) => tester
          .widget<InkWell>(
            find
                .ancestor(
                  of: find.byKey(ValueKey('nav-item-$index')),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .focusNode!;
      Future<void> navigation() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pumpAndSettle();
      }

      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      expect(navFocus(0).hasFocus, isFalse);
      await navigation();
      expect(navFocus(0).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(navFocus(1).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('NAS'), findsOneWidget);
      expect(navFocus(1).hasFocus, isFalse);
      await tester.tap(find.text('NAS'));
      await tester.pumpAndSettle();
      final first = tester.widget<ListTile>(
        find.widgetWithText(ListTile, '文件夹 00'),
      );
      first.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('收藏文件夹'), findsOneWidget);
      final menuFocus = FocusManager.instance.primaryFocus;
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(menuFocus));
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏文件夹'), findsNothing);
      expect(first.focusNode!.hasFocus, isTrue);
      await navigation();
      expect(navFocus(1).hasFocus, isTrue);
      // Native Back closes only navigation, leaving the same folder open.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('文件夹 00'), findsOneWidget);
      expect(first.focusNode!.hasFocus, isTrue);
      await navigation();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(first.focusNode!.hasFocus, isTrue);
      // Traverse beyond the first viewport without eagerly building the list.
      for (var i = 0; i < 26; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(fixture.hidden, isTrue);
      expect(navFocus(1).hasFocus, isFalse);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.pixels, greaterThan(500));
      await navigation();
      expect(fixture.hidden, isFalse);
      expect(navFocus(1).hasFocus, isTrue);
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pumpAndSettle();
      expect(find.text('本地视频'), findsNothing);
      expect(navFocus(1).hasFocus, isFalse);
      for (var i = 0; i < 80 && !navFocus(1).hasFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(navFocus(1).hasFocus, isTrue);
      expect(fixture.hidden, isFalse);
      expect(find.text('本地视频'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(navFocus(1).hasFocus, isFalse);
      expect(tester.takeException(), isNull);
      await fixture.close();
    },
  );

  testWidgets(
    'a downward pull on an unscrollable page reveals without stealing taps',
    (tester) async {
      var reveals = 0;
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NavigationRevealRegion(
              onReveal: () => reveals++,
              child: ListView(
                physics: const ClampingScrollPhysics(),
                children: [
                  TextButton(onPressed: () => taps++, child: const Text('打开')),
                ],
              ),
            ),
          ),
        ),
      );
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scroll.position.maxScrollExtent, 0);
      await tester.tap(find.text('打开'));
      expect(taps, 1);
      expect(reveals, 0);
      await tester.dragFrom(const Offset(200, 250), const Offset(0, 70));
      await tester.pumpAndSettle();
      expect(reveals, greaterThan(0));
      expect(scroll.position.pixels, 0);
      expect(taps, 1);
    },
  );

  testWidgets(
    'horizontal slider drags and multi-touch do not reveal navigation',
    (tester) async {
      var reveals = 0;
      var value = .2;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NavigationRevealRegion(
              onReveal: () => reveals++,
              child: StatefulBuilder(
                builder: (context, update) => Center(
                  child: Slider(
                    value: value,
                    onChanged: (next) => update(() => value = next),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider)),
      );
      await gesture.moveBy(const Offset(60, 3));
      await gesture.moveBy(const Offset(35, 25));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(value, greaterThan(.2));
      expect(reveals, 0);
      final first = await tester.startGesture(
        const Offset(100, 100),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(140, 100),
        pointer: 2,
      );
      await first.moveBy(const Offset(0, 70));
      await second.moveBy(const Offset(0, 70));
      await first.up();
      await second.up();
      expect(reveals, 0);
    },
  );

  testWidgets('returning from a route restores the navigation', (tester) async {
    var reveals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NavigationRevealRegion(
            onReveal: () => reveals++,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(body: Text('另一页')),
                  ),
                ),
                child: const Text('前往'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('前往'));
    await tester.pumpAndSettle();
    expect(reveals, 0);
    Navigator.pop(tester.element(find.text('另一页')));
    await tester.pumpAndSettle();
    expect(reveals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hidden library navigation can be pulled back after content becomes short',
    (tester) async {
      final fixture = _Fixture(tester);
      for (var i = 0; i < 30; i++) {
        fixture.store.save('media', '$i', {
          'title': '视频 $i.mp4',
          'series': '未分类',
          'size': i,
        });
      }
      await fixture.mount();
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -330),
      );
      await tester.pumpAndSettle();
      expect(fixture.hidden, isTrue);
      final details = find.byTooltip('查看详情').hitTestable().first;
      await tester.tap(details);
      await tester.pumpAndSettle();
      final detailsContext = tester.element(find.byTooltip('匹配海报与简介'));
      Navigator.pop(detailsContext);
      await tester.pumpAndSettle();
      expect(fixture.hidden, isFalse);
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      expect(fixture.hidden, isTrue);
      for (final record in fixture.store.all('media')) {
        fixture.store.save('media', record.id, record.data, deleted: true);
      }
      fixture.model.changed();
      await tester.pumpAndSettle();
      expect(find.text('暂无视频'), findsOneWidget);
      final shortScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(shortScroll.position.maxScrollExtent, 0);
      await tester.dragFrom(const Offset(190, 480), const Offset(0, 70));
      await tester.pumpAndSettle();
      expect(fixture.hidden, isFalse);
      await tester.tap(find.text('连接来源'));
      await tester.pumpAndSettle();
      expect(find.text('本地视频'), findsOneWidget);
      expect(fixture.hidden, isFalse);
      expect(tester.takeException(), isNull);
      await fixture.close();
    },
  );

  testWidgets(
    'entering and returning from source folders restores navigation',
    (tester) async {
      final fixture = _Fixture(tester);
      fixture.store.setLocal('sources', [
        {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
      ]);
      await fixture.mount();
      await tester.tap(find.byKey(const ValueKey('nav-item-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NAS'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -330));
      await tester.pumpAndSettle();
      expect(fixture.hidden, isTrue);
      final folder = find.text('文件夹 08');
      await tester.ensureVisible(folder);
      await tester.tap(folder);
      await tester.pumpAndSettle();
      expect(find.text('这里还没有文件'), findsOneWidget);
      expect(fixture.hidden, isFalse);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(fixture.hidden, isTrue);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('本地视频'), findsOneWidget);
      expect(fixture.hidden, isFalse);
      expect(tester.takeException(), isNull);
      await fixture.close();
    },
  );

  for (final desktop in [false, true]) {
    testWidgets(
      'double tapping the ${desktop ? 'side' : 'bottom'} source navigation returns to the source home',
      (tester) async {
        final fixture = _Fixture(tester);
        if (desktop) tester.view.physicalSize = const Size(1280, 900);
        fixture.store.setLocal('sources', [
          {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
        ]);
        await fixture.mount();
        final sourceTab = find.byKey(const ValueKey('nav-item-1'));
        await tester.tap(sourceTab);
        await tester.pumpAndSettle();
        await tester.tap(find.text('NAS'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('文件夹 00'));
        await tester.pumpAndSettle();
        expect(find.text('这里还没有文件'), findsOneWidget);
        await tester.tap(sourceTab);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(sourceTab);
        await tester.pumpAndSettle();
        expect(find.text('本地视频'), findsOneWidget);
        expect(find.text('NAS'), findsOneWidget);
        expect(find.text('这里还没有文件'), findsNothing);
        expect(find.byTooltip('返回'), findsNothing);
        expect(tester.takeException(), isNull);
        await fixture.close();
      },
    );
  }
}

class _Fixture {
  final WidgetTester tester;
  final directory = Directory.systemTemp.createTempSync('aiplayer-nav-');
  final store = AppStore(':memory:');
  late final AppModel model = _FolderModel(store, directory);
  bool _closed = false;

  _Fixture(this.tester) {
    FlutterSecureStorage.setMockInitialValues({});
    store.setLocal('settings', {'metadataStrategy': 'off'});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  bool get hidden =>
      tester
          .widget<AnimatedSlide>(find.byKey(const ValueKey('navigation-slide')))
          .offset
          .dy >
      1;

  Future<void> mount({bool television = false}) async {
    await tester.pumpWidget(
      television
          ? MaterialApp(
              builder: (context, child) =>
                  TelevisionInputScope(overrideTelevision: true, child: child!),
              home: LibraryPage(model: model),
            )
          : AIPlayerApp(model: model),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  }
}

class _FolderModel extends AppModel {
  _FolderModel(super.store, super.documents);

  @override
  Future<SourceAdapter> adapter(String id) async => _Folders();
}

class _Folders extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async => path.isEmpty
      ? [
          for (var i = 0; i < 40; i++)
            SourceEntry(
              name: '文件夹 ${i.toString().padLeft(2, '0')}',
              path: 'folder$i/',
              directory: true,
            ),
        ]
      : [];

  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path, directory: true);

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}
