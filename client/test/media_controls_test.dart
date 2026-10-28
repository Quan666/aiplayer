import 'dart:async';

import 'package:aiplayer/playback/media_controls.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.aiplayer/media_controls');
  const codec = StandardMethodCodec();
  final messenger = binding.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late _Session session;
  late PlayerMediaControls controls;
  Completer<void>? holdUpdate;

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  Map<dynamic, dynamic> snapshot() =>
      calls.lastWhere((call) => call.method == 'update').arguments as Map;
  Future<void> command(
    String action, {
    int? id,
    int? pauseRevision,
    Object? position,
  }) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall('command', {
          'sessionId': id ?? snapshot()['sessionId'],
          'pauseRevision': pauseRevision ?? session.backgroundPauseRevision,
          'action': action,
          'positionMs': ?position,
        }),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() async {
    calls.clear();
    holdUpdate = null;
    session = _Session();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'update') await holdUpdate?.future;
      return null;
    });
    controls = PlayerMediaControls(nativeSupported: true, keyboardEnabled: true)
      ..bindSession(session)
      ..configure(title: '第 2 集', seekStepSeconds: 15);
    await settle();
  });
  tearDown(() async {
    holdUpdate?.complete();
    await controls.close();
    session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('transport commands and state updates need no Flutter frames', () async {
    expect(snapshot()['active'], isTrue);
    expect(snapshot()['title'], '第 2 集');
    expect(snapshot()['seekStepSeconds'], 15);
    await command('play');
    expect(session.player.state.playing, isTrue);
    await command('pause');
    expect(session.player.state.playing, isFalse);
    await command('toggle');
    await command('stop');
    expect(session.intents, [true, false, true, false]);
    expect(session.checkpoints, 2);
    expect(snapshot()['playing'], false);
  });

  test('idle and position changes never poll or republish metadata', () async {
    final initial = calls.length;
    for (var index = 0; index < 100; index++) {
      session.player.state = session.player.state.copyWith(
        position: Duration(milliseconds: index),
      );
      session.position.value = session.player.state.position;
      session.refresh();
    }
    await settle();
    expect(calls.length, initial);
    session.player.state = session.player.state.copyWith(buffering: true);
    session.refresh();
    await settle();
    expect(calls.length, initial + 1);
    expect(snapshot()['positionMs'], 99);
  });

  test('late seek position corrects the system anchor only once', () async {
    session.timelineRevision++;
    session.refresh();
    await settle();
    final initial = calls.length;
    session.player.state = session.player.state.copyWith(
      position: const Duration(seconds: 70),
    );
    session.position.value = session.player.state.position;
    await settle();
    expect(snapshot()['positionMs'], 70000);
    expect(calls.length, initial + 1);
    session.position.value = const Duration(seconds: 71);
    await settle();
    expect(calls.length, initial + 1);
  });

  test(
    'media keys consume repeats and releases without double toggles',
    () async {
      await simulateKeyDownEvent(LogicalKeyboardKey.mediaPlayPause);
      await simulateKeyRepeatEvent(LogicalKeyboardKey.mediaPlayPause);
      await simulateKeyUpEvent(LogicalKeyboardKey.mediaPlayPause);
      await settle();
      expect(session.intents, [true]);
      await simulateKeyDownEvent(LogicalKeyboardKey.mediaPause);
      await simulateKeyUpEvent(LogicalKeyboardKey.mediaPause);
      expect(session.intents, [true, false]);
      await controls.close();
      await simulateKeyDownEvent(LogicalKeyboardKey.mediaPlay);
      await simulateKeyUpEvent(LogicalKeyboardKey.mediaPlay);
      expect(session.intents, [true, false]);
    },
  );

  test('seeks use configured step, clamp and reject malformed data', () async {
    await command('seekForward');
    await command('seekBackward');
    await command('seek', position: -500);
    await command('seek', position: 999999);
    await command('seek', position: '500');
    expect(session.seeks, [
      const Duration(seconds: 35),
      const Duration(seconds: 20),
      Duration.zero,
      const Duration(seconds: 100),
    ]);
    expect(snapshot()['positionMs'], 100000);
  });

  test(
    'slow seek keeps only latest pending target and drops it on pause',
    () async {
      session.holdSeek = Completer<void>();
      final first = command('seek', position: 1000);
      await settle();
      final pending = [
        for (var i = 2; i <= 100; i++) command('seek', position: i * 1000),
      ];
      await settle();
      expect(session.seeks, [const Duration(seconds: 1)]);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      session.backgroundPlaybackBlocked = true;
      session.backgroundPauseRevision++;
      session.holdSeek!.complete();
      await Future.wait([first, ...pending]);
      expect(session.seeks, [const Duration(seconds: 1)]);
      await command('play');
      expect(session.player.state.playing, false);
      // No pump after paused: delivery and cancellation are event driven.
    },
  );

  test('navigation is bounded and disabled in blocked background', () async {
    var next = 0, previous = 0;
    final hold = Completer<void>();
    controls.configure(
      title: '第 2 集',
      seekStepSeconds: 10,
      onNext: () async {
        next++;
        await hold.future;
      },
      onPrevious: () async {
        previous++;
      },
    );
    await settle();
    expect(snapshot()['canGoNext'], true);
    final first = command('next');
    await settle();
    await command('next');
    await command('previous');
    expect(next, 1);
    expect(previous, 0);
    hold.complete();
    await first;
    await command('previous');
    expect(previous, 1);
    session.backgroundPlaybackBlocked = true;
    await command('next');
    expect(next, 1);
  });

  test('rapid relative seeks accumulate from the in-flight target', () async {
    session.holdSeek = Completer<void>();
    final first = command('seekForward');
    await settle();
    final second = command('seekForward');
    final third = command('seekForward');
    await settle();
    session.holdSeek!.complete();
    await Future.wait([first, second, third]);
    expect(session.seeks, [
      const Duration(seconds: 35),
      const Duration(seconds: 65),
    ]);
  });

  test(
    'a previously copied close hook cannot release the new session',
    () async {
      final oldHook = session.hooks.single;
      final previous = session;
      session = _Session();
      controls.bindSession(session);
      await settle();
      final before = calls.length;
      await oldHook();
      expect(calls.length, before);
      await command('play');
      expect(session.intents, [true]);
      previous.dispose();
    },
  );

  test('rebind clears old system owner and rejects late commands', () async {
    final oldId = snapshot()['sessionId'] as int;
    final previous = session;
    session = _Session()..ready = false;
    controls.bindSession(session);
    await settle();
    expect(calls.where((call) => call.method == 'clear').last.arguments, {
      'sessionId': oldId,
    });
    expect(snapshot()['active'], false);
    await command('play', id: oldId);
    await command('play');
    expect(session.intents, isEmpty);
    session.ready = true;
    session.refresh();
    await settle();
    await command('play', id: oldId);
    expect(session.intents, isEmpty);
    await command('play');
    expect(session.intents, [true]);
    await previous.close();
    expect(snapshot()['active'], true);
    previous.dispose();
  });

  test(
    'native PiP and cast never send controls to the inline decoder',
    () async {
      session.remotePlayback = true;
      session.refresh();
      await settle();
      expect(snapshot()['active'], false);
      controls.setNativePictureInPicture(true);
      await settle();
      expect(snapshot()['active'], true);
      expect(snapshot()['nativePip'], true);
      await command('play');
      await command('seek', position: 4000);
      expect(session.intents, isEmpty);
      expect(session.seeks, isEmpty);
      controls.setNativePictureInPicture(false);
      session.remotePlayback = false;
      session.refresh();
      await command('play');
      expect(session.intents, [true]);
    },
  );

  test(
    'slow system updates coalesce and closing discards pending work',
    () async {
      holdUpdate = Completer<void>();
      session.player.state = session.player.state.copyWith(buffering: true);
      session.refresh();
      await settle();
      final initial = calls.length;
      for (var index = 0; index < 100; index++) {
        session.player.state = session.player.state.copyWith(rate: index + 1.0);
        session.refresh();
      }
      expect(calls.length, initial);
      await controls.close();
      holdUpdate!.complete();
      holdUpdate = null;
      await settle();
      expect(calls.length, initial + 1);
      expect(calls.last.method, 'clear');
    },
  );

  test('closing the playback session releases controls immediately', () async {
    await session.close();
    expect(calls.last.method, 'clear');
    await command('play');
    expect(session.intents, isEmpty);
  });

  test(
    'commands captured before a rapid background cycle stay obsolete',
    () async {
      final oldRevision = session.backgroundPauseRevision;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      session.backgroundPlaybackBlocked = true;
      session.backgroundPauseRevision++;
      controls.refresh();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      session.backgroundPlaybackBlocked = false;
      await command('play', pauseRevision: oldRevision);
      await command('toggle', pauseRevision: oldRevision);
      expect(session.intents, isEmpty);
      await command('play');
      expect(session.intents, [true]);
    },
  );

  test('native handoff waits for the coalesced PiP ownership update', () async {
    holdUpdate = Completer<void>();
    session.player.state = session.player.state.copyWith(buffering: true);
    session.refresh();
    await settle();
    controls.setNativePictureInPicture(true);
    var finished = false;
    final handoff = controls.settleNativeState().then((_) => finished = true);
    await settle();
    expect(finished, false);
    holdUpdate!.complete();
    holdUpdate = null;
    await handoff;
    expect(snapshot()['nativePip'], true);
  });
}

class _Session extends ChangeNotifier implements PlaybackSession {
  @override
  final _Player player = _Player();
  @override
  final position = ValueNotifier<Duration>(Duration.zero);
  @override
  bool ready = true, closed = false, remotePlayback = false;
  @override
  bool backgroundPlaybackBlocked = false;
  @override
  int backgroundPauseRevision = 0, timelineRevision = 0;
  @override
  String error = '';
  final intents = <bool>[];
  final seeks = <Duration>[];
  final hooks = <Future<void> Function()>{};
  int checkpoints = 0;
  Completer<void>? holdSeek;

  @override
  Future<void> setPlaying(bool playing) async {
    intents.add(playing);
    player.state = player.state.copyWith(
      playing: playing && !backgroundPlaybackBlocked,
    );
    notifyListeners();
  }

  @override
  Future<void> togglePlayback() => setPlaying(!player.state.playing);
  @override
  Future<void> seek(Duration target) async {
    seeks.add(target);
    await holdSeek?.future;
    player.state = player.state.copyWith(position: target);
    timelineRevision++;
    notifyListeners();
  }

  @override
  void checkpoint({bool capturePreview = true}) => checkpoints++;
  @override
  void addCloseHook(Future<void> Function() hook) => hooks.add(hook);
  @override
  void removeCloseHook(Future<void> Function() hook) => hooks.remove(hook);
  @override
  Future<void> close() async {
    closed = true;
    for (final hook in hooks.toList()) {
      await hook();
    }
  }

  void refresh() => notifyListeners();
  @override
  void dispose() {
    position.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState state = const PlayerState(
    position: Duration(seconds: 20),
    duration: Duration(seconds: 100),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
