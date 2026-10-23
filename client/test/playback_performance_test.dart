import 'dart:async';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test(
    'external playback never saves progress, watched state or a frame',
    () async {
      final model = _Model();
      final session = _Session(model, transient: true)..ready = true;
      addTearDown(model.dispose);
      session.player.state = const PlayerState(
        position: Duration(seconds: 590),
        duration: Duration(minutes: 10),
        videoParams: VideoParams(w: 1920, h: 1080),
      );
      await session.saveProgress();
      session.checkpoint();
      await session.close();
      expect(model.store.get('progress', 'v'), isNull);
      expect(model.store.get('watched', 'v'), isNull);
      expect(model.syncRequests, 0);
      expect(model.previewPositions, isEmpty);
      expect(session.player.screenshots, 0);
      expect(model.externalDisposals, ['v']);
    },
  );

  test(
    'unrelated model updates do not rebuild playback or reapply settings',
    () async {
      final model = _Model();
      final session = _Session(model)..ready = true;
      addTearDown(model.dispose);
      addTearDown(session.close);
      var notifications = 0;
      session.addListener(() => notifications++);
      await session.updateSettings({'volume': 60.0});
      expect(notifications, 1);
      session.player.commands.clear();

      for (var i = 0; i < 100; i++) {
        model.changed();
      }
      await session.updateSettings({'metadataProvider': 'tmdb'});
      expect(notifications, 1);
      expect(session.player.commands, isEmpty);

      await session.updateSettings({'volume': 80.0});
      expect(notifications, 2);
      expect(session.player.commands, ['volume:80.0']);
    },
  );

  test(
    'a burst of preference notifications applies the latest settings once',
    () async {
      final model = _Model();
      final session = _Session(model)..ready = true;
      addTearDown(model.dispose);
      addTearDown(session.close);
      await session.updateSettings({});
      session.player.commands.clear();
      var notifications = 0;
      session.addListener(() => notifications++);
      await Future.wait([
        for (var volume = 1; volume <= 50; volume++)
          session.updateSettings({'volume': volume.toDouble()}),
      ]);
      expect(session.player.commands, ['volume:50.0']);
      expect(notifications, 1);
    },
  );

  test(
    'overlapping diagnostics share native reads and finish before close',
    () async {
      final model = _Model();
      final session = _Session(model);
      addTearDown(model.dispose);
      final native = session.player.platform;
      native.hardwareRead = Completer<String>();
      final first = session.refreshDiagnostics();
      final second = session.refreshDiagnostics();
      expect(identical(first, second), isTrue);
      expect(native.reads, ['hwdec-current']);
      final closing = session.close();
      await Future<void>.delayed(Duration.zero);
      expect(session.player.disposed, isFalse);
      native.hardwareRead!.complete('auto-safe');
      await Future.wait([first, second, closing]);
      expect(native.reads, ['hwdec-current', 'video-codec']);
      expect(session.player.disposed, isTrue);
    },
  );

  test(
    'seeking changes the timeline without synchronous progress writes',
    () async {
      final model = _Model();
      final session = _Session(model)..ready = true;
      addTearDown(model.dispose);
      addTearDown(session.close);
      session.player.state = const PlayerState(duration: Duration(minutes: 10));
      for (var i = 1; i < 50; i++) {
        await session.seek(Duration(seconds: i));
      }
      expect(session.timelineRevision, 49);
      expect(model.store.get('progress', 'v'), isNull);
      expect(model.syncRequests, 0);
      await session.saveProgress();
      expect(model.store.get('progress', 'v')!.data['position'], 49);
      expect(model.syncRequests, 1);
    },
  );

  test(
    'slow progress writes preserve seek order and finish before close',
    () async {
      final store = _DelayedStore();
      final model = _Model(store: store);
      final session = _Session(model)..ready = true;
      addTearDown(model.dispose);
      session.player.state = const PlayerState(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 10),
      );
      final first = session.saveProgress();
      await session.seek(const Duration(seconds: 40));
      final second = session.saveProgress();
      await session.seek(const Duration(seconds: 580));
      final closing = session.close();
      await Future<void>.delayed(Duration.zero);

      expect(store.positions, [20]);
      expect(model.syncRequests, 0);
      expect(session.player.disposed, isFalse);
      expect(store.get('progress', 'v'), isNull);
      store.firstWrite.complete();
      await Future.wait([first, second, closing]);

      expect(store.positions.take(3), [20, 40, 580]);
      expect(model.syncedPositions, [20, 40, 580]);
      expect(store.get('progress', 'v')!.data['position'], 580);
      expect(store.get('progress', 'v')!.revision, 3);
      expect(store.get('watched', 'v')!.data['watched'], isTrue);
      expect(session.player.disposed, isTrue);
      expect(session.player.screenshots, 0);
    },
  );

  test(
    'failed progress persistence does not discard the next checkpoint',
    () async {
      final store = _DelayedStore()..failFirst = true;
      final model = _Model(store: store);
      final session = _Session(model)..ready = true;
      addTearDown(model.dispose);
      addTearDown(session.close);
      session.player.state = const PlayerState(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 10),
      );
      final failure = expectLater(session.saveProgress(), throwsStateError);
      await session.seek(const Duration(seconds: 40));
      final next = session.saveProgress();
      store.firstWrite.complete();
      await failure;
      await next;

      expect(store.positions, [20, 40]);
      expect(model.syncedPositions, [40]);
      expect(store.get('progress', 'v')!.data['position'], 40);
      expect(store.get('progress', 'v')!.revision, 1);
    },
  );

  test('pause and exit reuse one frame and do not await preview storage', () {
    fakeAsync((clock) {
      final model = _Model()..previewStorage = Completer<void>();
      final session = _Session(model)..ready = true;
      session.player.state = const PlayerState(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 10),
        videoParams: VideoParams(w: 1920, h: 1080),
      );
      session.player.frame = Completer<Uint8List?>();
      session.checkpoint();
      session.checkpoint();
      clock.elapse(const Duration(milliseconds: 250));
      expect(session.player.screenshots, 1);
      final closing = session.close();
      var closed = false;
      closing.then((_) => closed = true);
      clock.flushMicrotasks();
      expect(session.player.disposed, isFalse);
      session.player.frame!.complete(Uint8List.fromList([1, 2, 3]));
      clock.flushMicrotasks();
      expect(session.player.disposed, isTrue);
      expect(closed, isTrue);
      expect(session.player.screenshots, 1);
      expect(model.previewPositions, [20]);
      expect(model.previewStorage!.isCompleted, isFalse);
      expect(model.syncRequests, 1);
      expect(model.store.get('progress', 'v')!.revision, 1);
      model.previewStorage!.complete();
      clock.flushMicrotasks();
      model.dispose();
    });
  });

  test(
    'closing during a seek keeps the old frame without native polling',
    () async {
      final model = _Model();
      final session = _Session(model)..ready = true;
      addTearDown(model.dispose);
      session.player.state = const PlayerState(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 10),
        videoParams: VideoParams(w: 1920, h: 1080),
      );
      session.player.platform.seeking = true;
      await session.close();
      expect(session.player.platform.reads, ['seeking']);
      expect(session.player.screenshots, 0);
      expect(model.previewPositions, isEmpty);
      expect(model.store.get('progress', 'v')!.data['position'], 20);
      expect(session.player.disposed, isTrue);
    },
  );
}

