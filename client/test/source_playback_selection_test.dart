import 'dart:io';
import 'dart:math' show max;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/playback_source.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<_Fixture> setup(
    WidgetTester tester, {
    bool known = true,
    bool downloaded = true,
    bool alternate = false,
    List<SourceEntry>? entries,
    String? initialPath,
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = _Fixture(
      known: known,
      downloaded: downloaded,
      alternate: alternate,
      entries: entries,
    );
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      fixture.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassPalette.theme().copyWith(platform: TargetPlatform.macOS),
        home: SourceBrowser(
          model: fixture.model,
          source: _Fixture.source,
          initialPath: initialPath,
          initialName: initialPath,
          onPlay: (media) async => fixture.automatic.add(media),
          onPlaySource: (choice) async => fixture.selected.add(choice),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('video-options:clip.mkv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换版本与来源'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('media-source-selection')),
      findsOneWidget,
    );
  }

  testWidgets('source video menu forwards original and offline choices', (
    tester,
  ) async {
    final fixture = await setup(tester);
    for (final preference in [
      PlaybackSourcePreference.original,
      PlaybackSourcePreference.offline,
    ]) {
      await choose(tester);
      expect(find.text('WebDAV · 云盘'), findsWidgets);
      expect(find.text('本地 · 已下载'), findsWidgets);
      await tester.tap(
        find.byKey(ValueKey('media-source:known:${preference.name}')),
      );
      await tester.pumpAndSettle();
      expect(fixture.selected.last.media.id, 'known');
      expect(fixture.selected.last.preference, preference);
      expect(fixture.automatic, isEmpty);
      expect(fixture.store.local('location:known')['source'], 'dav');
      expect(fixture.store.local('location:known')['path'], 'clip.mkv');
    }
    expect(fixture.selected, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unimported single file hides switching without registering media',
    (tester) async {
      final fixture = await setup(tester, known: false);
      expect(fixture.model.sourceMedia('dav', 'clip.mkv'), isNull);
      await tester.tap(find.byKey(const ValueKey('video-options:clip.mkv')));
      await tester.pumpAndSettle();
      expect(find.text('切换版本与来源'), findsNothing);
      expect(fixture.model.sourceMedia('dav', 'clip.mkv'), isNull);
      expect(fixture.selected, isEmpty);
      expect(fixture.automatic, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completed downloads make the switching menu available', (
    tester,
  ) async {
    final fixture = await setup(tester, downloaded: false);
    await tester.tap(find.byKey(const ValueKey('video-options:clip.mkv')));
    await tester.pumpAndSettle();
    expect(find.text('切换版本与来源'), findsNothing);
    Navigator.of(tester.element(find.text('查看文件详情'))).pop();
    await tester.pumpAndSettle();
    fixture.downloads.put();
    await tester.pumpAndSettle();
    await choose(tester);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(fixture.selected, isEmpty);
    expect(fixture.automatic, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'same-source versions share the source picker with technical labels',
    (tester) async {
      final fixture = await setup(tester, downloaded: false, alternate: true);
      await choose(tester);
      expect(
        find.byKey(const ValueKey('media-source:known:original')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('media-source:variant:original')),
        findsOneWidget,
      );
      expect(find.textContaining('3840 × 2160'), findsWidgets);
      expect(find.textContaining('MP4'), findsWidgets);
      expect(find.textContaining('12 Mbps'), findsWidgets);
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('media-source:variant:original')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('media-source:known:original')),
              )
              .dy,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('media-source:variant:original')),
      );
      await tester.pumpAndSettle();
      expect(fixture.selected.single.media.id, 'variant');
      expect(
        fixture.selected.single.preference,
        PlaybackSourcePreference.original,
      );
      const MediaTechnicalInfo(
        container: 'mp4',
        width: 1280,
        height: 720,
        bitrate: 2000000,
      ).save(fixture.store, fixture.store.get('media', 'variant')!);
      fixture.model.changed();
      await tester.pumpAndSettle();
      await choose(tester);
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('media-source:known:original')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('media-source:variant:original')),
              )
              .dy,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening a recognized folder discovers all unimported versions before selection',
    (tester) async {
      const low = SourceEntry(
        name: 'Show S01E01 1080p.mkv',
        path: 'Show/Show S01E01 1080p.mkv',
        size: 100,
      );
      const high = SourceEntry(
        name: 'Show S01E01 2160p.mp4',
        path: 'Show/Show S01E01 2160p.mp4',
        size: 200,
      );
      final fixture = await setup(
        tester,
        known: false,
        downloaded: false,
        entries: [low, high],
        initialPath: 'Show',
      );
      final first = fixture.model.sourceMedia('dav', low.path);
      final second = fixture.model.sourceMedia('dav', high.path);
      expect(first, isNotNull);
      expect(second, isNotNull);
      await tester.tap(find.byKey(ValueKey('video-options:${low.path}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换版本与来源'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('media-source:${first!.id}:original')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('media-source:${second!.id}:original')),
        findsOneWidget,
      );
      expect(find.textContaining('1080p'), findsWidgets);
      expect(find.textContaining('2160p'), findsWidgets);
      expect(fixture.selected, isEmpty);
      expect(fixture.automatic, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background then resume without frames invalidates an open source choice',
    (tester) async {
      final fixture = await setup(tester);
      await choose(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // There is no frame between background entry and return to the foreground.
      await tester.tap(
        find.byKey(const ValueKey('media-source:known:offline')),
      );
      await tester.pumpAndSettle();
      expect(fixture.selected, isEmpty);
      expect(fixture.automatic, isEmpty);

      await choose(tester);
      await tester.tap(
        find.byKey(const ValueKey('media-source:known:original')),
      );
      await tester.pumpAndSettle();
      expect(
        fixture.selected.single.preference,
        PlaybackSourcePreference.original,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'playback file preparation registers remote and local files without downloads',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'playback-file-worker-',
      );
      final store = await AppStore.open('${directory.path}/app.sqlite');
      store.setLocal('settings', {
        'metadataStrategy': 'off',
        'autoDiscover': false,
      });
      store.setLocal('sources', [_Fixture.source]);
      final model = AppModel(store, directory, backgroundWork: false);
      try {
        const remote = SourceEntry(
          name: 'Show E16.mp4',
          path: 'folder/Show E16.mp4',
        );
        final first = await model.prepareSourceMediaForPlayback('dav', remote);
        final again = await model.prepareSourceMediaForPlayback('dav', remote);
        expect(again.id, first.id);
        expect(store.local('location:${first.id}')['path'], remote.path);
        final local = await model.prepareSourceMediaForPlayback(
          'local',
          SourceEntry(name: 'clip.mkv', path: '${directory.path}/clip.mkv'),
        );
        expect(local.data['localOnly'], isTrue);
        expect(store.local('location:${local.id}')['source'], 'local');
        expect(store.all('media'), hasLength(2));
        expect(model.downloads.initialized, isFalse);
        expect(model.downloads.entries, isEmpty);
      } finally {
        await model.downloads.close();
        model.dispose();
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

class _Fixture {
  static const source = {'id': 'dav', 'kind': 'webdav', 'label': '云盘'};
  final directory = Directory.systemTemp.createTempSync('source-file-choice-');
  final store = AppStore(':memory:');
  final downloads = _Downloads();
  final selected = <MediaPlaybackChoice>[];
  final automatic = <SyncRecord>[];
  final List<SourceEntry> entries;
  late final model = _Model(store, directory, downloads, entries);

  _Fixture({
    required bool known,
    bool downloaded = true,
    bool alternate = false,
    List<SourceEntry>? entries,
  }) : entries =
           entries ??
           const [SourceEntry(name: 'clip.mkv', path: 'clip.mkv', size: 100)] {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.setLocal('sources', [source]);
    if (known) {
      store.save('media', 'known', {
        'title': 'clip.mkv',
        'fileName': 'clip.mkv',
        'size': 100,
        'series': 'Show',
        'season': '1',
        'episode': '1',
      });
      store.setLocal('location:known', {
        'id': 'known',
        'source': 'dav',
        'path': 'clip.mkv',
        'size': 100,
      });
      store.setLocal('manualMetadata:known', true);
      if (downloaded) downloads.put();
      if (alternate) {
        store.save('media', 'variant', {
          'title': 'clip-2160p.mp4',
          'fileName': 'clip-2160p.mp4',
          'size': 200,
          'series': 'Show',
          'season': '1',
          'episode': '1',
        });
        store.setLocal('location:variant', {
          'id': 'variant',
          'source': 'dav',
          'path': 'clip-2160p.mp4',
          'size': 200,
        });
        store.setLocal('manualMetadata:variant', true);
        const MediaTechnicalInfo(
          container: 'mp4',
          width: 3840,
          height: 2160,
          bitrate: 12000000,
        ).save(store, store.get('media', 'variant')!);
        const MediaTechnicalInfo(
          container: 'matroska',
          width: 1920,
          height: 1080,
          bitrate: 6000000,
        ).save(store, store.get('media', 'known')!);
      }
    }
    downloads.addListener(model.changed);
  }

  void close() {
    downloads.removeListener(model.changed);
    model.dispose();
    downloads.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  }
}

class _Model extends AppModel {
  @override
  final OfflineDownloads downloads;
  final List<SourceEntry> entries;
  _Model(super.store, super.documents, this.downloads, this.entries)
    : super(backgroundWork: false);

  late final _reader = LibrarySnapshotReader(store);

  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) {
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
  Future<SourceAdapter> adapter(String id) async => _Source(entries);
}

class _Source extends SourceAdapter {
  final List<SourceEntry> entries;
  _Source(this.entries);
  @override
  Future<List<SourceEntry>> list(String path) async => entries;
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path, size: 100);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

class _Downloads extends ChangeNotifier implements OfflineDownloads {
  OfflineDownload? completed;
  @override
  int get completedRevision => completed == null ? 0 : 1;
  @override
  OfflineDownload? entryFor(String mediaId) =>
      completed?.mediaId == mediaId ? completed : null;

  @override
  Map<String, Map<String, dynamic>> get completedLocations {
    final entry = completed;
    return entry == null
        ? const {}
        : {
            entry.mediaId: {
              'id': entry.mediaId,
              'source': 'local',
              'path': entry.localPath,
              'size': entry.total,
              'offline': true,
              'remoteSource': entry.sourceId,
              'remotePath': entry.remotePath,
              'remoteRevision': entry.bindingRevision,
            },
          };
  }

  void put() {
    completed = const OfflineDownload(
      mediaId: 'known',
      sourceId: 'dav',
      remotePath: 'clip.mkv',
      localPath: '/offline/clip.mkv',
      name: 'clip.mkv',
      status: OfflineDownloadStatus.completed,
      received: 100,
      total: 100,
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
