import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/search_header.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _statusBarHeight = 44.0;
const _gestureAreaHeight = 34.0;

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform scrolls library and source headers behind a transparent status bar',
      (tester) async {
        final fixture = _Fixture(tester, platform);
        try {
          await fixture.mount();
          _expectStatusBar(Brightness.light);
          final library = find.byKey(const PageStorageKey('library-scroll'));
          final libraryHeader = find.descendant(
            of: library,
            matching: find.byType(SearchHeader),
          );
          expect(
            tester.getTopLeft(libraryHeader).dy,
            _statusBarHeight + 4,
            reason: 'The initial header consumes the top inset exactly once.',
          );
          await _scrollIntoStatusBar(tester, library, find.text('我的影视库'));

          await fixture.selectTab(1);
          final sources = find.byKey(const PageStorageKey('sources-scroll'));
          await _scrollIntoStatusBar(
            tester,
            sources,
            find.descendant(of: sources, matching: find.text('来源')),
          );
          await tester.tap(find.text('本地视频'));
          await tester.pumpAndSettle();
          final local = find.descendant(
            of: find.byType(SourcesPage),
            matching: find.byType(ListView),
          );
          await _scrollIntoStatusBar(tester, local, find.text('本地视频'));

          final navigation = find.byKey(const ValueKey('bottom-navigation'));
          expect(
            tester.getBottomRight(navigation).dy,
            lessThanOrEqualTo(844 - _gestureAreaHeight),
            reason:
                'Scrolling under the status bar preserves the home gesture inset.',
          );
          fixture.model.setThemeMode(ThemeMode.dark);
          await tester.pumpAndSettle();
          _expectStatusBar(Brightness.dark);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close();
        }
      },
    );

    testWidgets(
      '$platform keeps fixed browser and settings controls below the status bar',
      (tester) async {
        final fixture = _Fixture(tester, platform);
        try {
          await fixture.mount();
          await fixture.selectTab(1);
          await tester.tap(find.text('NAS 00'));
          await tester.pumpAndSettle();
          final browser = find.byType(SourceBrowser);
          final browserTitle = find.descendant(
            of: browser,
            matching: find.text('NAS 00'),
          );
          final back = find.descendant(
            of: browser,
            matching: find.byTooltip('返回'),
          );
          final titleTop = tester.getTopLeft(browserTitle).dy;
          expect(titleTop, greaterThanOrEqualTo(_statusBarHeight));
          expect(
            tester.getTopLeft(back).dy,
            greaterThanOrEqualTo(_statusBarHeight),
          );
          final files = find.descendant(
            of: browser,
            matching: find.byType(ListView),
          );
          _scrollPosition(tester, files).jumpTo(200);
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(browserTitle).dy, titleTop);
          expect(
            tester.getTopLeft(files).dy,
            greaterThanOrEqualTo(_statusBarHeight),
          );

          await fixture.selectTab(2);
          final settingsHeader = find.descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(SearchHeader),
          );
          final settingsTop = tester.getTopLeft(settingsHeader).dy;
          expect(settingsTop, _statusBarHeight + 4);
          final settings = find.byKey(const PageStorageKey('settings-general'));
          final settingsScroll = _scrollPosition(tester, settings);
          expect(settingsScroll.maxScrollExtent, greaterThan(0));
          settingsScroll.jumpTo(settingsScroll.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(settingsHeader).dy, settingsTop);

          await fixture.selectTab(0);
          expect(
            tester.getTopLeft(find.text('我的影视库')).dy,
            greaterThanOrEqualTo(_statusBarHeight),
          );
          await fixture.selectTab(1);
          expect(tester.getTopLeft(browserTitle).dy, titleTop);
          _expectStatusBar(Brightness.light);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.close();
        }
      },
    );
  }

  testWidgets('desktop consumes the top safe inset once across tabs', (
    tester,
  ) async {
    final fixture = _Fixture(
      tester,
      TargetPlatform.linux,
      size: const Size(1280, 900),
    );
    try {
      await fixture.mount();
      final library = find.byKey(const PageStorageKey('library-scroll'));
      expect(tester.getTopLeft(library).dy, _statusBarHeight);
      expect(
        tester
            .getTopLeft(
              find.descendant(of: library, matching: find.byType(SearchHeader)),
            )
            .dy,
        _statusBarHeight + 12,
      );
      await fixture.selectTab(1);
      expect(
        tester
            .getTopLeft(find.byKey(const PageStorageKey('sources-scroll')))
            .dy,
        _statusBarHeight,
      );
      expect(
        tester.getTopLeft(find.byTooltip('添加来源')).dy,
        inInclusiveRange(_statusBarHeight + 10, _statusBarHeight + 20),
        reason: 'The button stays in the header without a second top inset.',
      );
      await fixture.selectTab(2);
      expect(
        tester
            .getTopLeft(
              find.descendant(
                of: find.byType(SettingsPage),
                matching: find.byType(SearchHeader),
              ),
            )
            .dy,
        _statusBarHeight + 12,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.close();
    }
  });
}

