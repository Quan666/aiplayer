import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _origin = 'https://sync.example.com';
const _token = 'app-model-realtime-token-at-least-24-characters';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({'syncToken': _token}));

  testWidgets('unconfigured sync has no recurring maintenance wakeups', (
    tester,
  ) async {
    final f = _Fixture(
      backgroundWork: true,
      syncClock: tester.binding.clock.now,
    );
    addTearDown(() async {
      f.disposeModel();
      await tester.pump();
      f.store.dispose();
    });
    await tester.pump();
    final initial = (f.model as _Model).syncInvocations;
    await tester.pump(const Duration(hours: 1));
    expect((f.model as _Model).syncInvocations, initial);
    expect(f.client.requests, isEmpty);
  });

  testWidgets('failed long polls back off and only notify state transitions', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, backgroundWork: true);
    f.client.waitFailure = const AppFailure('offline');
    unawaited(f.model.synchronize(quiet: true));
    await tester.pump();
    f.client.requests.single.complete();
    await tester.pump();
    expect(f.client.waits, 1);
    var notifications = 0;
    f.model.addListener(() => notifications++);
    for (final seconds in [3, 6, 12]) {
      final count = f.client.waits;
      await tester.pump(Duration(seconds: seconds - 1));
      expect(f.client.waits, count);
      await tester.pump(const Duration(seconds: 1));
      expect(f.client.waits, count + 1);
    }
    expect(notifications, 0);
    f.client.waitFailure = null;
    await tester.pump(const Duration(seconds: 24));
    expect(f.model.realtimeConnected, true);
    expect(notifications, 1);
    await tester.pump(const Duration(seconds: 20));
    expect(notifications, 1);
    f.disposeModel();
    await tester.pump();
  });

  testWidgets(
    'idle maintenance waits five minutes and is suspended while hidden',
    (tester) async {
      final f = await _Fixture.create(tester, backgroundWork: true);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.client.requests.single.complete();
      await tester.pump();
      await tester.pump(const Duration(minutes: 4));
      expect(f.client.requests, hasLength(1));

      // Incremental updates must not postpone full profile maintenance forever.
      unawaited(f.model.synchronize(quiet: true, sharedOnly: true));
      await tester.pump();
      f.client.requests.last.complete();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      expect(f.client.requests, hasLength(3));
      expect(f.client.requests.last.sharedOnly, false);
      f.client.requests.last.complete();
      await tester.pump();

      f.model.setForeground(false);
      final polls = f.client.waits;
      await tester.pump(const Duration(hours: 1));
      expect(f.client.requests, hasLength(3));
      expect(f.client.waits, polls);
      f.model.setForeground(true);
      await tester.pump();
      expect(f.client.requests, hasLength(4));
      f.client.requests.last.complete();
      await tester.pump();
      f.disposeModel();
      await tester.pump();
    },
  );

  testWidgets('empty immediate long polls do not wake every second', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, backgroundWork: true);
    unawaited(f.model.synchronize(quiet: true));
    await tester.pump();
    f.client.requests.single.complete();
    await tester.pump();
    expect(f.client.waits, 1);
    var notifications = 0;
    f.model.addListener(() => notifications++);
    await tester.pump(const Duration(seconds: 19));
    expect(f.client.waits, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(f.client.waits, 2);
    expect(notifications, 0);
    f.model.setForeground(false);
    await tester.pump(const Duration(minutes: 1));
    expect(f.client.waits, 2);
  });

  testWidgets(
    'short empty long polls back off and stop without another background frame',
    (tester) async {
      final f = await _Fixture.create(tester, backgroundWork: true);
      final replies = <Completer<bool>>[];
      f.client.waitReply = () {
        final reply = Completer<bool>();
        replies.add(reply);
        return reply.future;
      };
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.client.requests.single.complete();
      await tester.pump();
      for (final seconds in [20, 40, 80]) {
        final polls = f.client.waits;
        await tester.pump(const Duration(seconds: 2));
        replies.last.complete(false);
        await tester.idle();
        await tester.pump(Duration(seconds: seconds - 3));
        expect(f.client.waits, polls);
        await tester.pump(const Duration(seconds: 1));
        expect(f.client.waits, polls + 1);
      }

      // A late reply cannot restart the watcher after the app stops drawing.
      f.model.setForeground(false);
      final polls = f.client.waits;
      replies.last.complete(false);
      await tester.idle();
      expect(f.client.waits, polls);
      expect(f.model.realtimeConnected, false);
      expect(tester.binding.hasScheduledFrame, false);
      f.model.setForeground(true);
      await tester.pump();
      f.client.requests.last.complete();
      await tester.pump();
      expect(f.client.waits, polls + 1);
      replies.last.complete(false);
      await tester.idle();
      await tester.pump(const Duration(seconds: 20));
      expect(
        f.client.waits,
        polls + 2,
        reason: 'resume starts a fresh watcher',
      );
      f.disposeModel();
      replies.last.complete(false);
      await tester.idle();
    },
  );

  testWidgets('healthy long polls immediately renew after empty responses', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, backgroundWork: true);
    final replies = <Completer<bool>>[];
    f.client.waitReply = () {
      final reply = Completer<bool>();
      replies.add(reply);
      return reply.future;
    };
    unawaited(f.model.synchronize(quiet: true));
    await tester.pump();
    f.client.requests.single.complete();
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 20));
      replies.last.complete(false);
      await tester.idle();
      expect(f.client.waits, i + 2);
    }
    f.disposeModel();
    replies.last.complete(false);
    await tester.idle();
  });

  testWidgets(
    'quiet unchanged sync does not rebuild the model for lastSync bookkeeping',
    (tester) async {
      final f = await _Fixture.create(tester);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.client.requests.single.complete();
      await tester.pump();
      var notifications = 0;
      f.model.addListener(() => notifications++);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.store.setLocal('lastSync', 'next-sync-time');
      f.client.requests.last.complete();
      await tester.pump();
      expect(notifications, 0);

      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.store.save('media', 'new-video', {'title': 'New video'});
      f.client.requests.last.complete();
      await tester.pump();
      expect(notifications, 1, reason: 'downloaded data must still refresh');
    },
  );

  testWidgets(
    'quiet sync refreshes imported presentation keys on writes and deletions',
    (tester) async {
      final f = await _Fixture.create(tester);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.client.requests.single.complete();
      await tester.pump();
      var notifications = 0;
      f.model.addListener(() => notifications++);
      const changes = <String, Object>{
        'sourceFavorites': [],
        'externalSource:video': {'kind': 'http'},
        'technical:video': {'width': 1920},
        'manualMetadata:video': true,
        'media-title-display:series': {'visible': true},
        'metadataEpisodeNames:series': {'1': 'Episode title'},
        'directory-preview:folder': {'collection': {}},
        'browse:video': {'title': 'Browsing video'},
        'syncDevice:id': 'changed-device',
      };
      for (final entry in changes.entries) {
        for (final deleted in [false, true]) {
          final before = notifications;
          unawaited(f.model.synchronize(quiet: true));
          await tester.pump();
          if (deleted) {
            f.store.removeLocal(entry.key);
          } else {
            f.store.setLocal(entry.key, entry.value);
          }
          f.client.requests.last.complete();
          await tester.pump();
          expect(
            notifications,
            before + 1,
            reason: '${entry.key}: ${deleted ? 'deletion' : 'write'}',
          );
        }
      }
    },
  );

  testWidgets(
    'offline retries back off to five minutes without quiet failure rebuilds',
    (tester) async {
      final f = await _Fixture.create(tester);
      f.progress(30);
      var notifications = 0;
      f.model.addListener(() => notifications++);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      for (final seconds in [3, 6, 12, 24, 48, 96, 180, 300, 300]) {
        final count = f.client.requests.length;
        f.client.requests.last.fail();
        await tester.pump();
        // Incidental full requests must respect the same offline deadline.
        unawaited(f.model.synchronize(quiet: true));
        await tester.pump(Duration(seconds: seconds - 1));
        expect(f.client.requests, hasLength(count));
        await tester.pump(const Duration(milliseconds: 1001));
        expect(f.client.requests, hasLength(count + 1));
        expect(f.client.requests.last.sharedOnly, false);
        expect(f.progressRecord.dirty, true);
      }
      expect(notifications, 0);
      f.client.requests.last.complete();
      await tester.pump();
      expect(f.progressRecord.dirty, false);
      expect(f.client.maxActive, 1);
    },
  );

  testWidgets(
    'manual sync bypasses backoff and successful recovery resets retry delay',
    (tester) async {
      final f = await _Fixture.create(tester);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.client.requests.last.fail();
      await tester.pump();
      unawaited(f.model.synchronize());
      await tester.pump();
      expect(f.client.requests, hasLength(2));
      f.client.requests.last.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(f.client.requests, hasLength(2));

      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.client.requests.last.fail();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3001));
      expect(f.client.requests, hasLength(4));
      f.client.requests.last.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'background suspends polling and retries, then resumes dirty work',
    (tester) async {
      final f = await _Fixture.create(tester, backgroundWork: true);
      f.progress(10);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      f.model.setForeground(false);
      expect(f.client.requests.single.cancel?.cancelled, true);
      await tester.pump();
      f.progress(20);
      f.model.requestProgressSync();
      await tester.pump(const Duration(minutes: 5));
      expect(f.client.requests, hasLength(1));
      expect(f.client.waits, 0);
      expect(f.progressRecord.dirty, true);
      f.model.setForeground(true);
      await tester.pump();
      expect(f.client.requests, hasLength(2));
      expect(f.client.requests.last.position, 20);
      f.client.requests.last.complete();
      await tester.pump();
      expect(f.progressRecord.dirty, false);
      expect(f.client.waits, 1);
      expect(f.client.maxActive, 1);
      f.disposeModel();
      await tester.pump();
    },
  );

  testWidgets(
    'progress sync uses a short debounce and skips the full profile',
    (tester) async {
      final f = await _Fixture.create(tester);
      f.progress(10);
      f.model.requestProgressSync();
      await tester.pump(const Duration(milliseconds: 149));
      expect(f.client.requests, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(f.client.requests, hasLength(1));
      expect(f.client.requests.single.sharedOnly, true);
      expect(f.client.requests.single.position, 10);
      expect(
        f.client.waits,
        0,
        reason: 'a secondary player must not start a library watcher',
      );
      f.client.requests.single.complete();
      await tester.pump();
      expect(f.progressRecord.dirty, false);
    },
  );

  testWidgets(
    'playback cancels full sync and suspends background polling until exit',
    (tester) async {
      final f = await _Fixture.create(tester, backgroundWork: true);
      f.progress(10);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      expect(f.client.requests.single.sharedOnly, false);

      f.model.activePlaybackMediaId = 'video';
      expect(f.client.requests.single.cancel?.cancelled, true);
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      expect(f.client.requests, hasLength(1));
      expect(f.client.waits, 0);

      f.model.requestProgressSync();
      await tester.pump(const Duration(milliseconds: 150));
      expect(f.client.requests, hasLength(2));
      expect(f.client.requests.last.sharedOnly, true);
      expect(f.client.requests.last.deferProfile, true);
      expect(f.client.requests.last.playbackOnly, true);
      f.client.requests.last.complete();
      await tester.pump();
      expect(f.client.waits, 0);

      f.model.activePlaybackMediaId = null;
      await tester.pump(const Duration(milliseconds: 999));
      expect(f.client.requests, hasLength(2));
      await tester.pump(const Duration(milliseconds: 1));
      expect(f.client.requests, hasLength(3));
      expect(f.client.requests.last.sharedOnly, false);
      expect(f.client.requests.last.deferProfile, false);
      expect(f.client.requests.last.playbackOnly, false);
      f.client.requests.last.complete();
      await tester.pump();
      expect(f.client.waits, 1);

      f.model.activePlaybackMediaId = 'video';
      await tester.pump(const Duration(seconds: 3));
      expect(f.client.waits, 1, reason: 'the library watcher stays suspended');
      f.disposeModel();
      await tester.pump();
    },
  );

  testWidgets(
    'opening playback cancels an idle incremental sync that may apply a profile',
    (tester) async {
      final f = await _Fixture.create(tester);
      unawaited(f.model.synchronize(quiet: true, sharedOnly: true));
      await tester.pump();
      final idle = f.client.requests.single;
      expect(idle.sharedOnly, true);
      expect(idle.deferProfile, false);
      f.model.activePlaybackMediaId = 'video';
      expect(idle.cancel?.cancelled, true);
      await tester.pump();

      f.model.requestProgressSync();
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        f.client.requests,
        hasLength(2),
        reason: 'deliberate cancellation needs no backoff',
      );
      final checkpoint = f.client.requests.last;
      expect(checkpoint.deferProfile, true);
      f.model.activePlaybackMediaId = 'next-video';
      expect(
        checkpoint.cancel?.cancelled,
        false,
        reason: 'lightweight progress can finish during playback',
      );
      checkpoint.complete();
      await tester.pump();
      expect(f.client.maxActive, 1);
    },
  );

  testWidgets(
    'quiet full requests during playback use only the lightweight path',
    (tester) async {
      final f = await _Fixture.create(tester);
      f.model.activePlaybackMediaId = 'video';
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      expect(f.client.requests.single.sharedOnly, true);
      f.client.requests.single.complete();
      await tester.pump();
      expect(f.client.waits, 0);
    },
  );

  testWidgets(
    'lazy screenshots coalesce without full sync or losing newer captures',
    (tester) async {
      final f = await _Fixture.create(tester);
      f.model.requestArtworkSync('first');
      f.model.requestArtworkSync('second');
      await tester.pump(const Duration(milliseconds: 150));
      expect(f.client.requests, hasLength(1));
      expect(f.client.requests.single.sharedOnly, true);
      expect(f.client.requests.single.artworkIds, {'first', 'second'});

      f.model.requestArtworkSync('first');
      await tester.pump(const Duration(milliseconds: 150));
      expect(f.client.requests, hasLength(1));
      f.client.requests.first.complete();
      await tester.pump();
      expect(f.client.requests, hasLength(2));
      expect(f.client.requests.last.sharedOnly, true);
      expect(f.client.requests.last.artworkIds, {'first'});
      f.client.requests.last.complete();
      await tester.pump();
      expect(f.client.maxActive, 1);
    },
  );

  testWidgets(
    'playback heartbeats defer artwork and do not notify hidden pages',
    (tester) async {
      final f = await _Fixture.create(tester, backgroundWork: true);
      f.model.activePlaybackMediaId = 'video';
      var notifications = 0;
      f.model.addListener(() => notifications++);
      f.progress(10);
      f.model.requestArtworkSync('video');
      await tester.pump(const Duration(milliseconds: 150));
      final playing = f.client.requests.single;
      expect(playing.playbackOnly, true);
      expect(playing.artworkIds, isEmpty);
      playing.complete();
      await tester.pump();
      expect(notifications, 0);

      f.progress(20);
      f.model.requestProgressSync();
      await tester.pump(const Duration(milliseconds: 150));
      f.client.requests.last.fail();
      await tester.pump();
      expect(notifications, 0, reason: 'a quiet failure is not a UI change');

      f.model.activePlaybackMediaId = null;
      await tester.pump(const Duration(seconds: 1));
      final idle = f.client.requests.last;
      expect(idle.playbackOnly, false);
      expect(idle.artworkIds, {'video'});
      idle.complete();
      await tester.pump();
      expect(notifications, greaterThan(0));
      f.disposeModel();
      await tester.pump();
    },
  );

  testWidgets(
    'shutdown waits for the lazy screenshot queue including its pending tail',
    (tester) async {
      final f = await _Fixture.create(tester);
      final first = Completer<void>();
      final last = Completer<void>();
      final queue = () async {
        await first.future;
        await last.future;
      }();
      f.model.trackPlaybackPreviewWork(queue);
      var flushed = false;
      final flushing = f.model.flushPlaybackPreviews().then((_) {
        flushed = true;
      });
      await tester.pump();
      expect(flushed, false);
      first.complete();
      await tester.pump();
      expect(
        flushed,
        false,
        reason: 'a queued final capture must be persisted',
      );
      last.complete();
      await tester.pump();
      await flushing;
      expect(flushed, true);
      expect(
        f.client.requests,
        isEmpty,
        reason: 'shutdown does not wait on sync',
      );
    },
  );

  testWidgets(
    'ticks during slow requests coalesce and eventually send the latest progress',
    (tester) async {
      final f = await _Fixture.create(tester);
      f.progress(1);
      unawaited(f.model.synchronize(quiet: true, sharedOnly: true));
      await tester.pump();
      for (var position = 2; position <= 50; position++) {
        f.progress(position.toDouble());
        f.model.requestProgressSync();
      }
      await tester.pump(const Duration(milliseconds: 150));
      expect(f.client.requests, hasLength(1));
      f.client.requests.first.complete();
      await tester.pump();
      expect(f.client.requests, hasLength(2));
      expect(f.client.requests.last.position, 50);
      expect(
        f.progressRecord.dirty,
        true,
        reason: 'acknowledging an older sample must retain a later edit',
      );
      for (var position = 51; position <= 100; position++) {
        f.progress(position.toDouble());
        f.model.requestProgressSync();
      }
      await tester.pump(const Duration(milliseconds: 150));
      f.client.requests.last.complete();
      await tester.pump();
      expect(
        f.client.requests,
        hasLength(2),
        reason: 'one drain runs at most two passes',
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(f.client.requests, hasLength(3));
      expect(f.client.requests.last.position, 100);
      f.client.requests.last.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(f.client.requests, hasLength(3));
      expect(f.client.maxActive, 1);
      expect(f.progressRecord.dirty, false);
    },
  );

  testWidgets(
    'disposing or replacing sync credentials cancels the old request',
    (tester) async {
      final disposed = await _Fixture.create(tester);
      disposed.progress(10);
      unawaited(disposed.model.synchronize(quiet: true, sharedOnly: true));
      await tester.pump();
      final abandoned = disposed.client.requests.single;
      disposed.disposeModel();
      expect(abandoned.cancel?.cancelled, true);
      await tester.pump();
      expect(disposed.progressRecord.dirty, true);

      final changed = await _Fixture.create(tester);
      changed.progress(20);
      unawaited(changed.model.synchronize(quiet: true, sharedOnly: true));
      await tester.pump();
      final old = changed.client.requests.single;
      const replacement = 'replacement-sync-token-at-least-24-characters';
      await changed.model.setSettings({
        'syncOrigin': 'https://replacement.example.com',
      }, syncToken: replacement);
      expect(old.cancel?.cancelled, true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final next = changed.client.requests.last;
      expect(changed.client.requests, hasLength(2));
      expect(next.address, 'https://replacement.example.com');
      expect(next.token, replacement);
      expect(next.sharedOnly, false);
      next.complete();
      old.complete();
      await tester.pump();
      expect(changed.model.status, '同步完成');
      expect(changed.progressRecord.dirty, false);
      expect(changed.client.maxActive, 1);
    },
  );

  testWidgets(
    'a failed full sync retains dirty data and retries full after backoff',
    (tester) async {
      final f = await _Fixture.create(tester);
      f.progress(30);
      unawaited(f.model.synchronize(quiet: true));
      await tester.pump();
      expect(f.client.requests.single.sharedOnly, false);
      f.client.requests.single.fail();
      await tester.pump();
      expect(f.progressRecord.dirty, true);
      f.model.requestProgressSync();
      await tester.pump(const Duration(milliseconds: 2900));
      expect(f.client.requests, hasLength(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(f.client.requests, hasLength(2));
      expect(
        f.client.requests.last.sharedOnly,
        false,
        reason: 'a playback tick must not downgrade a failed full sync',
      );
      f.client.requests.last.complete();
      await tester.pump();
      expect(f.progressRecord.dirty, false);
      expect(f.model.status, '同步完成');
    },
  );
}

class _Fixture {
  final store = AppStore(':memory:');
  late final _Client client = _Client(store);
  late final AppModel model;
  bool _disposed = false;
  _Fixture({bool backgroundWork = false, DateTime Function()? syncClock}) {
    model = _Model(
      store,
      client,
      backgroundWork: backgroundWork,
      syncClock: syncClock,
    );
  }
  static Future<_Fixture> create(
    WidgetTester tester, {
    bool backgroundWork = false,
  }) async {
    final fixture = _Fixture(
      backgroundWork: backgroundWork,
      syncClock: tester.binding.clock.now,
    );
    addTearDown(() async {
      fixture.disposeModel();
      await tester.pump();
      fixture.store.dispose();
    });
    await tester.pump(); // Settle startup work without a sync configuration.
    fixture.store.setLocal('settings', {'syncOrigin': _origin});
    return fixture;
  }

  void progress(double position) => store.save('progress', 'video:100', {
    'position': position,
    'duration': 1000,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });
  SyncRecord get progressRecord => store.get('progress', 'video:100')!;
  void disposeModel() {
    if (_disposed) return;
    _disposed = true;
    model.dispose();
  }
}

class _Model extends AppModel {
  final SyncClient _client;
  int syncInvocations = 0;
  _Model(
    AppStore store,
    this._client, {
    super.backgroundWork = false,
    super.syncClock,
  }) : super(store, Directory.systemTemp);
  @override
  SyncClient get sync => _client;
  @override
  Future<void> synchronize({bool quiet = false, bool sharedOnly = false}) {
    syncInvocations++;
    return super.synchronize(quiet: quiet, sharedOnly: sharedOnly);
  }
}

class _Request {
  final String address, token;
  final bool sharedOnly, deferProfile, playbackOnly;
  final Set<String> artworkIds;
  final CancelToken? cancel;
  final List<SyncRecord> records;
  final done = Completer<void>();
  _Request(
    this.address,
    this.token,
    this.sharedOnly,
    this.deferProfile,
    this.playbackOnly,
    this.artworkIds,
    this.cancel,
    this.records,
  );
  double? get position =>
      records.where((r) => r.kind == 'progress').firstOrNull?.data['position']
          as double?;
  void complete() {
    if (!done.isCompleted) done.complete();
  }

  void fail() => done.completeError(const AppFailure('offline'));
}

class _Client extends SyncClient {
  final requests = <_Request>[];
  AppFailure? waitFailure;
  Future<bool> Function()? waitReply;
  int active = 0, maxActive = 0, waits = 0;
  _Client(super.store);
  @override
  Future<void> synchronize(
    String address,
    String token, {
    CancelToken? cancel,
    bool sharedOnly = false,
    Set<String> artworkIds = const {},
    bool deferProfile = false,
    bool playbackOnly = false,
  }) async {
    final request = _Request(
      address,
      token,
      sharedOnly,
      deferProfile,
      playbackOnly,
      Set.of(artworkIds),
      cancel,
      store.pending,
    );
    requests.add(request);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await Future.any([
        request.done.future,
        if (cancel != null)
          cancel.whenCancelled.then<void>((_) => throw const Cancelled()),
      ]);
      cancel?.check();
      for (final record in request.records) {
        store.acknowledge(
          record,
          SyncRecord(
            id: record.id,
            kind: record.kind,
            data: record.data,
            version: record.version + 1,
          ),
        );
      }
    } finally {
      active--;
    }
  }

  @override
  Future<bool> waitForChanges(
    String address,
    String token, {
    CancelToken? cancel,
  }) async {
    waits++;
    if (waitFailure != null) throw waitFailure!;
    return await waitReply?.call() ?? false;
  }
}
