import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/favorites.dart';
import 'package:aiplayer/sources/directory_sort.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/settings_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late AppStore store;
  late _CountingModel model;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('aiplayer-scroll-lists-');
    store = AppStore(
      ':memory:',
    )..setLocal('settings', {'metadataStrategy': 'off', 'autoDiscover': false});
    model = _CountingModel(store, directory);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('source notifications reuse folder and local media snapshots', (
    tester,
  ) async {
    model.addMedia(
      'local',
      const SourceEntry(name: 'first.mp4', path: 'first.mp4'),
    );
    await mount(
      tester,
      SourcesPage(model: model, onImport: () async {}, onPlay: (_) async {}),
    );
    expect(find.text('1 个视频'), findsOneWidget);
    model.mediaReads = 0;
    for (var index = 0; index < 5; index++) {
      store.save('progress', 'first:0', {'position': index});
      model.changed();
      await tester.pumpAndSettle();
    }
    expect(model.mediaReads, 0);
    model.addMedia(
      'local',
      const SourceEntry(name: 'second.mp4', path: 'second.mp4'),
    );
    model.changed();
    await tester.pumpAndSettle();
    expect(find.text('2 个视频'), findsOneWidget);
    expect(model.mediaReads, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'favorites stay lazy and outside source drag gaps and reorder semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        store.setLocal('sources', [
          {'id': 'one', 'kind': 'webdav', 'label': 'NAS 1'},
          {'id': 'two', 'kind': 'webdav', 'label': 'NAS 2'},
        ]);
        store.setLocal(SourceFavorites.storageKey, [
          for (var index = 0; index < 250; index++)
            {'sourceId': 'one', 'path': 'folder-$index/', 'name': '收藏 $index'},
        ]);
        await mount(
          tester,
          SourcesPage(
            model: model,
            onImport: () async {},
            onPlay: (_) async {},
          ),
        );
        final favorites = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('favorite:'),
        );
        expect(favorites.evaluate().length, inExclusiveRange(0, 30));
        expect(find.text('收藏 249'), findsNothing);
        final firstSource = find.byKey(const ValueKey<dynamic>('one'));
        final lastSource = find.byKey(const ValueKey<dynamic>('two'));
        Set<String> actionsFor(Finder row) {
          final labels = <String>{};
          SemanticsNode? node = tester.getSemantics(row);
          while (node != null) {
            for (final id
                in node.getSemanticsData().customSemanticsActionIds ??
                    const <int>[]) {
              final label = CustomSemanticsAction.getAction(id)?.label;
              if (label != null) labels.add(label);
            }
            node = node.parent;
          }
          return labels;
        }

        final localization = WidgetsLocalizations.of(
          tester.element(firstSource),
        );
        expect(actionsFor(firstSource), contains(localization.reorderItemDown));
        expect(
          actionsFor(lastSource),
          isNot(contains(localization.reorderItemDown)),
        );
        expect(actionsFor(find.text('我的收藏')), isEmpty);
        expect(actionsFor(find.text('收藏 0')), isEmpty);
        final headingTop = tester.getTopLeft(find.text('我的收藏')).dy;
        final favoriteTop = tester.getTopLeft(find.text('收藏 0')).dy;
        final target = tester.getCenter(find.text('收藏 2'));
        final drag = await tester.startGesture(tester.getCenter(firstSource));
        await tester.pump(kLongPressTimeout + kPressTimeout);
        await drag.moveTo(target);
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.getTopLeft(find.text('我的收藏')).dy,
          closeTo(headingTop, .01),
        );
        expect(
          tester.getTopLeft(find.text('收藏 0')).dy,
          closeTo(favoriteTop, .01),
        );
        await drag.up();
        await tester.pumpAndSettle();
        expect(model.sources.map((source) => source['id']), ['two', 'one']);
        expect(SourceFavorites(store).all, hasLength(250));
        await tester.drag(
          find.byKey(const PageStorageKey('sources-scroll')),
          const Offset(0, -1800),
        );
        await tester.pumpAndSettle();
        expect(favorites.evaluate().length, inExclusiveRange(0, 30));
        expect(find.text('收藏 0'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'sync settings omit conflict decisions and preserve form drafts',
    (tester) async {
      for (var index = 0; index < 200; index++) {
        store.save('progress', 'conflict-$index', {'position': 10});
        store.conflict(
          SyncRecord(
            kind: 'progress',
            id: 'conflict-$index',
            data: const {'position': 20},
            version: 2,
          ),
        );
      }
      await mount(tester, SettingsPage(model: model));
      final chip = find.widgetWithText(ChoiceChip, '同步');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '同步服务地址',
      );
      await tester.enterText(field, 'https://draft.example');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.text('同步冲突'), findsNothing);
      expect(find.text('保留本机'), findsNothing);
      expect(find.text('采用服务端'), findsNothing);
      expect(find.text('progress · conflict-199'), findsNothing);
      final list = find.byKey(const PageStorageKey('settings-sync'));
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('同步冲突'), findsNothing);
      expect(find.text('保留本机'), findsNothing);
      expect(find.text('采用服务端'), findsNothing);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'https://draft.example',
      );
      await tester.ensureVisible(find.text('保存同步配置'));
      await tester.tap(find.text('保存同步配置'));
      await tester.pumpAndSettle();
      expect(model.settings['syncOrigin'], 'https://draft.example');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'browser layout rebuilds reuse collection records until data changes',
    (tester) async {
      for (final entry in _Episodes.entries) {
        model.addMedia('nas', entry);
      }
      Widget browser(double width) => SizedBox(
        width: width,
        child: SourceBrowser(
          model: model,
          source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
        ),
      );
      await mount(tester, browser(800));
      expect(model.collectionReads, greaterThan(0));
      model.collectionReads = 0;
      model.seriesReads = 0;
      await mount(tester, browser(700));
      expect(model.collectionReads, 0);
      expect(model.seriesReads, 0);
      model.sortApplications = 0;
      model.recentReads = 0;
      for (var i = 0; i < 5; i++) {
        store.setLocal('preview:$i', {'path': '/unused/$i.jpg'});
        model.changed();
        await tester.pumpAndSettle();
      }
      expect(model.sortApplications, 0);
      expect(model.collectionReads, 0);
      expect(model.seriesReads, 0);
      expect(model.recentReads, 0);
      model.setDirectorySorting(
        'directorySort:nas:',
        const DirectorySort(descending: true),
      );
      await tester.pumpAndSettle();
      expect(model.sortApplications, 1);
      expect(model.collectionReads, 0);
      expect(model.seriesReads, 0);
      expect(model.recentReads, 0);

      final record = model.sourceMedia('nas', _Episodes.entries.first.path)!;
      store.save('progress', model.progressKey(record), {
        'position': 60,
        'duration': 120,
      });
      store.setLocal('episodeTitle:${record.id}', '新的分集名称');
      model.changed();
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.textContaining('新的分集名称'), findsWidgets);
      expect(find.textContaining('01:00 / 02:00'), findsWidgets);
      expect(model.recentReads, 1);
      expect(model.collectionReads, 0);
      expect(model.seriesReads, 0);

      store.save('media', record.id, {
        ...record.data,
        'metadataTitle': '更新后的作品名',
      });
      model.changed();
      await tester.pumpAndSettle();
      expect(find.text('更新后的作品名'), findsOneWidget);
      expect(model.collectionReads, greaterThan(0));
      expect(model.seriesReads, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _CountingModel extends AppModel {
  int collectionReads = 0, seriesReads = 0, mediaReads = 0;
  int sortApplications = 0, recentReads = 0;
  @override
  DirectorySort directorySorting(String key) =>
      _CountingSort(super.directorySorting(key), () => sortApplications++);
  _CountingModel(super.store, super.documents);

  @override
  List<SyncRecord> get media {
    mediaReads++;
    return super.media;
  }

  // This suite verifies UI draft persistence, not network retry scheduling.
  @override
  Future<void> synchronize({
    bool quiet = false,
    bool sharedOnly = false,
  }) async {}

  @override
  List<SyncRecord> collectionRecords(
    String sourceId,
    DirectoryCollection value,
  ) {
    collectionReads++;
    return super.collectionRecords(sourceId, value);
  }

  @override
  List<SyncRecord> seriesRecords(SyncRecord record) {
    seriesReads++;
    return super.seriesRecords(record);
  }

  @override
  List<SyncRecord> recentMedia({
    bool groupSeries = true,
    Iterable<SyncRecord>? items,
  }) {
    recentReads++;
    return super.recentMedia(groupSeries: groupSeries, items: items);
  }

  @override
  Future<SourceAdapter> adapter(String id) async => _Episodes();

  @override
  bool needsMediaPreview(String id) => false;
}

class _Episodes extends SourceAdapter {
  static final entries = [
    for (var episode = 1; episode <= 40; episode++)
      SourceEntry(
        name: '示例作品 S01E${episode.toString().padLeft(2, '0')}.mkv',
        path: 'show/episode-$episode.mkv',
      ),
  ];

  @override
  Future<List<SourceEntry>> list(String path) async => entries;

  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path);

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

class _CountingSort extends DirectorySort {
  final VoidCallback onApply;
  _CountingSort(DirectorySort value, this.onApply)
    : super(
        field: value.field,
        descending: value.descending,
        showSubtitles: value.showSubtitles,
      );
  @override
  List<SourceEntry> apply(
    Iterable<SourceEntry> entries, {
    bool hideHiddenFiles = true,
  }) {
    onApply();
    return super.apply(entries, hideHiddenFiles: hideHiddenFiles);
  }
}
