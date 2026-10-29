import 'dart:io';
import 'dart:math';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/playback_source.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_source_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<_Fixture> fixture(WidgetTester tester) async {
    final result = _Fixture();
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      result.close();
    });
    return result;
  }

  testWidgets('one media offers its downloaded copy and original source', (
    tester,
  ) async {
    final f = await fixture(tester);
    final media = f.add('episode', 'dav');
    f.downloads.put(media.id);
    MediaPlaybackChoice? selected;
    await tester.pumpWidget(
      _shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showMediaSourceSelection(
                context,
                model: f.model,
                item: media,
              );
            },
            child: const Text('选择'),
          ),
        ),
      ),
    );
    for (final preference in [
      PlaybackSourcePreference.offline,
      PlaybackSourcePreference.original,
    ]) {
      await tester.tap(find.text('选择'));
      await tester.pumpAndSettle();
      expect(find.text('本地 · 已下载'), findsOneWidget);
      expect(find.text('WebDAV · 云盘'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(2));
      await tester.tap(
        find.byKey(ValueKey('media-source:episode:${preference.name}')),
      );
      await tester.pumpAndSettle();
      expect(selected?.media.id, media.id);
      expect(selected?.preference, preference);
      expect(selected?.expectedBinding, {
        'source': 'dav',
        'path': '/share/episode.mkv',
        'previewRevision': '',
      });
    }
    expect(f.downloads.validations, 0);
    expect(f.store.local('location:episode')['source'], 'dav');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a displayed choice retains its binding after reassociation', (
    tester,
  ) async {
    final f = await fixture(tester);
    final media = f.add('episode', 'dav');
    f.add('alternate', 'nas');
    MediaPlaybackChoice? selected;
    await tester.pumpWidget(
      _shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => selected = await showMediaSourceSelection(
              context,
              model: f.model,
              item: media,
            ),
            child: const Text('选择'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    f.store.setLocal('location:episode', {
      'source': 'nas',
      'path': '/other/episode.mkv',
    });
    await tester.tap(
      find.byKey(const ValueKey('media-source:episode:original')),
    );
    await tester.pumpAndSettle();
    expect(selected?.expectedBinding?['source'], 'dav');
    await expectLater(
      f.model.playbackLocation(
        selected!.media,
        preference: selected!.preference,
        expectedBinding: selected!.expectedBinding,
      ),
      throwsA(isA<AppFailure>()),
    );
  });

  testWidgets('single available file hides the combined switch menu', (
    tester,
  ) async {
    final f = await fixture(tester);
    final media = f.add('episode', 'dav');
    final snapshot = await f.model.loadLibrarySnapshot();
    await tester.pumpWidget(
      _shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showLibraryMediaDetails(
              context,
              model: f.model,
              snapshot: snapshot,
              anchor: media,
              onPlay: (_) {},
            ),
            child: const Text('详情'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('视频选项'));
    await tester.pumpAndSettle();
    expect(find.text('切换版本与来源'), findsNothing);
    expect(find.text('查看文件详情'), findsOneWidget);
  });

  testWidgets('combined choices show bitrate and rank local versions first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = await fixture(tester);
    final low = f.add('local-low', 'local');
    final high = f.add('local-high', 'local');
    final remote = f.add('remote-4k', 'dav');
    const MediaTechnicalInfo(
      codec: 'H.264',
      width: 1920,
      height: 1080,
      bitrate: 4000000,
    ).save(f.store, low);
    const MediaTechnicalInfo(
      codec: 'H.264',
      width: 1920,
      height: 1080,
      bitrate: 10000000,
    ).save(f.store, high);
    const MediaTechnicalInfo(
      codec: 'AV1',
      width: 3840,
      height: 2160,
      bitrate: 20000000,
    ).save(f.store, remote);
    MediaPlaybackChoice? selected;
    await tester.pumpWidget(
      _shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => selected = await showMediaSourceSelection(
              context,
              model: f.model,
              item: remote,
            ),
            child: const Text('选择'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    expect(find.text('版本与来源'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.byType(ListTile).first).key,
      const ValueKey('media-source:local-high:original'),
    );
    expect(find.textContaining('10 Mbps'), findsOneWidget);
    expect(find.textContaining('4 Mbps'), findsOneWidget);
    expect(find.text('本地文件'), findsNWidgets(2));
    expect(find.text('默认'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('media-source:local-low:original')),
    );
    await tester.pumpAndSettle();
    expect(selected?.media.id, low.id);
    expect(selected?.preference, PlaybackSourcePreference.original);
    expect(selected?.expectedBinding?['source'], 'local');
    expect(tester.takeException(), isNull);
  });

  testWidgets('version choices identify SMB, WebDAV and local files', (
    tester,
  ) async {
    final f = await fixture(tester);
    final dav = f.add('dav-copy', 'dav');
    f.add('smb-copy', 'nas');
    f.add('local-copy', 'local');
    MediaPlaybackChoice? selected;
    await tester.pumpWidget(
      _shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showMediaSourceSelection(
                context,
                model: f.model,
                item: dav,
              );
            },
            child: const Text('选择'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    expect(find.text('WebDAV · 云盘'), findsOneWidget);
    expect(find.text('SMB · 家中 NAS'), findsOneWidget);
    expect(find.text('本地文件'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('media-source:smb-copy:original')),
    );
    await tester.pumpAndSettle();
    expect(selected?.media.id, 'smb-copy');
    expect(selected?.preference, PlaybackSourcePreference.original);
    expect(f.downloads.validations, 0);
  });

  for (final stale in ['path', 'revision', 'pending']) {
    testWidgets('source picker hides $stale offline copies', (tester) async {
      final f = await fixture(tester);
      final media = f.add('episode', 'dav');
      f.add('alternate', 'nas');
      f.downloads.put(
        media.id,
        path: stale == 'path' ? '/old/episode.mkv' : null,
        revision: stale == 'revision' ? 'old-source' : '',
        status: stale == 'pending'
            ? OfflineDownloadStatus.downloading
            : OfflineDownloadStatus.completed,
      );
      await tester.pumpWidget(
        _shell(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showMediaSourceSelection(
                context,
                model: f.model,
                item: media,
              ),
              child: const Text('选择'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择'));
      await tester.pumpAndSettle();
      expect(find.text('本地 · 已下载'), findsNothing);
      expect(find.text('WebDAV · 云盘'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(2));
      expect(f.downloads.validations, 0);
    });
  }

  testWidgets('large version selection keeps rows lazy', (tester) async {
    final f = await fixture(tester);
    final records = [
      for (var index = 0; index < 300; index++)
        f.add('cut-${index.toString().padLeft(3, '0')}', 'dav'),
    ];
    await tester.pumpWidget(
      _shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaSourceSelection(
              context,
              model: f.model,
              item: records.first,
            ),
            child: const Text('选择'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('media-source-selection'));
    final delegate = tester.widget<ListView>(list).childrenDelegate;
    expect(delegate, isA<SliverChildBuilderDelegate>());
    expect((delegate as SliverChildBuilderDelegate).childCount, 300);
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    final last = (await f.model.loadLibrarySnapshot())
        .playbackOptionsFor(records.first)
        .last;
    expect(
      find.byKey(
        ValueKey('media-source:${last.media.id}:${last.preference.name}'),
      ),
      findsNothing,
    );
    await tester.drag(list, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    expect(f.downloads.validations, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single-record details exposes source selection callback', (
    tester,
  ) async {
    final f = await fixture(tester);
    final media = f.add('episode', 'dav');
    f.downloads.put(media.id);
    final snapshot = await f.model.loadLibrarySnapshot();
    MediaPlaybackChoice? selected;
    var automaticPlays = 0;
    await tester.pumpWidget(
      _shell(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showLibraryMediaDetails(
              context,
              model: f.model,
              snapshot: snapshot,
              anchor: media,
              onPlay: (_) => automaticPlays++,
              onPlaySource: (choice) => selected = choice,
            ),
            child: const Text('详情'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('视频选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换版本与来源'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('media-source:episode:original')),
    );
    await tester.pumpAndSettle();
    expect(selected?.media.id, media.id);
    expect(selected?.preference, PlaybackSourcePreference.original);
    expect(automaticPlays, 0);
    expect(tester.takeException(), isNull);
  });
}

Widget _shell(Widget child) => MaterialApp(
  theme: GlassPalette.theme(),
  home: Scaffold(body: child),
);

class _Fixture {
  final directory = Directory.systemTemp.createTempSync('media-source-ui-');
  final store = AppStore(':memory:');
  final downloads = _Downloads();
  late final model = _Model(store, directory, downloads);

  _Fixture() {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.setLocal('sources', [
      {'id': 'dav', 'kind': 'webdav', 'label': '云盘'},
      {'id': 'nas', 'kind': 'smb', 'label': '家中 NAS'},
    ]);
  }

  SyncRecord add(String id, String source) {
    store.save('media', id, {
      'title': '$id.mkv',
      'fileName': '$id.mkv',
      'series': 'Show',
      'season': '1',
      'episode': '1',
      'size': 100,
    });
    store.setLocal('location:$id', {
      'id': id,
      'source': source,
      'path': '/share/$id.mkv',
      'size': 100,
    });
    return store.get('media', id)!;
  }

  void close() {
    model.dispose();
    downloads.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  }
}

class _Model extends AppModel {
  @override
  final OfflineDownloads downloads;
  _Model(super.store, super.documents, this.downloads)
    : super(backgroundWork: false);

  late final _reader = LibrarySnapshotReader(store);

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) async {
    cancel?.check();
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
    );
  }

  @override
  void dispose() {
    _reader.dispose();
    super.dispose();
  }

  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async => [record];
}

class _Downloads extends ChangeNotifier implements OfflineDownloads {
  final values = <String, OfflineDownload>{};
  int validations = 0;
  @override
  int completedRevision = 0;

  @override
  Map<String, Map<String, dynamic>> get completedLocations => {
    for (final entry in values.values)
      if (entry.isComplete)
        entry.mediaId: {
          'id': entry.mediaId,
          'source': 'local',
          'path': entry.localPath,
          'size': entry.total,
          'offline': true,
          'remoteRevision': entry.bindingRevision,
          'remoteSource': entry.sourceId,
          'remotePath': entry.remotePath,
        },
  };

  @override
  OfflineDownload? entryFor(String mediaId) {
    return values[mediaId];
  }

  void put(
    String id, {
    String? path,
    String revision = '',
    OfflineDownloadStatus status = OfflineDownloadStatus.completed,
  }) {
    values[id] = OfflineDownload(
      mediaId: id,
      sourceId: 'dav',
      remotePath: path ?? '/share/$id.mkv',
      localPath: '/offline/$id.mkv',
      name: '$id.mkv',
      status: status,
      bindingRevision: revision,
      received: status == OfflineDownloadStatus.completed ? 100 : 10,
      total: 100,
    );
    completedRevision++;
    notifyListeners();
  }

  @override
  Future<String?> localPath(String mediaId) async {
    validations++;
    throw StateError('The source picker must not probe local files.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
