import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/offline_downloads.dart';
import 'package:aiplayer/data/playback_source.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a playback choice freezes only the displayed binding identity',
    () async {
      final fixture = await _Fixture.create();
      try {
        final binding = <String, dynamic>{
          ...fixture.store.local('location:episode') as Map,
          'password': 'not-part-of-a-choice',
        };
        final choice = MediaPlaybackChoice(
          fixture.media,
          PlaybackSourcePreference.original,
          expectedBinding: binding,
        );
        binding['source'] = 'replacement';
        expect(choice.expectedBinding, {
          'source': 'dav',
          'path': '/share/video.mkv',
          'previewRevision': '',
        });
        expect(
          () => choice.expectedBinding!['source'] = 'replacement',
          throwsUnsupportedError,
        );
      } finally {
        await fixture.close();
      }
    },
  );

  for (final preference in [
    PlaybackSourcePreference.original,
    PlaybackSourcePreference.offline,
  ]) {
    for (final change in ['rebind', 'remove-location', 'source-revision']) {
      test('$preference rejects $change after displaying a choice', () async {
        final fixture = await _Fixture.create();
        try {
          final choice = MediaPlaybackChoice(
            fixture.media,
            preference,
            expectedBinding: Map<String, dynamic>.from(
              fixture.store.local('location:episode'),
            ),
          );
          if (change == 'remove-location') {
            fixture.store.removeLocal('location:episode');
          } else {
            fixture.store.setLocal('location:episode', {
              ...fixture.store.local('location:episode') as Map,
              if (change == 'rebind') 'source': 'nas',
              if (change == 'source-revision') 'previewRevision': 'changed',
            });
          }
          await expectLater(
            fixture.model.playbackLocation(
              choice.media,
              preference: choice.preference,
              expectedBinding: choice.expectedBinding,
            ),
            throwsA(isA<AppFailure>()),
          );
          expect(fixture.model.downloadReads, 0);
        } finally {
          await fixture.close();
        }
      });
    }
  }

  test('displayed binding is checked after download restoration', () async {
    final fixture = await _Fixture.create(onDisk: true);
    try {
      fixture.downloads.restored = false;
      fixture.downloads.initialization = Completer<void>();
      final resolving = fixture.model.playbackLocation(
        fixture.media,
        expectedBinding: Map<String, dynamic>.from(
          fixture.store.local('location:episode'),
        ),
      );
      final rejected = expectLater(resolving, throwsA(isA<AppFailure>()));
      expect(fixture.downloads.initializationCalls, 1);
      fixture.store.removeLocal('location:episode');
      fixture.downloads.initialization!.complete();
      await rejected;
      expect(fixture.downloads.validationCalls, 0);
    } finally {
      await fixture.close();
    }
  });

  test('displayed binding cannot fall back after local validation', () async {
    final fixture = await _Fixture.create();
    try {
      fixture.downloads.validation = Completer<String?>();
      final expected = Map<String, dynamic>.from(
        fixture.store.local('location:episode'),
      );
      final resolving = fixture.model.playbackLocation(
        fixture.media,
        expectedBinding: expected,
      );
      final rejected = expectLater(resolving, throwsA(isA<AppFailure>()));
      await fixture.downloads.validationStarted.future;
      fixture.store.setLocal('location:episode', {
        ...expected,
        'source': 'nas',
      });
      // Mutating a caller-owned map must not rewrite an in-flight request.
      expected['source'] = 'nas';
      fixture.downloads.validation!.complete('/offline/video.mkv');
      await rejected;
    } finally {
      await fixture.close();
    }
  });

  test('an unbound offline choice rejects a new binding', () async {
    final fixture = await _Fixture.create();
    try {
      fixture.store.removeLocal('location:episode');
      final selected = await fixture.model.playbackLocation(
        fixture.media,
        preference: PlaybackSourcePreference.offline,
        expectedBinding: const {},
      );
      expect(selected?['source'], 'local');
      fixture.store.setLocal('location:episode', {
        'id': 'episode',
        'source': 'dav',
        'path': '/share/video.mkv',
        'size': 100,
      });
      await expectLater(
        fixture.model.playbackLocation(
          fixture.media,
          preference: PlaybackSourcePreference.offline,
          expectedBinding: const {},
        ),
        throwsA(isA<AppFailure>()),
      );
    } finally {
      await fixture.close();
    }
  });

  test(
    'session carries the frozen binding through playback resolution',
    () async {
      final fixture = await _Fixture.create();
      final expected = Map<String, dynamic>.from(
        fixture.store.local('location:episode'),
      );
      final session = _Session(
        fixture.model,
        fixture.media,
        sourcePreference: PlaybackSourcePreference.original,
        expectedBinding: expected,
      );
      try {
        fixture.store.setLocal('location:episode', {
          ...expected,
          'source': 'nas',
        });
        expected['source'] = 'nas';
        await expectLater(
          session.resolvePlaybackLocation(),
          throwsA(isA<AppFailure>()),
        );
        expect(fixture.model.downloadReads, 0);
      } finally {
        await session.close();
        await fixture.close();
      }
    },
  );

  test(
    'original source bypasses even an unrestored download catalog',
    () async {
      final fixture = await _Fixture.create(onDisk: true);
      try {
        fixture.downloads.restored = false;
        fixture.downloads.initialization = Completer<void>();
        final location = await fixture.model
            .playbackLocation(
              fixture.media,
              preference: PlaybackSourcePreference.original,
            )
            .timeout(const Duration(seconds: 1));
        expect(location?['source'], 'dav');
        expect(location?['path'], '/share/video.mkv');
        expect(fixture.model.downloadReads, 0);
        expect(fixture.downloads.initializationCalls, 0);
        expect(fixture.downloads.validationCalls, 0);
      } finally {
        await fixture.close();
      }
    },
  );

  for (final preference in [
    PlaybackSourcePreference.automatic,
    PlaybackSourcePreference.offline,
  ]) {
    test(
      '$preference resolves local bytes without changing identity',
      () async {
        final fixture = await _Fixture.create();
        try {
          final progressKey = fixture.model.progressKey(fixture.media);
          final location = await fixture.model.playbackLocation(
            fixture.media,
            preference: preference,
          );
          expect(location?['id'], fixture.media.id);
          expect(location?['source'], 'local');
          expect(location?['path'], '/offline/video.mkv');
          expect(location?['offline'], isTrue);
          expect(fixture.store.local('location:episode')['source'], 'dav');
          expect(
            fixture.store.local('location:episode')['path'],
            '/share/video.mkv',
          );
          expect(fixture.model.progressKey(fixture.media), progressKey);
        } finally {
          await fixture.close();
        }
      },
    );
  }

  for (final unavailable in [
    'missing-task',
    'missing-file',
    'validation-error',
  ]) {
    test(
      'explicit offline fails instead of using remote for $unavailable',
      () async {
        final fixture = await _Fixture.create();
        try {
          if (unavailable == 'missing-task') {
            fixture.downloads.downloaded = null;
          }
          if (unavailable == 'missing-file') fixture.downloads.path = null;
          if (unavailable == 'validation-error') {
            fixture.downloads.failure = const AppFailure('本地文件检查失败。');
          }
          await expectLater(
            fixture.model.playbackLocation(
              fixture.media,
              preference: PlaybackSourcePreference.offline,
            ),
            throwsA(isA<AppFailure>()),
          );
          final original = await fixture.model.playbackLocation(
            fixture.media,
            preference: PlaybackSourcePreference.original,
          );
          expect(original?['source'], 'dav');
        } finally {
          await fixture.close();
        }
      },
    );
  }

  for (final change in ['rebind', 'source-revision', 'delete-download']) {
    test('explicit offline rejects $change during validation', () async {
      final fixture = await _Fixture.create();
      try {
        fixture.downloads.validation = Completer<String?>();
        final resolving = fixture.model.playbackLocation(
          fixture.media,
          preference: PlaybackSourcePreference.offline,
        );
        final rejected = expectLater(resolving, throwsA(isA<AppFailure>()));
        await fixture.downloads.validationStarted.future;
        if (change == 'delete-download') {
          fixture.downloads.downloaded = null;
        } else {
          fixture.store.setLocal('location:episode', {
            ...fixture.store.local('location:episode') as Map,
            if (change == 'rebind') 'path': '/replacement.mkv',
            if (change == 'source-revision') 'previewRevision': 'changed',
          });
        }
        fixture.downloads.validation!.complete('/offline/video.mkv');
        await rejected;
        expect(fixture.downloads.validationCalls, 1);
      } finally {
        await fixture.close();
      }
    });
  }

  test(
    'session pins its original source for playback, preview and cast',
    () async {
      final fixture = await _Fixture.create();
      final session = _Session(
        fixture.model,
        fixture.media,
        sourcePreference: PlaybackSourcePreference.original,
      );
      try {
        final first = session.resolvePlaybackLocation();
        final second = session.resolvePlaybackLocation();
        final location = await first;
        expect(await second, same(location));
        expect(location?['source'], 'dav');
        expect(fixture.model.requestedPreferences, [
          PlaybackSourcePreference.original,
        ]);
        expect(fixture.model.downloadReads, 0);
        expect(() => location!['path'] = '/other.mkv', throwsUnsupportedError);
        expect(await session.resolvePlaybackLocation(), same(location));
        expect(fixture.model.resolutions, 1);
      } finally {
        await session.close();
        await fixture.close();
      }
    },
  );

  test(
    'a download completing later cannot change the session source',
    () async {
      final fixture = await _Fixture.create();
      fixture.downloads.downloaded = null;
      final session = _Session(fixture.model, fixture.media);
      try {
        final location = await session.resolvePlaybackLocation();
        expect(location?['source'], 'dav');
        fixture.downloads.downloaded = _Downloads.completed;
        expect(await session.resolvePlaybackLocation(), same(location));
        expect(fixture.model.resolutions, 1);
        expect(fixture.downloads.validationCalls, 0);
        // A new playback attempt can choose the now-available local copy.
        final current = await fixture.model.playbackLocation(fixture.media);
        expect(current?['source'], 'local');
      } finally {
        await session.close();
        await fixture.close();
      }
    },
  );

  test(
    'closing cancels shared pending source resolution without a frame',
    () async {
      final fixture = await _Fixture.create();
      fixture.downloads.validation = Completer<String?>();
      final session = _Session(
        fixture.model,
        fixture.media,
        sourcePreference: PlaybackSourcePreference.offline,
      );
      try {
        final first = session.resolvePlaybackLocation();
        final second = session.resolvePlaybackLocation();
        final rejected = [
          expectLater(first, throwsA(isA<Cancelled>())),
          expectLater(second, throwsA(isA<Cancelled>())),
        ];
        await fixture.downloads.validationStarted.future;
        await session.close();
        await Future.wait(rejected).timeout(const Duration(seconds: 1));
        fixture.downloads.validation!.complete('/offline/video.mkv');
        await expectLater(
          session.resolvePlaybackLocation(),
          throwsA(isA<Cancelled>()),
        );
        expect(fixture.model.resolutions, 1);
        expect(fixture.downloads.validationCalls, 1);
        expect(session.player.opens, 0);
      } finally {
        await session.close();
        await fixture.close();
      }
    },
  );
}

