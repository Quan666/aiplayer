import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_snapshot.dart';
import 'package:aiplayer/data/media_technical_info.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/playback_source.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async => f.close());

  test(
    'worker ranks local first, then resolution and verified bitrate',
    () async {
      final remote = f.add(
        'remote',
        width: 3840,
        height: 2160,
        bitrate: 50000000,
      );
      f.add(
        'local-low',
        source: 'local',
        width: 1280,
        height: 720,
        bitrate: 30000000,
      );
      f.add(
        'local-high',
        source: 'local',
        width: 1920,
        height: 1080,
        bitrate: 8000000,
      );
      f.add(
        'local-best',
        source: 'local',
        width: 1920,
        height: 1080,
        bitrate: 15000000,
      );
      f.store.fullReads = 0;
      final snapshot = await f.model.loadLibrarySnapshot();
      final options = snapshot.playbackOptionsFor(remote);
      expect(options.map((o) => o.media.id), [
        'local-best',
        'local-high',
        'local-low',
        'remote',
      ]);
      expect(snapshot.episodesFor(remote).single.id, 'local-best');
      expect(snapshot.preparationIsolate, isNot(Isolate.current.hashCode));
      expect(f.store.fullReads, 0);
      expect(() => options.clear(), throwsUnsupportedError);
      expect(
        () => options.first.choice.expectedBinding!['source'] = 'changed',
        throwsUnsupportedError,
      );
      expect(options.first.technical.bitrate, 15000000);
    },
  );

  test(
    'download and original are distinct options, stale copies disappear',
    () async {
      final remote = f.add('remote', width: 1920, height: 1080);
      f.complete(remote);
      final options = (await f.model.loadLibrarySnapshot()).playbackOptionsFor(
        remote,
      );
      expect(options.map((o) => o.preference), [
        PlaybackSourcePreference.offline,
        PlaybackSourcePreference.original,
      ]);
      expect(options.first.sourceId, 'local');
      expect(options.last.sourceId, 'nas');
      f.store.setLocal('location:remote', {
        ...f.store.local('location:remote') as Map,
        'previewRevision': 'replaced',
      });
      expect(
        (await f.model.loadLibrarySnapshot())
            .playbackOptionsFor(remote)
            .single
            .preference,
        PlaybackSourcePreference.original,
      );
    },
  );

  test(
    'same physical binding is deduplicated despite multiple records',
    () async {
      final original = f.add('one', path: '/same.mkv');
      f.add('two', path: '/same.mkv');
      expect(
        (await f.model.loadLibrarySnapshot()).playbackOptionsFor(original),
        hasLength(1),
      );
    },
  );

  test(
    'filename resolution is labelled and ranked without inventing bitrate',
    () async {
      final plain = f.add('plain', name: 'Example.S01E01.mkv');
      f.add('hint', name: 'Example.S01E01.2160p.mp4');
      final options = (await f.model.loadLibrarySnapshot()).playbackOptionsFor(
        plain,
      );
      expect(options.first.media.id, 'hint');
      expect(options.first.technical.resolutionHint, '2160p');
      expect(options.first.technical.width, isNull);
      expect(options.first.technical.bitrate, isNull);
      expect(options.first.technical.label, contains('文件名标注'));
    },
  );

  test(
    'unknown quality preserves existing detailed representative, ignoring size/codec/container',
    () async {
      final old = f.add(
        'a',
        name: 'Example.S01E01.mkv',
        size: 99999999,
        codec: 'AV1',
      );
      final detailed = f.add(
        'z',
        name: 'Example.S01E01.mp4',
        size: 10,
        codec: 'H.264',
        detailed: true,
      );
      final options = (await f.model.loadLibrarySnapshot()).playbackOptionsFor(
        old,
      );
      expect(options.first.media.id, detailed.id);
      expect(
        options.every((option) => option.technical.bitrate == null),
        isTrue,
      );
    },
  );

  test(
    'technical edits, external commits, rollback and progress invalidate correctly',
    () async {
      final a = f.add('a', width: 1280, height: 720);
      final b = f.add('b', width: 1920, height: 1080);
      final first = await f.model.loadLibrarySnapshot();
      expect(first.playbackOptionsFor(a).first.media.id, b.id);
      const MediaTechnicalInfo(width: 3840, height: 2160).save(f.store, a);
      expect(
        (await f.model.loadLibrarySnapshot())
            .playbackOptionsFor(a)
            .first
            .media
            .id,
        a.id,
      );
      final external = AppStore.openExisting(f.store.path);
      try {
        const MediaTechnicalInfo(width: 7680, height: 4320).save(external, b);
        expect(
          (await f.model.loadLibrarySnapshot())
              .playbackOptionsFor(a)
              .first
              .media
              .id,
          b.id,
        );
        final saved = Map<String, dynamic>.from(external.local('technical:a'));
        external.db.execute('UPDATE local SET value=? WHERE key=?', [
          jsonEncode({...saved, 'width': 12000, 'height': 6000}),
          'technical:a',
        ]);
        expect(
          (await f.model.loadLibrarySnapshot())
              .playbackOptionsFor(a)
              .first
              .media
              .id,
          a.id,
        );
        expect(
          () => f.store.transaction(() {
            const MediaTechnicalInfo(
              width: 20000,
              height: 10000,
            ).save(f.store, b);
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        final rolledBack = await f.model.loadLibrarySnapshot();
        expect(rolledBack.playbackOptionsFor(a).first.media.id, a.id);
        f.store.save('progress', 'a:100', {
          'position': 5,
          'updatedAt': '2026-10-29',
        });
        expect(
          (await f.model.loadLibrarySnapshot())
              .playbackOptionsFor(a)
              .first
              .media
              .id,
          a.id,
        );
        external.removeLocal('technical:a');
        expect(
          (await f.model.loadLibrarySnapshot())
              .playbackOptionsFor(a)
              .first
              .media
              .id,
          b.id,
        );
      } finally {
        external.dispose();
      }
    },
  );

  test('changed file identity rejects stale technical quality', () async {
    final a = f.add('a', width: 7680, height: 4320);
    final b = f.add('b', width: 1920, height: 1080);
    f.store.setLocal('location:a', {
      ...f.store.local('location:a') as Map,
      'path': '/different.mkv',
    });
    final options = (await f.model.loadLibrarySnapshot()).playbackOptionsFor(a);
    expect(options.first.media.id, b.id);
    expect(options.last.technical.width, isNull);
  });

  test(
    'automatic skips missing imported files and invalid downloads',
    () async {
      final remote = f.add('remote', width: 3840, height: 2160);
      f.add('missing', source: 'local', width: 7680, height: 4320);
      final validPath = '${f.directory.path}/valid.mkv';
      await File(validPath).writeAsString('bytes');
      final valid = f.add(
        'valid',
        source: 'local',
        path: validPath,
        width: 1920,
        height: 1080,
      );
      expect(
        (await f.model.preferredPlaybackChoice(remote)).media.id,
        valid.id,
      );
      await File(validPath).delete();
      f.complete(remote);
      f.downloads.valid = false;
      final choice = await f.model.preferredPlaybackChoice(remote);
      expect(choice.media.id, remote.id);
      expect(choice.preference, PlaybackSourcePreference.original);
    },
  );

  test(
    'session selects actual best media while explicit original stays exact',
    () async {
      final remote = f.add('remote', width: 3840, height: 2160);
      final path = '${f.directory.path}/local.mkv';
      await File(path).writeAsString('bytes');
      final local = f.add(
        'local',
        source: 'local',
        path: path,
        width: 1920,
        height: 1080,
      );
      final automatic = _Session(f.model, remote);
      final explicit = _Session(
        f.model,
        remote,
        sourcePreference: PlaybackSourcePreference.original,
        expectedBinding: Map<String, dynamic>.from(
          f.store.local('location:remote'),
        ),
      );
      try {
        expect((await automatic.resolvePlaybackLocation())?['path'], path);
        expect(automatic.media.id, local.id);
        expect(automatic.sourcePreference, PlaybackSourcePreference.automatic);
        expect((await explicit.resolvePlaybackLocation())?['source'], 'nas');
        expect(explicit.media.id, remote.id);
        expect(
          await automatic.resolvePlaybackLocation(),
          same(await automatic.resolvePlaybackLocation()),
        );
      } finally {
        await automatic.close();
        await explicit.close();
      }
    },
  );

  test(
    'external transient file keeps its identity and close removes owned temporary file',
    () async {
      f.add('library', width: 3840, height: 2160);
      final path =
          '${f.directory.path}/media/12345678-1234-1234-1234-123456789abc/external.mkv';
      await File(path).parent.create(recursive: true);
      await File(path).writeAsString('temporary bytes');
      f.store.save('media', 'external', {
        'title': 'Example',
        'series': 'Example',
        'season': '1',
        'episode': '1',
        'transient': true,
        'transientFileOwned': true,
      });
      f.store.setLocal('location:external', {'source': 'local', 'path': path});
      final media = f.store.get('media', 'external')!;
      expect(
        (await f.model.preferredPlaybackChoice(media)).media.id,
        'external',
      );
      final session = _Session(f.model, media);
      expect((await session.resolvePlaybackLocation())?['path'], path);
      expect(session.media.id, 'external');
      await session.close();
      expect(f.store.get('media', 'external'), isNull);
      expect(await File(path).exists(), isFalse);
      expect(f.store.get('media', 'library'), isNotNull);
      expect(f.store.records('progress'), isEmpty);
    },
  );

  test(
    'an explicit source belongs to this request, a new episode uses automatic ordering',
    () async {
      final first = f.add('first');
      f.complete(first);
      final current = _Session(
        f.model,
        first,
        sourcePreference: PlaybackSourcePreference.offline,
      );
      final nextPath = '${f.directory.path}/next.mkv';
      await File(nextPath).writeAsString('next');
      final remote = f.add('second-remote', width: 3840, height: 2160);
      final local = f.add(
        'second-local',
        source: 'local',
        path: nextPath,
        width: 1920,
        height: 1080,
      );
      for (final media in [remote, local]) {
        f.store.save('media', media.id, {...media.data, 'episode': '2'});
      }
      final next = _Session(f.model, f.store.get('media', remote.id)!);
      try {
        expect((await current.resolvePlaybackLocation())?['offline'], isTrue);
        expect((await next.resolvePlaybackLocation())?['path'], nextPath);
        expect(next.media.id, local.id);
        expect(next.sourcePreference, PlaybackSourcePreference.automatic);
        expect(next.expectedBinding, isNull);
      } finally {
        await current.close();
        await next.close();
      }
    },
  );

  test(
    'removed source is excluded but its completed offline copy remains playable',
    () async {
      final high = f.add('high', source: 'dav', width: 3840, height: 2160);
      final low = f.add('low', width: 1920, height: 1080);
      expect((await f.model.preferredPlaybackChoice(low)).media.id, high.id);
      f.store.setLocal('sources', [
        {'id': 'nas', 'type': 'smb'},
      ]);
      final options = (await f.model.loadLibrarySnapshot()).playbackOptionsFor(
        low,
      );
      expect(options.single.media.id, low.id);
      expect((await f.model.preferredPlaybackChoice(high)).media.id, low.id);
      f.complete(high);
      final choice = await f.model.preferredPlaybackChoice(low);
      expect(choice.media.id, high.id);
      expect(choice.preference, PlaybackSourcePreference.offline);
      expect(
        (await f.model.loadLibrarySnapshot()).playbackOptionsFor(low),
        hasLength(2),
      );
    },
  );

  test(
    'external source config updates candidates and missing sources never auto-select',
    () async {
      final external = f.add('external-source', source: 'external-dav');
      expect(
        (await f.model.loadLibrarySnapshot()).playbackOptionsFor(external),
        isEmpty,
      );
      await expectLater(
        f.model.preferredPlaybackChoice(external),
        throwsA(isA<AppFailure>()),
      );
      f.store.setLocal('externalSource:external-dav', {
        'id': 'external-dav',
        'type': 'webdav',
      });
      expect(
        (await f.model.loadLibrarySnapshot())
            .playbackOptionsFor(external)
            .single
            .sourceId,
        'external-dav',
      );
      f.store.removeLocal('externalSource:external-dav');
      expect(
        (await f.model.loadLibrarySnapshot()).playbackOptionsFor(external),
        isEmpty,
      );
    },
  );

  test('new completed download updates candidate membership', () async {
    final remote = f.add('remote');
    final first = await f.model.loadLibrarySnapshot();
    expect(first.playbackOptionsFor(remote), hasLength(1));
    f.complete(remote);
    final second = await f.model.loadLibrarySnapshot();
    expect(second.playbackOptionsFor(remote), hasLength(2));
    expect(
      (await f.model.preferredPlaybackChoice(remote)).preference,
      PlaybackSourcePreference.offline,
    );
  });
}

class _Fixture {
  final Directory directory;
  final _Store store;
  final _Downloads downloads;
  final _Model model;
  _Fixture(this.directory, this.store, this.downloads, this.model);
  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'playback-options-',
    );
    final store = _Store('${directory.path}/app.db');
    store.setLocal('sources', [
      {'id': 'nas', 'type': 'smb'},
      {'id': 'dav', 'type': 'webdav'},
    ]);
    final downloads = _Downloads();
    return _Fixture(
      directory,
      store,
      downloads,
      _Model(store, directory, downloads),
    );
  }

  SyncRecord add(
    String id, {
    String source = 'nas',
    String? path,
    String? name,
    int? width,
    int? height,
    int? bitrate,
    int size = 100,
    String codec = '',
    bool detailed = false,
  }) {
    store.save('media', id, {
      'title': 'Example',
      'series': 'Example',
      'season': '1',
      'episode': '1',
      'fileName': name ?? 'Example.S01E01.$id.mkv',
      'size': size,
      if (detailed) 'episodeTitle': 'Pilot',
    });
    store.setLocal('location:$id', {
      'id': id,
      'source': source,
      'path': path ?? '/$id.mkv',
      'size': size,
    });
    final record = store.get('media', id)!;
    MediaTechnicalInfo(
      width: width,
      height: height,
      bitrate: bitrate,
      codec: codec,
    ).save(store, record);
    return record;
  }

  void complete(SyncRecord media) {
    final binding = store.local('location:${media.id}') as Map;
    downloads.items[media.id] = OfflineDownload(
      mediaId: media.id,
      sourceId: binding['source'],
      remotePath: binding['path'],
      localPath: '${directory.path}/${media.id}.offline.mkv',
      name: 'copy.mkv',
      status: OfflineDownloadStatus.completed,
      received: 100,
      total: 100,
    );
    downloads.revision++;
  }

  Future<void> close() async {
    model.dispose();
    downloads.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  }
}