ScrollPosition _scrollPosition(WidgetTester tester, Finder list) => tester
    .state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    )
    .position;

Future<void> _scrollIntoStatusBar(
  WidgetTester tester,
  Finder list,
  Finder heading,
) async {
  final viewport = find
      .descendant(of: list, matching: find.byType(Viewport))
      .first;
  expect(tester.getTopLeft(viewport).dy, 0);
  final initialTop = tester.getTopLeft(heading).dy;
  expect(initialTop, greaterThanOrEqualTo(_statusBarHeight));
  final position = _scrollPosition(tester, list);
  final target = initialTop - _statusBarHeight / 2;
  expect(position.maxScrollExtent, greaterThan(target));
  position.jumpTo(target);
  await tester.pumpAndSettle();
  expect(tester.getTopLeft(heading).dy, closeTo(_statusBarHeight / 2, .01));
  expect(tester.getTopLeft(viewport).dy, 0);
  _expectStatusBar(Brightness.light);
  position.jumpTo(0);
  await tester.pumpAndSettle();
}

void _expectStatusBar(Brightness brightness) {
  // Inspect the resolved style sent by the render tree to the platform.
  final overlay = SystemChrome.latestStyle!;
  expect(overlay.statusBarColor, Colors.transparent);
  expect(overlay.systemStatusBarContrastEnforced, isFalse);
  expect(
    overlay.statusBarIconBrightness,
    brightness == Brightness.dark ? Brightness.light : Brightness.dark,
  );
  expect(overlay.statusBarBrightness, brightness);
}

class _Fixture {
  final WidgetTester tester;
  final directory = Directory.systemTemp.createTempSync('aiplayer-status-bar-');
  final store = AppStore(':memory:');
  late final AppModel model;

  _Fixture(
    this.tester,
    TargetPlatform platform, {
    Size size = const Size(390, 844),
  }) {
    FlutterSecureStorage.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(
      top: _statusBarHeight,
      bottom: _gestureAreaHeight,
    );
    tester.view.viewPadding = const FakeViewPadding(
      top: _statusBarHeight,
      bottom: _gestureAreaHeight,
    );
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.setLocal('sources', [
      for (var i = 0; i < 30; i++)
        {
          'id': 'nas-$i',
          'kind': 'webdav',
          'label': 'NAS ${i.toString().padLeft(2, '0')}',
        },
    ]);
    for (var i = 0; i < 30; i++) {
      final id = 'video-$i';
      store.save('media', id, {
        'title': '视频 $i.mp4',
        'series': '未分类',
        'size': i + 100,
      });
      store.setLocal('location:$id', {
        'id': id,
        'source': 'local',
        'path': '${directory.path}/$id.mp4',
      });
    }
    model = _FolderModel(store, directory);
  }

  Future<void> mount() async {
    await tester.pumpWidget(AIPlayerApp(model: model));
    await tester.pumpAndSettle();
  }

  Future<void> selectTab(int index) async {
    await tester.tap(find.byKey(ValueKey('nav-item-$index')));
    await tester.pumpAndSettle();
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDefaultTargetPlatformOverride = null;
  }
}

class _FolderModel extends AppModel {
  _FolderModel(super.store, super.documents);

  @override
  Future<SourceAdapter> adapter(String id) async => _Folders();
}

class _Folders extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async => [
    for (var i = 0; i < 30; i++)
      SourceEntry(name: '文件夹 $i', path: 'folder-$i/', directory: true),
  ];

  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path, directory: true);

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}