class _Fixture {
  final Directory directory;
  final AppStore store;
  final _Downloads downloads;
  final _Model model;
  final SyncRecord media;
  _Fixture(this.directory, this.store, this.downloads, this.model, this.media);

  static Future<_Fixture> create({bool onDisk = false}) async {
    final directory = await Directory.systemTemp.createTemp(
      'source-preference-',
    );
    final store = onDisk
        ? await AppStore.open('${directory.path}/app.db')
        : AppStore(':memory:');
    store.setLocal('sources', [
      {'id': 'dav', 'type': 'webdav'},
    ]);
    store.save('media', 'episode', {'title': 'video.mkv', 'size': 100});
    store.setLocal('location:episode', {
      'id': 'episode',
      'source': 'dav',
      'path': '/share/video.mkv',
      'size': 100,
    });
    final downloads = _Downloads();
    final model = _Model(store, directory, downloads);
    return _Fixture(
      directory,
      store,
      downloads,
      model,
      store.get('media', 'episode')!,
    );
  }

  Future<void> close() async {
    model.dispose();
    downloads.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  }
}

class _Model extends AppModel {
  final _Downloads manager;
  int downloadReads = 0, resolutions = 0;
  final requestedPreferences = <PlaybackSourcePreference>[];
  _Model(super.store, super.documents, this.manager)
    : super(backgroundWork: false);