class _Store extends AppStore {
  int fullReads = 0;
  _Store(super.path);
  @override
  List<SyncRecord> all(String kind) {
    fullReads++;
    return super.all(kind);
  }

  @override
  List<SyncRecord> records(String kind) {
    fullReads++;
    return super.records(kind);
  }

  @override
  Map<String, dynamic> localEntries(String prefix) {
    fullReads++;
    return super.localEntries(prefix);
  }
}

class _Model extends AppModel {
  final _Downloads manager;
  late final reader = LibrarySnapshotReader(store);
  _Model(super.store, super.documents, this.manager)
    : super(backgroundWork: false);
  @override
  OfflineDownloads get downloads => manager;
  @override
  Future<LibrarySnapshot> loadLibrarySnapshot({
    String query = '',
    CancelToken? cancel,
  }) => reader.read(
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
    offlineRevision: manager.completedRevision,
    offlineLocations: manager.completedLocations,
  );
  @override
  void dispose() {
    reader.dispose();
    super.dispose();
  }
}

class _Downloads extends ChangeNotifier implements OfflineDownloads {
  final items = <String, OfflineDownload>{};
  int revision = 0;
  bool valid = true;
  @override
  bool get initialized => true;
  @override
  int get completedRevision => revision;
  @override
  Map<String, Map<String, dynamic>> get completedLocations => {
    for (final e in items.values)
      e.mediaId: {
        'source': 'local',
        'path': e.localPath,
        'remoteSource': e.sourceId,
        'remotePath': e.remotePath,
        'remoteRevision': e.bindingRevision,
      },
  };
  @override
  OfflineDownload? entryFor(String id) => items[id];
  @override
  Future<String?> localPath(String id) async =>
      valid ? items[id]?.localPath : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends PlaybackSession {
  _Session(
    super.model,
    super.media, {
    super.sourcePreference,
    super.expectedBinding,
  });
  final _player = _Player();
  @override
  _Player get player => _player;
}

class _Player implements Player {
  @override
  final state = const PlayerState();
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
