import 'dart:io';
import 'dart:math' show max;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('source folder downloads one file or a selected batch', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = Directory.systemTemp.createTempSync(
      'source-download-ui-',
    );
    final store = AppStore(
      ':memory:',
    )..setLocal('settings', {'metadataStrategy': 'off', 'autoDiscover': false});
    final model = _SourceModel(store, directory);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: SourceBrowser(
            model: model,
            source: const {'id': 'dav', 'kind': 'webdav', 'label': 'DAV'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('下载视频'), findsNWidgets(2));
      await tester.tap(find.byTooltip('下载视频').first);
      await tester.pumpAndSettle();
      expect(model.requests, [
        ['dav', '/share/alpha.mkv'],
      ]);
      await tester.tap(find.byTooltip('选择下载'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('download-selection-list')),
          matching: find.text('notes.nfo'),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('download-select:1')));
      await tester.pump();
      await tester.tap(find.text('下载 (1)'));
      await tester.pumpAndSettle();
      expect(model.requests.last, ['dav', '/share/beta.mp4']);
      expect(
        find.byKey(const ValueKey('download-selection-list')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'source selection mixes folders and videos and exposes folder shortcuts',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'source-folder-download-ui-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        });
      final model = _SourceModel(store, directory, withFolder: true);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'dav', 'kind': 'webdav', 'label': 'DAV'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('选择下载'));
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsNWidgets(3));
        expect(find.text('文件夹包含所有子目录中的视频。'), findsOneWidget);
        final selection = find.byKey(const ValueKey('download-selection-list'));
        expect(
          find.descendant(of: selection, matching: find.text('notes.nfo')),
          findsNothing,
        );
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Season'));
        await tester.pump();
        await tester.tap(find.widgetWithText(CheckboxListTile, 'alpha.mkv'));
        await tester.pump();
        await tester.tap(find.text('下载 (2)'));
        await tester.pumpAndSettle();
        expect(model.requests.single, [
          'dav',
          '/share/Season/',
          '/share/alpha.mkv',
        ]);
        expect(model.batches.single.first.directory, isTrue);
        expect(model.batches.single.last.directory, isFalse);

        await tester.longPress(find.byKey(const ValueKey('/share/Season/')));
        await tester.pumpAndSettle();
        expect(find.text('包含子文件夹内的视频'), findsOneWidget);
        await tester.tap(find.text('下载文件夹'));
        await tester.pumpAndSettle();
        expect(model.requests.last, ['dav', '/share/Season/']);
        expect(model.batches.last.single.directory, isTrue);

        await tester.tap(find.byTooltip('文件夹选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载当前文件夹（含子目录）'));
        await tester.pumpAndSettle();
        expect(model.requests.last, ['dav', '']);
        expect(model.batches.last.single.directory, isTrue);
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
    'desktop folder menu opens from its trailing button and keeps row navigation',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'source-desktop-folder-menu-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        });
      final model = _SourceModel(store, directory, withFolder: true);
      final folder = find.byKey(const ValueKey('/share/Season/'));
      final menu = find.byKey(const ValueKey('folder-options:/share/Season/'));
      try {
        // A narrow desktop window still needs a mouse-accessible folder menu.
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme().copyWith(
              platform: TargetPlatform.linux,
            ),
            home: SourceBrowser(
              model: model,
              source: const {'id': 'dav', 'kind': 'webdav', 'label': 'DAV'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(menu, findsOneWidget);
        expect(
          tester.getCenter(menu).dx,
          greaterThan(tester.getCenter(folder).dx),
        );
        expect(
          tester
              .widget<ListTile>(
                find.descendant(of: folder, matching: find.byType(ListTile)),
              )
              .onLongPress,
          isNull,
        );

        await tester.tap(menu);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text('重新识别影视资料'), findsOneWidget);
        expect(find.text('手动搜索影视资料'), findsOneWidget);
        await tester.tap(find.text('收藏文件夹'));
        await tester.pumpAndSettle();
        expect(menu, findsOneWidget);
        expect(
          find.descendant(
            of: folder,
            matching: find.byIcon(Icons.star_rounded),
          ),
          findsOneWidget,
        );

        await tester.tap(menu);
        await tester.pumpAndSettle();
        expect(find.text('取消收藏'), findsOneWidget);
        await tester.tap(find.text('下载文件夹'));
        await tester.pumpAndSettle();
        expect(model.requests.single, ['dav', '/share/Season/']);
        expect(model.batches.single.single.directory, isTrue);
        expect(folder, findsOneWidget);

        await tester.tap(
          find.descendant(of: folder, matching: find.text('Season')),
        );
        await tester.pumpAndSettle();
        expect(menu, findsNothing);
        expect(find.text('Season'), findsOneWidget);
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
    'downloaded local video retains shared details and can be deleted',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync(
        'download-local-ui-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        })
        ..setLocal('sources', [
          {'id': 'dav', 'kind': 'webdav', 'label': '我的下载来源'},
        ])
        ..save('media', 'episode', {
          'title': 'Series S01E01.mkv',
          'fileName': 'Series S01E01.mkv',
          'series': '离线系列',
          'season': '1',
          'episode': '1',
          'metadataTitle': '离线系列',
          'bangumiId': '77',
        })
        ..setLocal('location:episode', {
          'id': 'episode',
          'source': 'dav',
          'path': '/share/episode.mkv',
          'size': 100,
        });
      final model = _CompletedModel(store, directory);
      final played = <String>[];
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(
              body: SourcesPage(
                model: model,
                onImport: () async {},
                onPlay: (media) async => played.add(media.id),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('本地视频'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('local-video:episode')), findsNothing);
        await tester.tap(find.text('我的下载来源'));
        await tester.pumpAndSettle();
        expect(find.text('share'), findsOneWidget);
        await tester.tap(find.text('share'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('local-video:episode')),
          findsOneWidget,
        );
        expect(find.byTooltip('已下载'), findsNothing);
        expect(find.byIcon(Icons.download_done_rounded), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('local-video-options:episode')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('影视详情'));
        await tester.pumpAndSettle();
        expect(find.byType(MediaDetailsOverview), findsOneWidget);
        expect(find.byType(MediaDetailsEpisodeTile), findsOneWidget);
        expect(find.text('离线系列'), findsWidgets);
        final downloaded = find.descendant(
          of: find.byType(MediaDetailsEpisodeTile),
          matching: find.byTooltip('已下载'),
        );
        expect(downloaded, findsNothing);
        expect(find.byTooltip('选择下载'), findsOneWidget);
        Navigator.of(tester.element(find.byType(MediaDetailsOverview))).pop();
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('local-video-options:episode')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除本地视频'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(model.downloads.entryFor('episode'), isNotNull);
        await tester.tap(
          find.byKey(const ValueKey('local-video-options:episode')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除本地视频'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        expect(model.downloads.entryFor('episode'), isNull);
        expect(store.get('media', 'episode')?.deleted, isFalse);
        expect(store.local('location:episode')['source'], 'dav');
        expect(find.text('还没有本地视频'), findsOneWidget);
        expect(find.text('share'), findsNothing);
        expect(played, isEmpty);
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
    'large local directories restore scroll and search and reject a changed deletion binding',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('local-tree-ui-');
      final store = AppStore(':memory:')
        ..setLocal('settings', {
          'metadataStrategy': 'off',
          'autoDiscover': false,
        })
        ..setLocal('sources', [
          {'id': 'dav', 'kind': 'webdav', 'label': '下载来源'},
        ]);
      final model = _CompletedModel(store, directory);
      model.downloads.entries.clear();
      model.downloads.completedLocations.clear();
      void add(String id, String path) {
        final name = path.split('/').last;
        store.save('media', id, {'title': name, 'fileName': name, 'size': 100});
        store.setLocal('location:$id', {
          'id': id,
          'source': 'dav',
          'path': path,
          'size': 100,
        });
        model.downloads.entries[id] = OfflineDownload(
          mediaId: id,
          sourceId: 'dav',
          remotePath: path,
          localPath: '/offline/$path',
          name: name,
          status: OfflineDownloadStatus.completed,
          received: 100,
          total: 100,
        );
        model.downloads.completedLocations[id] = {
          'id': id,
          'source': 'local',
          'path': '/offline/$path',
          'size': 100,
          'offline': true,
          'remoteSource': 'dav',
          'remotePath': path,
        };
      }

      for (var i = 0; i < 300; i++) {
        add('file-$i', 'share/Video ${i.toString().padLeft(3, '0')}.mp4');
      }
      add('nested', 'share/Season 2/Nested.mp4');
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(finder, findsOneWidget);
        await tester.pumpAndSettle();
      }

      try {
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
        await tester.tap(find.text('本地视频'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载来源'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('share'));
        await tester.pump();
        // The source's old child row must not appear under the new title while
        // the 301 entries are sorted on the directory worker.
        expect(find.text('share'), findsOneWidget);
        await waitFor(find.byKey(const ValueKey('local-video:file-0')));
        final list = find.byType(ListView);
        await tester.drag(list, const Offset(0, -700));
        await tester.pumpAndSettle();
        ScrollPosition position() => tester
            .state<ScrollableState>(
              find.descendant(of: list, matching: find.byType(Scrollable)),
            )
            .position;
        final offset = position().pixels;
        expect(offset, greaterThan(500));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.text('share'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 200 && position().pixels < offset - 1; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(position().pixels, closeTo(offset, 1));

        await tester.fling(list, const Offset(0, -300), 1200);
        expect(position().isScrollingNotifier.value, isTrue);
        // Lifecycle suspension ends scrolling immediately without a frame.
        await tester.runAsync(() async {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          final pausedOffset = position().pixels;
          expect(position().isScrollingNotifier.value, isFalse);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(position().pixels, pausedOffset);
        });
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        position().jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索'));
        await tester.pumpAndSettle();
        final search = find.byKey(const ValueKey('folder-search-field'));
        await tester.enterText(search, 'Season');
        await tester.pump(const Duration(milliseconds: 200));
        await waitFor(find.text('Season 2'));
        await tester.tap(find.text('Season 2'));
        await tester.pumpAndSettle();
        expect(search, findsNothing);
        expect(
          find.byKey(const ValueKey('local-video:nested')),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(search).controller!.text, 'Season');
        await waitFor(find.text('Season 2'));
        await tester.tap(find.text('Season 2'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('local-video-options:nested')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除本地视频'));
        await tester.pumpAndSettle();
        store.setLocal('location:nested', {
          'id': 'nested',
          'source': 'dav',
          'path': 'replacement.mp4',
          'size': 100,
        });
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        expect(find.textContaining('视频位置已改变'), findsOneWidget);
        expect(model.downloads.entryFor('nested'), isNotNull);
        expect(store.get('media', 'nested')?.deleted, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );
}

class _SourceModel extends AppModel {
  _SourceModel(super.store, super.documents, {this.withFolder = false})
    : super(backgroundWork: false);
  final bool withFolder;
  final requests = <List<String>>[];
  final batches = <List<SourceEntry>>[];
  @override
  Future<SourceAdapter> adapter(String id) async =>
      _Source(withFolder: withFolder);
  @override
  Future<void> downloadSourceEntries(
    String sourceId,
    Iterable<SourceEntry> entries,
  ) async {
    final selected = entries.toList();
    batches.add(selected);
    requests.add([sourceId, for (final entry in selected) entry.path]);
  }
}

class _Source extends SourceAdapter {
  final bool withFolder;
  _Source({this.withFolder = false});
  @override
  Future<List<SourceEntry>> list(String path) async => [
    if (withFolder && path.isEmpty)
      const SourceEntry(
        name: 'Season',
        path: '/share/Season/',
        directory: true,
      ),
    const SourceEntry(name: 'alpha.mkv', path: '/share/alpha.mkv', size: 100),
    const SourceEntry(name: 'beta.mp4', path: '/share/beta.mp4', size: 100),
    const SourceEntry(name: 'notes.nfo', path: '/share/notes.nfo'),
  ];
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

class _CompletedModel extends AppModel {
  _CompletedModel(super.store, super.documents) : super(backgroundWork: false) {
    downloads.addListener(changed);
  }
  @override
  final _CompletedDownloads downloads = _CompletedDownloads();
  late final _reader = LibrarySnapshotReader(store);
  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) => _reader.read(
    query: query,
    revision: (
      store.recordsRevision('media'),
      store.recordsRevision('progress'),
      max(store.locationRevision, store.localKeyRevision('sources')),
    ),
    offlineRevision: downloads.completedRevision,
    offlineLocations: downloads.completedLocations,
  );
  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async => [record];
  @override
  Future<void> deleteDownload(String id) async {
    downloads.entries.remove(id);
    downloads.completedLocations.remove(id);
    downloads.completedRevision++;
    downloads.changed();
  }

  @override
  Future<void> deleteLocalVideo(SyncRecord record) => deleteDownload(record.id);

  @override
  void dispose() {
    _reader.dispose();
    downloads.dispose();
    super.dispose();
  }
}

class _CompletedDownloads extends ChangeNotifier implements OfflineDownloads {
  @override
  int completedRevision = 1;
  @override
  final entries = <String, OfflineDownload>{
    'episode': const OfflineDownload(
      mediaId: 'episode',
      sourceId: 'dav',
      remotePath: '/share/episode.mkv',
      localPath: '/offline/share/episode.mkv',
      name: 'Series S01E01.mkv',
      status: OfflineDownloadStatus.completed,
      received: 100,
      total: 100,
    ),
  };
  @override
  final completedLocations = <String, Map<String, dynamic>>{
    'episode': {
      'id': 'episode',
      'source': 'local',
      'path': '/offline/share/episode.mkv',
      'size': 100,
      'offline': true,
      'remoteSource': 'dav',
      'remotePath': '/share/episode.mkv',
    },
  };
  @override
  OfflineDownload? entryFor(String mediaId) => entries[mediaId];
  void changed() => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