  @override
  OfflineDownloads get downloads {
    downloadReads++;
    return manager;
  }

  @override
  Future<Map<String, dynamic>?> playbackLocation(
    SyncRecord media, {
    PlaybackSourcePreference preference = PlaybackSourcePreference.automatic,
    Map<String, dynamic>? expectedBinding,
  }) {
    resolutions++;
    requestedPreferences.add(preference);
    return super.playbackLocation(
      media,
      preference: preference,
      expectedBinding: expectedBinding,
    );
  }
}

class _Downloads extends ChangeNotifier implements OfflineDownloads {
  static const completed = OfflineDownload(
    mediaId: 'episode',
    sourceId: 'dav',
    remotePath: '/share/video.mkv',
    localPath: '/offline/video.mkv',
    name: 'video.mkv',
    status: OfflineDownloadStatus.completed,
    received: 100,
    total: 100,
  );
  OfflineDownload? downloaded = completed;
  String? path = '/offline/video.mkv';
  AppFailure? failure;
  bool restored = true;
  Completer<void>? initialization;
  Completer<String?>? validation;
  final validationStarted = Completer<void>();
  int initializationCalls = 0, validationCalls = 0;

  @override
  bool get initialized => restored;

  @override
  Future<void> initialize() async {
    initializationCalls++;
    await initialization?.future;
    restored = true;
  }

  @override
  Future<String?> localPath(String mediaId) async {
    validationCalls++;
    if (!validationStarted.isCompleted) validationStarted.complete();
    if (failure != null) throw failure!;
    return validation == null ? path : validation!.future;
  }

  @override
  OfflineDownload? entryFor(String mediaId) => downloaded;

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
  final PlayerState state = const PlayerState();
  int opens = 0;
  @override
  Future<void> open(Playable playable, {bool play = true}) async => opens++;
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
