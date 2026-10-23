import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _OfflineSource extends SourceAdapter {
  @override
  Future<List<SourceEntry>> list(String path) async =>
      throw const AppFailure('offline');
  @override
  Future<SourceEntry> stat(String path) async => throw UnimplementedError();
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

class _DelayedSource extends _OfflineSource {
  final started = Completer<void>();
  final listing = Completer<List<SourceEntry>>();
  int closes = 0;
  @override
  Future<List<SourceEntry>> list(String path) {
    started.complete();
    return listing.future;
  }

  @override
  Future<void> close() async => closes++;
}

class _CancelAfterResult extends CancelToken {
  int checks = 0;
  @override
  void check() {
    // AppModel admission, worker admission, then the completed worker result.
    if (++checks == 3) cancel();
    super.check();
  }
}

class _CachedCatalog extends LibraryCatalog {
  final DirectoryCollection? Function() cached;
  _CachedCatalog(super.store, this.cached) : super(strategy: () => 'off');
  @override
  DirectoryPreview? directoryPreview(
    String sourceId,
    String path, {
    int? modified,
    bool allowStale = false,
  }) {
    final collection = cached();
    return collection == null
        ? null
        : DirectoryPreview(
            collection: collection,
            context: '',
            fingerprint: '',
            updatedAt: 0,
            modified: 0,
          );
  }
}

class _Model extends AppModel {
  _Model(
    super.store,
    super.documents, {
    super.enableThumbnails,
    super.previewCapture,
  }) : super(backgroundWork: false);
  DirectoryCollection? cached;
  bool failCache = false;
  SourceAdapter? connection;
  late final _catalog = _CachedCatalog(store, () {
    if (failCache) throw StateError('invalid directory cache');
    return cached;
  });
  @override
  LibraryCatalog get catalog => _catalog;
  @override
  Future<SourceAdapter> adapter(String id) async =>
      connection ?? await super.adapter(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late _Model model;
  late List<SourceEntry> entries;
  late DirectoryCollection collection;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('directory-reconcile-');
    store = AppStore('${root.path}/library.db')
      ..setLocal('settings', {'metadataStrategy': 'off'});
    model = _Model(store, root);
    final folder = await Directory('${root.path}/Show').create();
    entries = [];
    for (var episode = 1; episode <= 3; episode++) {
      final file = File('${folder.path}/Show S01E0$episode.mkv');
      await file.writeAsBytes([episode]);
      entries.add(await LocalSource().stat(file.path));
    }
    collection = identifyDirectory(folder.path, entries)!.withMetadata(
      {
        'id': '7',
        'provider': 'bangumi',
        'name_cn': '识别后的作品',
        'total_episodes': 12,
      },
      {'1': '第一集', '2': '第二集', '3': '第三集'},
    );
  });
  tearDown(() async {
    model.dispose();
    store.dispose();
    await root.delete(recursive: true);
  });

  test(
    'cancelled callers still notify committed directory writes but not unchanged data',
    () async {
      for (final listing in [false, true]) {
        var notifications = 0;
        void changed() => notifications++;
        model.addListener(changed);
        Future<Object?> run(CancelToken cancel) => listing
            ? model.synchronizeDirectoryEntriesInBackground(
                'local',
                '${root.path}/Show',
                entries,
                cancel: cancel,
              )
            : model.synchronizeCollectionInBackground(
                'local',
                collection,
                cancel: cancel,
              );
        final before = await model.loadLibrarySnapshot();
        final token = _CancelAfterResult();
        await expectLater(run(token), throwsA(isA<Cancelled>()));
        expect(token.checks, 3);
        final snapshot = await model.loadLibrarySnapshot();
        expect(snapshot.media, hasLength(3));
        expect(notifications, listing ? 0 : 1);
        if (listing) expect(snapshot, same(before));

        notifications = 0;
        await expectLater(run(_CancelAfterResult()), throwsA(isA<Cancelled>()));
        expect(notifications, 0);
        expect(await model.loadLibrarySnapshot(), same(snapshot));
        model.removeListener(changed);
      }
    },
  );

  test(
    'a cancelled listing with its own commit still invalidates an already visible library',
    () async {
      final before = await model.loadLibrarySnapshot();
      var notifications = 0;
      model.addListener(() => notifications++);
      await expectLater(
        model.synchronizeDirectoryEntriesInBackground(
          'local',
          '${root.path}/Show',
          entries,
          cancel: _CancelAfterResult(),
        ),
        throwsA(isA<Cancelled>()),
      );
      final after = await model.loadLibrarySnapshot();
      expect(after, isNot(same(before)));
      expect(after.media, hasLength(3));
      expect(notifications, 1);
    },
  );

  test(
    'cancelling a hung source closes it without waiting for a listing response',
    () async {
      final id = model.addMedia('local', entries.first);
      final source = _DelayedSource();
      model.connection = source;
      final cancel = CancelToken();
      final work = model.loadSeriesEpisodes(
        store.get('media', id)!,
        cancel: cancel,
      );
      await source.started.future;
      cancel.cancel();
      await expectLater(
        work.timeout(const Duration(seconds: 2)),
        throwsA(isA<Cancelled>()),
      );
      expect(source.closes, 1);
      expect((await model.loadLibrarySnapshot()).media, hasLength(1));
      // Real sources often report a transport error after close; the detached
      // listing's failure must already have a handler and cannot update data.
      source.listing.completeError(const AppFailure('connection closed'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'fresh recognized folder imports every episode and replaces a warm library snapshot',
    () async {
      final empty = await model.loadLibrarySnapshot();
      expect(empty.media, isEmpty);
      var notifications = 0;
      model.addListener(() => notifications++);
      // The user-facing recognition action formerly omitted importMissing and
      // updated only played records. The default must complete recognized data.
      await model.synchronizeCollectionInBackground('local', collection);
      final loaded = await model.loadLibrarySnapshot();
      expect(loaded.media, hasLength(3));
      expect(loaded.series.values.single.map((e) => e.data['episode']), [
        '1',
        '2',
        '3',
      ]);
      expect(loaded.media.every((e) => e.data['bangumiId'] == '7'), isTrue);
      expect(store.records('progress'), isEmpty);
      expect(notifications, 1);
      await model.synchronizeCollectionInBackground('local', collection);
      expect(await model.loadLibrarySnapshot(), same(loaded));
      expect(notifications, 1);
    },
  );

  test(
    'a broken directory cache cannot prevent reading newly added source episodes',
    () async {
      final id = model.addMedia('local', entries.first);
      model.failCache = true;
      final loaded = await model.loadSeriesEpisodes(store.get('media', id)!);
      expect(loaded.map((item) => item.data['episode']), ['1', '2', '3']);
      expect(
        model.seriesRefreshDelay(loaded.first),
        const Duration(seconds: 30),
      );
    },
  );

  test(
    'automatic series retries back off and reset after the source recovers',
    () async {
      final id = model.addMedia('local', entries.first);
      final record = store.get('media', id)!;
      model.connection = _OfflineSource();
      for (final seconds in [60, 120, 240, 240]) {
        expect(await model.loadSeriesEpisodes(record), hasLength(1));
        expect(model.seriesRefreshDelay(record), Duration(seconds: seconds));
      }
      final delayed = _DelayedSource();
      model.connection = delayed;
      final cancel = CancelToken();
      final pending = model.loadSeriesEpisodes(record, cancel: cancel);
      await delayed.started.future;
      cancel.cancel();
      await expectLater(pending, throwsA(isA<Cancelled>()));
      expect(model.seriesRefreshDelay(record), const Duration(seconds: 240));
      delayed.listing.complete(entries);
      model.connection = null;
      expect(await model.loadSeriesEpisodes(record), hasLength(3));
      expect(model.seriesRefreshDelay(record), const Duration(seconds: 30));
    },
  );

  test(
    'single old-library seed recovers all cached episodes on disk while offline',
    () async {
      final id = model.addMedia('local', entries.first);
      final old = await model.loadLibrarySnapshot();
      expect(old.media, hasLength(1));
      model.cached = collection;
      model.connection = _OfflineSource();
      final recovered = await model.loadSeriesEpisodes(old.byId[id]!);
      expect(recovered.map((e) => e.data['episode']), ['1', '2', '3']);
      expect(recovered.map((e) => e.data['episodeTitle']), [
        '第一集',
        '第二集',
        '第三集',
      ]);
      expect(store.records('progress'), isEmpty);
    },
  );

  test(
    'offline parsed folder shortcuts recover unplayed episodes without catalogue metadata',
    () async {
      final id = model.addMedia('local', entries.first);
      model.cached = identifyDirectory('${root.path}/Show', entries);
      model.connection = _OfflineSource();
      final loaded = await model.loadSeriesEpisodes(store.get('media', id)!);
      expect(loaded.map((item) => item.data['episode']), ['1', '2', '3']);
      expect(loaded.every((item) => item.data['bangumiId'] == null), isTrue);
      expect(store.records('progress'), isEmpty);
    },
  );

  test(
    'real source directory completes a series despite trailers and other shows',
    () async {
      final id = model.addMedia('local', entries.first);
      for (final name in [
        'trailer.mkv',
        'Other S01E01.mkv',
        '.Show S01E04.mkv',
      ]) {
        await File('${root.path}/Show/$name').writeAsBytes([1]);
      }
      await model.synchronizeCollectionInBackground(
        'local',
        DirectoryCollection(
          title: collection.title,
          season: collection.season,
          videos: [entries.first],
          identities: collection.identities,
          subject: collection.subject,
        ),
      );
      final loaded = await model.loadSeriesEpisodes(store.get('media', id)!);
      expect(loaded.map((e) => e.data['episode']), ['1', '2', '3']);
      expect(loaded.every((e) => e.data['bangumiId'] == '7'), isTrue);
      expect((await model.loadLibrarySnapshot()).media, hasLength(3));
      expect(store.records('progress'), isEmpty);
    },
  );

  test(
    'series completion follows each existing source directory with its own anchor',
    () async {
      await File(entries[1].path).delete();
      await File(entries[2].path).delete();
      final other = await Directory('${root.path}/Another copy').create();
      final sibling = <SourceEntry>[];
      for (final episode in [2, 3]) {
        final file = await File(
          '${other.path}/Show S01E0$episode.mkv',
        ).writeAsBytes([episode]);
        sibling.add(await LocalSource().stat(file.path));
      }
      final first = model.addMedia('local', entries.first);
      model.addMedia('local', sibling.first);
      final loaded = await model.loadSeriesEpisodes(store.get('media', first)!);
      expect(loaded.map((item) => item.data['episode']), ['1', '2', '3']);
      expect(model.sourceMedia('local', sibling.last.path), isNotNull);
    },
  );

  test(
    'removing the selected record while its listing is pending cannot import siblings',
    () async {
      final id = model.addMedia('local', entries.first);
      final selected = store.get('media', id)!;
      final source = _DelayedSource();
      model.connection = source;
      final work = model.loadSeriesEpisodes(selected);
      await source.started.future;
      await model.removeMedia(selected);
      source.listing.complete(entries);
      expect(await work, isEmpty);
      expect((await model.loadLibrarySnapshot()).media, isEmpty);
    },
  );

  test(
    'directory cancellation before a delayed listing completes does not add episodes',
    () async {
      final id = model.addMedia('local', entries.first);
      final source = _DelayedSource();
      model.connection = source;
      final cancel = CancelToken();
      final work = model.loadSeriesEpisodes(
        store.get('media', id)!,
        cancel: cancel,
      );
      await source.started.future;
      cancel.cancel();
      source.listing.complete(entries);
      await expectLater(work, throwsA(isA<Cancelled>()));
      expect((await model.loadLibrarySnapshot()).media, hasLength(1));
    },
  );

  test(
    'recognition promotes existing browsing frames and technical metadata without recapture',
    () async {
      final entry = entries[1];
      final browsingId = model.ensureSourceMediaPreview('local', entry);
      final request = MediaPreviewRequest(
        browsingId,
        'local',
        entry.path,
        entry.size,
      );
      final frame = await File(
        '${root.path}/frame.jpg',
      ).writeAsBytes([1, 2, 3]);
      store.setLocal('preview:$browsingId', {
        'path': frame.path,
        'fingerprint': request.fingerprint,
        'contentFingerprint': request.contentFingerprint,
        'formatVersion': MediaPreview.formatVersion,
      });
      store.setLocal('mediaMetadata:$browsingId', {
        'fingerprint': request.contentFingerprint,
        'duration': 90.0,
        'width': 1920,
        'height': 1080,
      });
      await model.synchronizeCollectionInBackground('local', collection);
      final episode = model.sourceMedia('local', entry.path)!;
      expect(episode.id, isNot(browsingId));
      expect(model.thumbnailPath(episode.id), frame.path);
      expect(await model.needsMediaPreview(episode.id), isFalse);
      expect(model.mediaDuration(episode), 90);
      expect(model.mediaDimensions(episode), (width: 1920, height: 1080));
      expect(store.local('preview:$browsingId'), isNull);
      expect(store.local('mediaMetadata:$browsingId'), isNull);
    },
  );

  test(
    'unrecognized collections need explicit import while recognized update-only remains available',
    () async {
      await model.synchronizeCollectionInBackground(
        'local',
        collection.withMetadata(null, {}),
      );
      expect((await model.loadLibrarySnapshot()).media, isEmpty);
      await model.synchronizeCollectionInBackground(
        'local',
        collection,
        importMissing: false,
      );
      expect((await model.loadLibrarySnapshot()).media, isEmpty);
      final id = model.addMedia('local', entries.first);
      await model.synchronizeCollectionInBackground(
        'local',
        collection,
        importMissing: false,
      );
      expect(store.get('media', id)!.data['bangumiId'], '7');
      expect((await model.loadLibrarySnapshot()).media, hasLength(1));
      await model.synchronizeCollectionInBackground(
        'local',
        collection.withMetadata(null, {}),
      );
      expect((await model.loadLibrarySnapshot()).media, hasLength(3));
    },
  );

  test(
    'a newer library frame wins over a browsing frame during promotion',
    () async {
      final entry = entries.first;
      final browsingId = model.ensureSourceMediaPreview('local', entry);
      final id = model.addMedia('local', entry);
      final request = MediaPreviewRequest(id, 'local', entry.path, entry.size);
      for (final owner in [browsingId, id]) {
        store.setLocal('preview:$owner', {
          'path': '${root.path}/$owner.jpg',
          'fingerprint': request.fingerprint,
          'contentFingerprint': request.contentFingerprint,
          'formatVersion': MediaPreview.formatVersion,
        });
      }
      await model.synchronizeCollectionInBackground('local', collection);
      expect(model.thumbnailPath(id), '${root.path}/$id.jpg');
      expect(store.local('preview:$browsingId'), isNull);
    },
  );

  test(
    'a browsing capture finishing after recognition publishes to its new library ID',
    () async {
      model.dispose();
      final started = Completer<void>();
      final captured = Completer<MediaPreview>();
      model = _Model(
        store,
        root,
        enableThumbnails: true,
        previewCapture: (uri, cancel) {
          started.complete();
          return captured.future;
        },
      );
      final entry = entries.first;
      final browsingId = model.ensureSourceMediaPreview('local', entry);
      await started.future.timeout(const Duration(seconds: 5));
      await model.synchronizeCollectionInBackground('local', collection);
      final id = model.sourceMedia('local', entry.path)!.id;
      final ready = Completer<void>();
      model.addListener(() {
        if (!ready.isCompleted && model.thumbnailPath(id) != null) {
          ready.complete();
        }
      });
      captured.complete(
        MediaPreview(Uint8List.fromList([1, 2, 3]), 90, 1920, 1080),
      );
      await ready.future.timeout(const Duration(seconds: 5));
      expect(model.thumbnailPath(id), isNotNull);
      expect(await model.needsMediaPreview(id), isFalse);
      expect(store.local('preview:$browsingId'), isNull);
      expect(model.mediaDimensions(store.get('media', id)!), (
        width: 1920,
        height: 1080,
      ));
      await model.pausePreviews();
    },
  );

  test(
    'explicit import also retains its browsing frame but rejects changed content',
    () async {
      for (final changed in [false, true]) {
        final entry = entries[changed ? 1 : 0];
        final browsingId = model.ensureSourceMediaPreview('local', entry);
        final request = MediaPreviewRequest(
          browsingId,
          'local',
          entry.path,
          changed ? entry.size + 100 : entry.size,
        );
        store.setLocal('preview:$browsingId', {
          'path': '${root.path}/$browsingId.jpg',
          'fingerprint': request.fingerprint,
          'contentFingerprint': request.contentFingerprint,
          'formatVersion': MediaPreview.formatVersion,
        });
        final id = model.addMedia('local', entry);
        expect(
          model.thumbnailPath(id),
          changed ? isNull : '${root.path}/$browsingId.jpg',
        );
      }
    },
  );
}