class _Session extends PlaybackSession {
  _Session(AppModel model, {bool transient = false})
    : super(
        model,
        SyncRecord(
          id: 'v',
          kind: 'media',
          data: {if (transient) 'transient': true},
        ),
      );

  final _player = _Player();
  @override
  _Player get player => _player;
}

class _Model extends ChangeNotifier implements AppModel {
  _Model({AppStore? store}) : store = store ?? AppStore(':memory:');

  final _settings = <String, dynamic>{};
  @override
  final AppStore store;
  int syncRequests = 0;
  final syncedPositions = <num>[];
  final externalDisposals = <String>[];
  @override
  Future<void> disposeExternalMedia(String id) async =>
      externalDisposals.add(id);
  final previewPositions = <double>[];
  Completer<void>? previewStorage;
  @override
  String progressKey(SyncRecord media) => media.id;
  @override
  String watchedKey(SyncRecord media) => media.id;
  @override
  void requestProgressSync() {
    syncRequests++;
    syncedPositions.add(store.get('progress', 'v')!.data['position'] as num);
  }

  @override
  Future<void> savePlaybackPreview(
    String id,
    Uint8List bytes, {
    required double position,
  }) async {
    previewPositions.add(position);
    await previewStorage?.future;
  }

  @override
  void trackPlaybackPreviewWork(Future<void> work) {}

  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }

  @override
  String? activePlaybackMediaId;
  @override
  AppPreferences get preferences => AppPreferences(_settings);
  @override
  Future<void> updatePreferences(Map<String, dynamic> patch) async {
    _settings.addAll(patch);
    notifyListeners();
  }

  @override
  void changed() => notifyListeners();
  @override
  void ensureMediaPreview(String id) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedStore extends AppStore {
  _DelayedStore() : super(':memory:');

  final firstWrite = Completer<void>();
  final positions = <num>[];
  bool failFirst = false;

  @override
  Future<bool> savePlaybackProgress(
    String progressId,
    Map<String, dynamic> data, {
    String? watchedId,
  }) async {
    positions.add(data['position'] as num);
    if (positions.length == 1) {
      await firstWrite.future;
      if (failFirst) throw StateError('Disk unavailable');
    }
    return super.savePlaybackProgress(progressId, data, watchedId: watchedId);
  }
}

class _Player implements Player {
  @override
  late final _Native platform = _Native(
    () => state.position.inMilliseconds / 1000,
  );
  @override
  var state = const PlayerState();
  final commands = <String>[];
  bool disposed = false;
  int screenshots = 0;
  Completer<Uint8List?>? frame;
  @override
  Future<void> seek(Duration position) async {
    state = state.copyWith(position: position);
  }

  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) async {
    screenshots++;
    return await frame?.future ?? Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<void> setVolume(double volume) async => commands.add('volume:$volume');
  @override
  Future<void> setRate(double rate) async => commands.add('rate:$rate');
  @override
  Future<void> pause() async {}
  @override
  Future<void> dispose() async => disposed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Native implements PlatformPlayer {
  final double Function() position;
  _Native(this.position);
  final reads = <String>[];
  Completer<String>? hardwareRead;
  bool seeking = false;
  Future<void> setProperty(String name, String value) async {}
  Future<String> getProperty(String name) async {
    reads.add(name);
    if (name == 'hwdec-current') return hardwareRead?.future ?? 'auto-safe';
    if (name == 'seeking') return seeking ? 'yes' : 'no';
    if (name == 'time-pos') return '${position()}';
    return 'h264';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
