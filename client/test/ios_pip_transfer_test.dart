import 'dart:async';
import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/window_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.aiplayer/window_mode');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> native(String method, Map<String, dynamic> values) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, values)),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  late Directory directory;
  late AppStore store;
  late AppModel model;
  late _Session session;
  late PlayerWindowMode mode;
  Map<String, dynamic>? request;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('aiplayer-ios-pip-');
    store = AppStore(':memory:');
    model = AppModel(store, directory);
    store.save('media', 'video', {'title': '视频.mp4', 'size': 100});
    session = _Session(model, store.get('media', 'video')!);
    request = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'supported') return true;
      if (call.method == 'enter') {
        request = Map<String, dynamic>.from(call.arguments as Map);
        return true;
      }
      if (call.method == 'exit' && request != null) {
        return {
          'requestId': request!['requestId'],
          'position': 55.0,
          'duration': 120.0,
          'playing': true,
          'rate': 1.25,
        };
      }
      return null;
    });
    mode = PlayerWindowMode(isIOS: true)..bindSession(session);
  });
  tearDown(() async {
    await mode.close();
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('switching episodes detaches the previous iOS window cleanup', () async {
    final next = _Session(model, store.get('media', 'video')!);
    expect(session.closeHooks, hasLength(1));
    mode.unbindSession(session);
    expect(session.closeHooks, isEmpty);
    mode.bindSession(next);
    expect(next.closeHooks, hasLength(1));
    // A late detach from the old decoder must not detach the active episode.
    mode.unbindSession(session);
    await mode.enter(aspectRatio: 16 / 9);
    expect(next.remotePlayback, true);
    expect(session.remotePlayback, false);
    await mode.close();
    expect(next.closeHooks, isEmpty);
  });

  test('rebinding a window automatically removes the old close hook', () async {
    final next = _Session(model, store.get('media', 'video')!);
    mode.bindSession(next);
    expect(session.closeHooks, isEmpty);
    expect(next.closeHooks, hasLength(1));
  });

  test(
    'iOS handoff pauses mpv, records native progress, ignores stale callbacks and restores pause state',
    () async {
      await mode.enter(aspectRatio: 16 / 9);
      expect(request?['position'], 17);
      expect(request?['playing'], true);
      expect(session.remotePlayback, true);
      expect(session.player.state.playing, false);
      await native('progress', {
        'requestId': request!['requestId'],
        'position': 37.0,
        'duration': 120.0,
        'playing': true,
      });
      expect(model.progressFor(session.media)?['position'], 37);
      await native('restored', {
        'requestId': -1,
        'position': 99.0,
        'duration': 120.0,
        'playing': true,
      });
      expect(mode.active, true);
      expect(model.progressFor(session.media)?['position'], 37);
      await native('restored', {
        'requestId': request!['requestId'],
        'position': 49.0,
        'duration': 120.0,
        'playing': false,
        'rate': 1.5,
      });
      expect(mode.active, false);
      expect(session.remotePlayback, false);
      expect(session.player.state.position, const Duration(seconds: 49));
      expect(session.player.state.playing, false);
      expect(session.player.state.rate, 1.5);
      expect(model.progressFor(session.media)?['position'], 49);
    },
  );

  test(
    'external playback returns from PiP without progress or watched history',
    () async {
      session = _Session(
        model,
        const SyncRecord(
          id: 'external-video',
          kind: 'media',
          data: {'title': '临时视频.mp4', 'transient': true, 'localOnly': true},
        ),
      );
      mode.bindSession(session);
      await mode.enter(aspectRatio: 16 / 9);
      await native('progress', {
        'requestId': request!['requestId'],
        'position': 119.0,
        'duration': 120.0,
        'playing': true,
      });
      expect(store.all('progress'), isEmpty);
      expect(store.all('watched'), isEmpty);
      await mode.exit();
      expect(session.player.state.position, const Duration(seconds: 55));
      expect(session.remotePlayback, isFalse);
      expect(store.all('progress'), isEmpty);
      expect(store.all('watched'), isEmpty);
    },
  );

  test(
    'unsupported iOS media returns an error and restores inline playback',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'supported') return true;
        if (call.method == 'enter') {
          throw PlatformException(code: 'pip_media', message: '系统播放器无法打开此视频。');
        }
        return null;
      });
      await expectLater(
        mode.enter(aspectRatio: 16 / 9),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('无法打开'),
          ),
        ),
      );
      expect(mode.active, false);
      expect(session.remotePlayback, false);
      expect(session.player.state.playing, true);
      expect(session.player.state.position, const Duration(seconds: 17));
    },
  );

  test(
    'closing an already closed session preserves PiP progress without touching its native player',
    () async {
      await mode.enter(aspectRatio: 16 / 9);
      session.closed = true;
      final calls = session.player.calls.length;
      await mode.close();
      expect(session.player.calls.length, calls);
      expect(model.progressFor(session.media)?['position'], 55);
      expect(session.remotePlayback, true);
    },
  );

  test(
    'leaving the player restores final position without restarting playback during disposal',
    () async {
      await mode.enter(aspectRatio: 16 / 9);
      await mode.close();
      expect(session.player.state.position, const Duration(seconds: 55));
      expect(session.player.state.playing, false);
      expect(session.remotePlayback, false);
      expect(model.progressFor(session.media)?['position'], 55);
    },
  );

  test(
    'an unconfirmed seek preserves native progress and rejects delayed snapshots during restoration',
    () async {
      await mode.enter(aspectRatio: 16 / 9);
      await native('progress', {
        'requestId': request!['requestId'],
        'position': 37.0,
        'duration': 120.0,
        'playing': true,
      });
      session.player.dropSeek = true;
      final exit = mode.exit();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await native('progress', {
        'requestId': request!['requestId'],
        'position': 38.0,
        'duration': 120.0,
        'playing': true,
      });
      await exit;
      expect(mode.active, false);
      expect(session.remotePlayback, true);
      expect(session.player.state.position, const Duration(seconds: 17));
      expect(session.player.state.playing, false);
      expect(model.progressFor(session.media)?['position'], 55);
      expect(session.notice, contains('重新打开'));
    },
  );
}

class _Session implements PlaybackSession {
  @override
  final AppModel model;
  @override
  final SyncRecord media;
  @override
  final _Player player = _Player();
  @override
  bool ready = true, closed = false, remotePlayback = false;
  @override
  String notice = '';
  @override
  String? playbackUri = 'file:///private/test/video.mp4';
  _Session(this.model, this.media);
  final closeHooks = <Future<void> Function()>{};
  @override
  Future<void> seek(Duration target) => player.seek(target);
  @override
  void addCloseHook(Future<void> Function() hook) => closeHooks.add(hook);
  @override
  void removeCloseHook(Future<void> Function() hook) => closeHooks.remove(hook);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  bool dropSeek = false;
  @override
  PlayerState state = const PlayerState(
    position: Duration(seconds: 17),
    duration: Duration(seconds: 120),
    playing: true,
  );
  final calls = <String>[];
  @override
  Future<void> pause() async {
    calls.add('pause');
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    if (!dropSeek) state = state.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('rate');
    state = state.copyWith(rate: rate);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
