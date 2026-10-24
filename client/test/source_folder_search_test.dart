import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'folder search preserves complete listing and dismisses input before play',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('folder-search-');
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _SearchModel(store, directory);
      final navigator = GlobalKey<NavigatorState>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'one', 'kind': 'webdav', 'label': 'NAS'},
              onPlay: (_) => navigator.currentState!.push<void>(
                MaterialPageRoute(
                  builder: (_) => const Scaffold(body: Text('播放中')),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final reads = model.listReads;
        await tester.tap(find.byTooltip('搜索'));
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('folder-search-field'));
        await tester.enterText(input, 'alpha');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        final dynamic browser = tester.state(find.byType(SourceBrowser));
        expect((browser.entries as List<SourceEntry>), hasLength(3));
        expect(
          (browser.displayedEntries as List<SourceEntry>).single.name,
          'Alpha Movie.mkv',
        );
        expect(model.listReads, reads);
        expect(find.textContaining('Beta'), findsNothing);
        await tester.tap(find.textContaining('Alpha').first);
        await tester.pumpAndSettle();
        expect(find.text('播放中'), findsOneWidget);
        tester.testTextInput.log.clear();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(input);
        expect(field.controller!.text, 'alpha');
        expect(field.focusNode!.hasFocus, isFalse);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        expect(
          (browser.displayedEntries as List<SourceEntry>).single.name,
          'Alpha Movie.mkv',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'folder search pauses its pending debounce without another frame and resumes latest query',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'folder-search-paused-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = _SearchModel(store, directory);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'one', 'kind': 'webdav', 'label': 'NAS'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索'));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('folder-search-field')),
        );
        final dynamic browser = tester.state(find.byType(SourceBrowser));
        final initial = browser.displayedEntries;
        final reads = model.listReads;
        // Start the debounce on the real event loop. No pump/frame occurs while
        // paused, so a lifecycle check deferred until build would fail this.
        await tester.runAsync(() async {
          field.controller!.text = 'beta';
          field.onChanged!('beta');
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(identical(browser.displayedEntries, initial), isTrue);
          expect(model.listReads, reads);
        });
        _resume(tester);
        await tester.pumpAndSettle();
        expect(
          (browser.displayedEntries as List<SourceEntry>).single.name,
          'Beta Movie.mkv',
        );
        expect(field.focusNode!.hasFocus, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        _resume(tester);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('local folder searches filenames and recognized titles', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'local-folder-search-',
    );
    final store = AppStore(':memory:')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    final model = _SearchModel(store, directory);
    try {
      final alpha = model.addMedia(
        'local',
        const SourceEntry(name: 'alpha.mp4', path: '/alpha.mp4'),
      );
      model.addMedia(
        'local',
        const SourceEntry(name: 'beta.mp4', path: '/beta.mp4'),
      );
      model.addMedia(
        'local',
        const SourceEntry(name: '.hidden.mp4', path: '/.hidden.mp4'),
      );
      model.addMedia(
        'local',
        const SourceEntry(name: 'captions.ass', path: '/captions.ass'),
      );
      store.save('media', alpha, {'title': '中文片名'});
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            body: SourcesPage(
              model: model,
              onImport: () async {},
              onPlay: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 个视频'), findsOneWidget);
      await tester.tap(find.text('本地视频'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-search-field')),
        '中文片名',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.textContaining('中文片名'), findsWidgets);
      expect(find.textContaining('beta'), findsNothing);
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.textContaining('beta'), findsOneWidget);
      expect(find.textContaining('.hidden'), findsNothing);
      expect(find.textContaining('captions'), findsNothing);
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      // Selecting a video before the open-search frame arrives must cancel
      // that queued focus request, even if the play callback does not push.
      await tester.tap(find.byTooltip('搜索'));
      await tester.tap(find.text('中文片名'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('folder-search-field')),
            )
            .focusNode!
            .hasFocus,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    }
  });
}

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

class _SearchModel extends AppModel {
  int listReads = 0;
  _SearchModel(super.store, super.documents) : super(backgroundWork: false);

  @override
  Future<SourceAdapter> adapter(String id) async => _SearchAdapter(this);
}

class _SearchAdapter extends SourceAdapter {
  final _SearchModel model;
  _SearchAdapter(this.model);
  static const entries = [
    SourceEntry(name: 'Alpha Movie.mkv', path: 'alpha.mkv'),
    SourceEntry(name: 'Beta Movie.mkv', path: 'beta.mkv'),
    SourceEntry(name: 'Notes.txt', path: 'notes.txt'),
  ];
  @override
  Future<List<SourceEntry>> list(String path) async {
    model.listReads++;
    return entries;
  }

  @override
  Future<SourceEntry> stat(String path) async =>
      entries.firstWhere((entry) => entry.path == path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}
