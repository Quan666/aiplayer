import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/directory_preview_context.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_identity.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/playback_source.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/media_details_content.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _poster = 'https://offline.invalid/local-series.png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await Future.wait([
      (FontLoader('NotoSansSC')
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')))
          .load(),
      (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load(),
    ]);
  });

  Future<_Fixture> mount(WidgetTester tester, {bool cachedOnly = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = _Fixture();
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      fixture.model.dispose();
      fixture.store.dispose();
      await fixture.directory.delete(recursive: true);
    });
    await tester.runAsync(() async {
      final file = fixture.model.posterCache.cachedFile(_poster);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        await File('assets/branding/app_icon.png').readAsBytes(),
      );
    });
    fixture.add(
      'one',
      episode: '1',
      relative: '本地番剧/01.mkv',
      identified: !cachedOnly,
      parsed: true,
    );
    fixture.add(
      'two',
      episode: '2',
      relative: '本地番剧/附加目录/02.mkv',
      identified: !cachedOnly,
      parsed: true,
    );
    if (!cachedOnly) {
      fixture.add('remote-only', episode: '3', downloaded: false);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme().copyWith(platform: TargetPlatform.macOS),
        home: RepaintBoundary(
          key: const ValueKey('local-collection-screen'),
          child: Scaffold(
            body: SourcesPage(
              model: fixture.model,
              onImport: () async {},
              onPlay: (media) async => fixture.played.add(media.id),
              onPlaySource: (choice) async => fixture.selected.add(choice),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地视频'));
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> coverReady(WidgetTester tester, Finder scope) async {
    final image = find.descendant(of: scope, matching: find.byType(RawImage));
    for (var i = 0; i < 80; i++) {
      if (tester
          .widgetList<RawImage>(image)
          .any((value) => value.image != null)) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    fail('Cached local collection poster did not decode');
  }

  testWidgets(
    'downloaded folders show cached covers and local-only details offline',
    (tester) async {
      final fixture = await mount(tester);
      final folder = find.ancestor(
        of: find.text('本地番剧'),
        matching: find.byType(ListTile),
      );
      expect(find.byType(MediaDetailsOverview), findsNothing);
      expect(
        tester
            .widget<MediaArtwork>(
              find.descendant(of: folder, matching: find.byType(MediaArtwork)),
            )
            .poster,
        _poster,
      );
      await coverReady(tester, folder);
      await _capture(tester, 'local-folders');
      await tester.tap(
        find.descendant(of: folder, matching: find.byTooltip('文件夹选项')),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除文件夹'), findsOneWidget);
      Navigator.of(tester.element(find.text('删除文件夹'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地番剧'));
      await tester.pumpAndSettle();
      final overview = tester.widget<MediaDetailsOverview>(
        find.byType(MediaDetailsOverview),
      );
      expect(overview.details.title, '缓存番剧');
      expect(overview.details.availableEpisodes, 2);
      expect(overview.details.totalEpisodes, 12);
      expect(
        overview.records.map((record) => record.id),
        containsAll(['one', 'two']),
      );
      expect(
        overview.records.any((record) => record.id == 'remote-only'),
        isFalse,
      );
      expect(find.text('已经保存的作品简介'), findsOneWidget);
      expect(find.byType(MediaDetailsEpisodeTile), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('local-video:remote-only')),
        findsNothing,
      );
      expect(find.text('附加目录'), findsOneWidget);
      await coverReady(tester, find.byType(MediaDetailsOverview));
      await _capture(tester, 'local-collection-details');
      expect(fixture.model.adapterReads, 0);
      expect(fixture.model.posterNetworkReads, 0);
      for (final id in ['two', 'remote-only']) {
        fixture.store.save(
          'progress',
          fixture.model.progressKey(fixture.store.get('media', id)!),
          {
            'position': 20,
            'duration': 100,
            'updatedAt': id == 'two'
                ? '2026-10-29T12:00:00Z'
                : '2026-10-29T13:00:00Z',
          },
        );
      }
      fixture.model.changed();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MediaDetailsOverview>(find.byType(MediaDetailsOverview))
            .latest
            ?.id,
        'two',
      );
      await tester.tap(find.byKey(const ValueKey('local-video:one')));
      await tester.pumpAndSettle();
      expect(fixture.played, ['one']);
      await tester.tap(find.byKey(const ValueKey('local-video-options:one')));
      await tester.pumpAndSettle();
      expect(find.text('切换版本与来源'), findsNothing);
      expect(find.text('删除本地视频'), findsOneWidget);
      Navigator.of(tester.element(find.text('删除本地视频'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('附加目录'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MediaDetailsOverview>(find.byType(MediaDetailsOverview))
            .details
            .availableEpisodes,
        1,
      );
      expect(find.byKey(const ValueKey('local-video:one')), findsNothing);
      expect(find.byKey(const ValueKey('local-video:two')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MediaDetailsEpisodeTile), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local collection menus switch sources and retain search and deletion',
    (tester) async {
      final fixture = await mount(tester);
      fixture.store.setLocal('sources', [
        {'id': 'dav', 'kind': 'webdav', 'label': '云盘'},
      ]);
      fixture.model.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地番剧'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-video-options:one')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换版本与来源'));
      await tester.pumpAndSettle();
      expect(find.text('WebDAV · 云盘'), findsOneWidget);
      expect(find.text('本地 · 已下载'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('media-source:one:offline')));
      await tester.pumpAndSettle();
      expect(
        fixture.selected.single.preference,
        PlaybackSourcePreference.offline,
      );
      expect(fixture.selected.single.media.id, 'one');
      expect(fixture.played, isEmpty);

      await tester.tap(find.byKey(const ValueKey('local-video-options:one')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换版本与来源'));
      await tester.pumpAndSettle();
      // Lifecycle changes invalidate a pending choice without another frame.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.tap(find.byKey(const ValueKey('media-source:one:original')));
      await tester.pumpAndSettle();
      expect(fixture.selected, hasLength(1));

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-search-field')),
        '02',
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local-video:one')), findsNothing);
      expect(find.byKey(const ValueKey('local-video:two')), findsOneWidget);
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('排序与显示'));
      await tester.pumpAndSettle();
      expect(find.text('降序'), findsOneWidget);
      Navigator.of(tester.element(find.text('降序'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-video-options:one')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除本地视频'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(fixture.model.downloads.entryFor('one'), isNull);
      expect(fixture.store.get('media', 'one')?.deleted, isFalse);
      expect(find.byKey(const ValueKey('local-video:one')), findsNothing);
      expect(
        tester
            .widget<MediaDetailsOverview>(find.byType(MediaDetailsOverview))
            .details
            .availableEpisodes,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local episodes show the best version and keep all source choices',
    (tester) async {
      final fixture = await mount(tester);
      fixture.add('high', episode: '1', relative: '本地番剧/01.2160p.mkv');
      fixture.store.setLocal('sources', [
        {'id': 'dav', 'kind': 'webdav', 'label': '云盘'},
      ]);
      fixture.model.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地番剧'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaDetailsEpisodeTile), findsNWidgets(2));
      expect(find.byKey(const ValueKey('local-video:one')), findsNothing);
      expect(find.byKey(const ValueKey('local-video:high')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-video-options:high')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换版本与来源'));
      await tester.pumpAndSettle();
      for (final id in ['one', 'high']) {
        for (final source in ['original', 'offline']) {
          expect(
            find.byKey(ValueKey('media-source:$id:$source')),
            findsOneWidget,
          );
        }
      }
      await tester.tap(find.byKey(const ValueKey('media-source:one:offline')));
      await tester.pumpAndSettle();
      expect(fixture.selected.single.media.id, 'one');
      expect(
        fixture.selected.single.preference,
        PlaybackSourcePreference.offline,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached directory facts refresh on resume without changing media records',
    (tester) async {
      final fixture = await mount(tester, cachedOnly: true);
      expect(find.byType(MediaArtwork), findsNothing);
      final before = fixture.model.snapshotReads;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      fixture.cacheDirectoryFacts('one', '第一集缓存标题');
      fixture.cacheDirectoryFacts('two', '第二集缓存标题');
      fixture.store.setLocal('episodeTitle:one', '本机优先标题');
      fixture.store.save(
        'progress',
        fixture.model.progressKey(fixture.store.get('media', 'two')!),
        {'position': 20, 'duration': 100, 'updatedAt': '2026-10-29T12:00:00Z'},
      );
      fixture.model.changed();
      fixture.model.changed();
      expect(fixture.model.snapshotReads, before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.model.snapshotReads, before + 1);
      expect(find.byType(MediaArtwork), findsOneWidget);
      await tester.tap(find.text('本地番剧'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaDetailsOverview), findsOneWidget);
      expect(find.text('第 1 集 · 本机优先标题'), findsOneWidget);
      expect(find.text('第 2 集 · 第二集缓存标题'), findsOneWidget);
      expect(find.text('继续观看 · 第 2 集 · 第二集缓存标题'), findsOneWidget);
      expect(
        fixture.store.get('media', 'one')!.data,
        isNot(contains('poster')),
      );
      expect(
        fixture.store.get('media', 'two')!.data,
        isNot(contains('episodeTitle')),
      );
      fixture.store.setLocal('episodeTitle:two', '本机第二集');
      fixture.model.changed();
      await tester.pumpAndSettle();
      expect(find.text('第 2 集 · 本机第二集'), findsOneWidget);
      expect(find.text('继续观看 · 第 2 集 · 本机第二集'), findsOneWidget);
      expect(fixture.model.adapterReads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mixed ordinary local folders keep file browsing', (
    tester,
  ) async {
    final fixture = await mount(tester);
    fixture.add('unidentified', relative: '本地番剧/notes.mp4', identified: false);
    fixture.model.changed();
    await tester.pumpAndSettle();
    final folder = find.ancestor(
      of: find.text('本地番剧'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: folder, matching: find.byType(MediaArtwork)),
      findsNothing,
    );
    await tester.tap(find.text('本地番剧'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaDetailsOverview), findsNothing);
    expect(find.byType(MediaDetailsEpisodeTile), findsNothing);
    expect(find.byKey(const ValueKey('local-video:one')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local-video:unidentified')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('local-video:two')), findsNothing);
    expect(find.text('附加目录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['AIPLAYER_UI_SCREENSHOTS'];
  if (output == null || output.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('local-collection-screen')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

class _Fixture {
  final directory = Directory.systemTemp.createTempSync('local-collection-ui-');
  final store = AppStore(':memory:')
    ..setLocal('settings', {'metadataStrategy': 'off', 'autoDiscover': false});
  late final model = _Model(store, directory);
  final played = <String>[];
  final selected = <MediaPlaybackChoice>[];

  void add(
    String id, {
    String? episode,
    String? relative,
    bool downloaded = true,
    bool identified = true,
    bool parsed = false,
  }) {
    final name = relative?.split('/').last ?? '$id.mkv';
    final remote = '/NAS/2026-10/${relative ?? '本地番剧/$name'}';
    store.save('media', id, {
      'title': name,
      'fileName': name,
      'size': 100,
      if (identified || parsed) ...{
        'series': '缓存番剧',
        'season': '1',
        'episode': episode,
      },
      if (identified) ...{
        'metadataTitle': '缓存番剧',
        'bangumiId': '77',
        'poster': _poster,
        'summary': '已经保存的作品简介',
        'totalEpisodes': 12,
      },
    });
    store.setLocal('location:$id', {
      'id': id,
      'source': 'dav',
      'path': remote,
      'size': 100,
    });
    if (!downloaded) return;
    final local = '${directory.path}/offline/$relative';
    const root = '/NAS/2026-10/本地番剧';
    model.downloads.entries[id] = OfflineDownload(
      mediaId: id,
      sourceId: 'dav',
      remotePath: remote,
      localPath: local,
      name: name,
      status: OfflineDownloadStatus.completed,
      received: 100,
      total: 100,
      downloadRoot: root,
      downloadRelativePath: relative,
    );
    model.downloads.completedLocations[id] = {
      'id': id,
      'source': 'local',
      'path': local,
      'size': 100,
      'offline': true,
      'remoteSource': 'dav',
      'remotePath': remote,
      'downloadRoot': root,
      'downloadRelativePath': relative,
    };
    model.downloads.completedRevision++;
  }

  void cacheDirectoryFacts(String id, String episodeTitle) {
    final record = store.get('media', id)!;
    final location = store.local('location:$id') as Map;
    final path = location['path'] as String;
    final parent = path.substring(0, path.lastIndexOf('/'));
    final settings = store.local('settings') as Map;
    persistDirectoryPreview(
      store,
      'dav',
      parent,
      DirectoryPreview(
        collection: DirectoryCollection(
          title: '缓存番剧',
          season: '1',
          videos: [
            SourceEntry(name: record.data['fileName'], path: path, size: 100),
          ],
          identities: {
            path: ReleaseName('缓存番剧', '1', '${record.data['episode']}'),
          },
          subject: const {
            'id': 77,
            'name': '缓存番剧',
            'summary': '已经保存的作品简介',
            'images': {'large': _poster},
            'eps': 12,
          },
          episodeTitles: {'${record.data['episode']}': episodeTitle},
        ),
        context: directoryPreviewContext(
          source: null,
          strategy: '${settings['metadataStrategy']}',
          aiContext: jsonEncode([
            AppPreferences(
              Map<String, dynamic>.from(settings),
            ).aiMetadataEnabled,
            settings['aiSubtitleOrigin'],
            settings['aiSubtitleModel'],
            store.local('metadataCredentialsRevision'),
          ]),
        ),
        fingerprint: 'cached-membership-$id',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        modified: 0,
      ),
    );
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents) : super(backgroundWork: false);
  int adapterReads = 0, posterNetworkReads = 0, snapshotReads = 0;
  @override
  final _Downloads downloads = _Downloads();
  late final _reader = LibrarySnapshotReader(store);
  late final _posters = PosterCache(
    directory: Directory('${documents.path}/posters'),
    createClient: () {
      posterNetworkReads++;
      throw StateError('Local cached artwork must not use the network');
    },
  );
  @override
  PosterCache get posterCache => _posters;
  @override
  Future<SourceAdapter> adapter(String id) async {
    adapterReads++;
    throw const AppFailure('来源离线');
  }

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) {
    cancel?.check();
    snapshotReads++;
    return _reader.read(
      query: query,
      revision: (
        store.recordsRevision('media'),
        store.recordsRevision('progress'),
        max(
          max(store.locationRevision, store.localKeyRevision('sources')),
          max(
            store.localPrefixRevision('technical:'),
            store.localPrefixRevision('externalSource:'),
          ),
        ),
      ),
      offlineRevision: downloads.completedRevision,
      offlineLocations: downloads.completedLocations,
      localMetadataRevision: libraryLocalMetadataRevision,
    );
  }

  @override
  Future<void> deleteLocalVideo(SyncRecord record) async {
    downloads.entries.remove(record.id);
    downloads.completedLocations.remove(record.id);
    downloads.completedRevision++;
    changed();
  }

  @override
  void dispose() {
    _reader.dispose();
    _posters.close();
    downloads.dispose();
    super.dispose();
  }
}

class _Downloads extends ChangeNotifier implements OfflineDownloads {
  @override
  int completedRevision = 0;
  @override
  final entries = <String, OfflineDownload>{};
  @override
  final completedLocations = <String, Map<String, dynamic>>{};
  @override
  OfflineDownload? entryFor(String mediaId) => entries[mediaId];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
