import 'dart:async';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/album_video_controller.dart';
import 'package:aiplayer/playback/media_controls.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test(
    'preselected mute opens silently and restores the previous local volume',
    () async {
      final fixture = _Fixture(volume: 37);
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggleMute();
      expect(fixture.controller.muted, isTrue);
      expect(fixture.model.requested, isEmpty);
      expect(fixture.sessions, isEmpty);
      await fixture.controller.toggle();
      final session = fixture.sessions.single;
      expect(session.playRequests, [false]);
      expect(session.audibleStarts, [0]);
      expect(session.player.volumes, [0]);
      expect(fixture.controller.playing, isTrue);
      await fixture.controller.toggleMute();
      expect(session.player.state.volume, 37);
      expect(fixture.controller.muted, isFalse);
      expect(fixture.model.preferences.volume, 37);
      expect(session.audibleStarts, [0]);
      await fixture.controller.toggleMute();
      final transferred = await fixture.controller.takeSession();
      expect(transferred, same(session));
      expect(transferred!.player.state.volume, 0);
      expect(transferred.player.state.playing, isFalse);
      await transferred.close();
      await fixture.close();
    },
  );

  test(
    'unmuting a silent initial preference uses an audible local level',
    () async {
      final fixture = _Fixture(volume: 0);
      fixture.controller.select(_entry('one.mp4'));
      expect(fixture.controller.muted, isTrue);
      await fixture.controller.toggleMute();
      expect(fixture.controller.muted, isFalse);
      expect(fixture.model.preferences.volume, 0);
      await fixture.controller.toggle();
      expect(fixture.sessions.single.audibleStarts, [100]);
      await fixture.close();
    },
  );

  test(
    'quick mute toggles coalesce and handoff waits for the latest level',
    () async {
      final fixture = _Fixture(volume: 53);
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      final session = fixture.sessions.single;
      final gate = session.player.volumeGate = Completer<void>();
      final changes = [fixture.controller.toggleMute()];
      for (var i = 0; i < 31; i++) {
        changes.add(fixture.controller.toggleMute());
      }
      expect(session.player.volumes, [0]);
      expect(fixture.controller.muted, isFalse);
      final handoff = fixture.controller.takeSession();
      expect(fixture.controller.session, same(session));
      gate.complete();
      await Future.wait(changes);
      final transferred = await handoff;
      expect(transferred, same(session));
      expect(session.player.volumes, [0, 53]);
      expect(session.player.maximumVolumeWrites, 1);
      expect(session.player.state.volume, 53);
      expect(session.player.state.playing, isFalse);
      await transferred!.close();
      await fixture.close();
    },
  );

  test('failed preselected mute never starts an audible video', () async {
    final fixture = _Fixture(volumeFailure: StateError('volume failed'));
    fixture.controller.select(_entry('one.mp4'));
    await fixture.controller.toggleMute();
    await fixture.controller.toggle();
    expect(fixture.sessions.single.playRequests, [false]);
    expect(fixture.sessions.single.audibleStarts, isEmpty);
    expect(fixture.sessions.single.closed, isTrue);
    expect(fixture.controller.playing, isFalse);
    expect(fixture.controller.error, isNotEmpty);
    await fixture.close();
  });

  test(
    'background during a preselected volume write never starts playback',
    () async {
      final gate = Completer<void>();
      final fixture = _Fixture(volumeGate: gate);
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggleMute();
      final opening = fixture.controller.toggle();
      await fixture.created.future;
      await Future<void>.delayed(Duration.zero);
      expect(fixture.sessions.single.player.volumes, [0]);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      gate.complete();
      await opening;
      expect(fixture.sessions.single.audibleStarts, isEmpty);
      expect(fixture.controller.session, isNull);
      expect(fixture.controller.playing, isFalse);
      await fixture.close();
    },
  );

  test('failed live mute reports the actual audible state', () async {
    final fixture = _Fixture();
    fixture.controller.select(_entry('one.mp4'));
    await fixture.controller.toggle();
    final session = fixture.sessions.single;
    session.player.volumeFailure = StateError('volume failed');
    await fixture.controller.toggleMute();
    expect(fixture.controller.error, isNotEmpty);
    expect(fixture.controller.muted, isFalse);
    session.player.volumeFailure = null;
    session.player.state = session.player.state.copyWith(volume: 0);
    session.changed();
    expect(fixture.controller.muted, isTrue);
    await fixture.close();
  });

  test('closing absorbs a rejected in-flight volume write', () async {
    final fixture = _Fixture();
    fixture.controller.select(_entry('one.mp4'));
    await fixture.controller.toggle();
    final player = fixture.sessions.single.player;
    final gate = player.volumeGate = Completer<void>();
    player.volumeFailure = StateError('decoder retired');
    final muting = fixture.controller.toggleMute();
    final closing = fixture.controller.close();
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([muting, closing]);
    expect(fixture.controller.closed, isTrue);
    expect(fixture.controller.session, isNull);
    await fixture.close();
  });

  test(
    'browsing never prepares or opens video, including a pause command',
    () async {
      final fixture = _Fixture();
      for (var i = 0; i < 12; i++) {
        fixture.controller.select(_entry('$i.mp4'));
      }
      await fixture.controller.setPlaying(false);
      expect(fixture.model.requested, isEmpty);
      expect(fixture.sessions, isEmpty);
      expect(fixture.controller.position.value, Duration.zero);
      await fixture.close();
    },
  );

  test(
    'swiping away closes playback and next file remains a still cover',
    () async {
      final fixture = _Fixture();
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      expect(fixture.controller.playing, isTrue);
      final first = fixture.sessions.single;
      fixture.controller.select(_entry('two.mp4'));
      expect(first.closed, isTrue);
      expect(fixture.controller.session, isNull);
      expect(fixture.controller.playing, isFalse);
      expect(fixture.model.requested, ['one.mp4']);
      await fixture.controller.toggle();
      expect(fixture.model.requested, ['one.mp4', 'two.mp4']);
      await fixture.close();
    },
  );

  test(
    'full-player handoff retains the exact paused decoder and position',
    () async {
      final fixture = _Fixture();
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      final session = fixture.sessions.single;
      session.player.state = session.player.state.copyWith(
        position: const Duration(seconds: 42),
      );
      session.position.value = const Duration(seconds: 42);
      final transferred = await fixture.controller.takeSession();
      expect(transferred, same(session));
      expect(session.closed, isFalse);
      expect(session.player.state.playing, isFalse);
      expect(session.player.state.position, const Duration(seconds: 42));
      expect(fixture.controller.session, isNull);
      expect(fixture.model.requested, ['one.mp4']);
      await fixture.close();
      expect(
        session.closed,
        isFalse,
        reason: 'Full player owns the transferred decoder',
      );
      await transferred!.close();
    },
  );

  test(
    'failed handoff releases system controls while decoder close is pending',
    () async {
      final fixture = _Fixture(connectMediaControls: true);
      addTearDown(fixture.close);
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      final session = fixture.sessions.single;
      final closeGate = session.closeGate = Completer<void>();
      addTearDown(() {
        if (!closeGate.isCompleted) closeGate.complete();
      });
      const codec = StandardMethodCodec();
      Future<Object?> controlsHandlerReply() {
        final reply = Completer<Object?>();
        binding.defaultBinaryMessenger.handlePlatformMessage(
          'app.aiplayer/media_controls',
          codec.encodeMethodCall(const MethodCall('ownershipProbe')),
          reply.complete,
        );
        return reply.future;
      }

      expect(PlayerMediaControls.remoteStatus.value.active, isTrue);
      expect(await controlsHandlerReply(), isNotNull);
      final failure = StateError('native pause failed');
      session.setPlayingFailure = failure;
      final handoff = fixture.controller.takeSession();
      final rejected = expectLater(handoff, throwsA(same(failure)));
      await Future<void>.delayed(Duration.zero);

      expect(session.closed, isTrue);
      expect(fixture.controller.session, isNull);
      expect(PlayerMediaControls.remoteStatus.value.active, isFalse);
      expect(
        await controlsHandlerReply(),
        isNull,
        reason: 'The detached session must not retain a platform handler',
      );
      closeGate.complete();
      await rejected;
    },
  );

  test(
    'background during source preparation cancels without another frame',
    () async {
      final fixture = _Fixture();
      fixture.model.gate = Completer<void>();
      fixture.controller.select(_entry('one.mp4'));
      final opening = fixture.controller.toggle();
      await fixture.model.started.future;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      fixture.model.gate!.complete();
      await opening;
      expect(fixture.sessions, isEmpty);
      expect(fixture.controller.loading, isFalse);
      fixture.model.gate = null;
      await fixture.controller.toggle();
      expect(fixture.sessions.single.playRequests, [true]);
      await fixture.close();
    },
  );

  test(
    'late native open is retired on background and never restarts on resume',
    () async {
      final fixture = _Fixture(gatedOpen: true);
      fixture.controller.select(_entry('one.mp4'));
      final opening = fixture.controller.toggle();
      await fixture.created.future;
      final session = fixture.sessions.single;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(session.closed, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await opening;
      expect(session.player.state.playing, isFalse);
      expect(fixture.controller.session, isNull);
      expect(fixture.sessions, hasLength(1));
      await fixture.close();
    },
  );

  test(
    'retirement wait includes another decoder closed while already waiting',
    () async {
      final first = _Fixture(), second = _Fixture();
      first.controller.select(_entry('one.mp4'));
      second.controller.select(_entry('two.mp4'));
      await first.controller.toggle();
      await second.controller.toggle();
      final firstGate = first.sessions.single.closeGate = Completer<void>();
      final secondGate = second.sessions.single.closeGate = Completer<void>();
      first.controller.select(null);
      var finished = false;
      final waiting = AlbumVideoController.waitForDisposals().then((_) {
        finished = true;
      });
      second.controller.select(null);
      firstGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      expect(first.sessions.single.player.state.playing, isFalse);
      expect(second.sessions.single.player.state.playing, isFalse);
      secondGate.complete();
      await waiting;
      expect(finished, isTrue);
      // Completed retirements leave no retained future in the global queue.
      await AlbumVideoController.waitForDisposals();
      await first.close();
      await second.close();
    },
  );

  test(
    'background cancels a tap waiting for another player to dispose',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final fixture = _Fixture(
        beforeOpen: () {
          entered.complete();
          return gate.future;
        },
      );
      fixture.controller.select(_entry('one.mp4'));
      final opening = fixture.controller.toggle();
      await entered.future;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      gate.complete();
      await opening;
      expect(fixture.model.requested, isEmpty);
      expect(fixture.sessions, isEmpty);
      await fixture.close();
    },
  );

  test(
    'inactive keeps playback, paused stops immediately and resume stays paused',
    () async {
      final fixture = _Fixture();
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      final session = fixture.sessions.single;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(fixture.controller.playing, isTrue);
      expect(session.presentation, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(session.blocked, isTrue);
      expect(fixture.controller.playing, isFalse);
      expect(session.checkpoints, 1);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(fixture.controller.playing, isFalse);
      expect(session.presentation, isTrue);
      expect(session.playRequests, [true]);
      await fixture.close();
    },
  );

  test(
    'explicit background playback keeps audio but stops presentation work',
    () async {
      final fixture = _Fixture(pauseOnBackground: false);
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(fixture.controller.playing, isTrue);
      expect(fixture.sessions.single.presentation, isFalse);
      fixture.sessions.single.position.value = const Duration(seconds: 14);
      expect(fixture.controller.position.value, Duration.zero);
      fixture.controller.setVisible(false);
      expect(fixture.controller.playing, isFalse);
      fixture.controller.setVisible(true);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(fixture.controller.playing, isFalse);
      expect(fixture.controller.position.value, const Duration(seconds: 14));
      await fixture.close();
    },
  );

  test(
    'information sheet pauses playback and dismissing it does not resume',
    () async {
      final fixture = _Fixture();
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      fixture.controller.setVisible(false);
      expect(fixture.controller.playing, isFalse);
      fixture.controller.setVisible(true);
      expect(fixture.controller.playing, isFalse);
      expect(fixture.sessions, hasLength(1));
      await fixture.close();
    },
  );

  test(
    'new viewer waits for previous native teardown before creating a decoder',
    () async {
      final previous = _Fixture();
      previous.controller.select(_entry('one.mp4'));
      await previous.controller.toggle();
      final gate = previous.sessions.single.closeGate = Completer<void>();
      final closing = previous.controller.close();
      final next = _Fixture();
      next.controller.select(_entry('two.mp4'));
      final opening = next.controller.toggle();
      await Future<void>.delayed(Duration.zero);
      expect(next.sessions, isEmpty);
      gate.complete();
      await Future.wait([closing, opening]);
      expect(next.sessions.single.media.id, 'two.mp4');
      await previous.close();
      await next.close();
    },
  );

  test(
    'timeline events do not rebuild the viewer and seeking clamps to file',
    () async {
      final fixture = _Fixture();
      fixture.controller.select(_entry('one.mp4'));
      await fixture.controller.toggle();
      var changes = 0;
      fixture.controller.addListener(() => changes++);
      fixture.sessions.single.position.value = const Duration(seconds: 3);
      fixture.sessions.single.position.value = const Duration(seconds: 4);
      expect(fixture.controller.position.value, const Duration(seconds: 4));
      expect(changes, 0);
      await fixture.controller.seek(const Duration(seconds: 500));
      expect(fixture.sessions.single.seeks, [const Duration(seconds: 90)]);
      await fixture.close();
    },
  );
}

SourceEntry _entry(String name) => SourceEntry(name: name, path: name);

class _Fixture {
  final _Model model;
  final bool gatedOpen;
  final sessions = <_Session>[];
  final created = Completer<void>();
  late final AlbumVideoController controller;

  _Fixture({
    bool pauseOnBackground = true,
    bool connectMediaControls = false,
    this.gatedOpen = false,
    Future<void> Function()? beforeOpen,
    double volume = 100,
    Completer<void>? volumeGate,
    Object? volumeFailure,
  }) : model = _Model(pauseOnBackground, volume) {
    controller = AlbumVideoController(
      model: model,
      sourceId: 'nas',
      beforeOpen: beforeOpen,
      connectMediaControls: connectMediaControls,
      createSession: (_, record) {
        final session = _Session(
          record,
          gatedOpen: gatedOpen,
          initialVolume: volume,
        );
        session.player.volumeGate = volumeGate;
        session.player.volumeFailure = volumeFailure;
        sessions.add(session);
        if (!created.isCompleted) created.complete();
        return session;
      },
    );
  }

  Future<void> close() async {
    await controller.close();
    controller.dispose();
    model.dispose();
  }
}

class _Model extends ChangeNotifier implements AppModel {
  final bool pauseOnBackground;
  final double volume;
  _Model(this.pauseOnBackground, this.volume);
  @override
  AppPreferences get preferences => AppPreferences({
    'pauseOnBackground': pauseOnBackground,
    'keepScreenOn': false,
    'volume': volume,
  });
  final requested = <String>[];
  final started = Completer<void>();
  Completer<void>? gate;

  @override
  Future<SyncRecord> preparePersonalMediaForPlayback(
    String sourceId,
    SourceEntry entry, {
    CancelToken? cancel,
  }) async {
    requested.add(entry.name);
    if (!started.isCompleted) started.complete();
    if (gate != null) await Future.any([gate!.future, cancel!.whenCancelled]);
    cancel?.check();
    return SyncRecord(
      kind: 'media',
      id: entry.name,
      data: {'personalMedia': true},
      deviceId: 'test',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState state = const PlayerState(duration: Duration(seconds: 90));
  final volumes = <double>[];
  Completer<void>? volumeGate;
  Object? volumeFailure;
  int volumeWrites = 0, maximumVolumeWrites = 0;
  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    volumeWrites++;
    if (volumeWrites > maximumVolumeWrites) maximumVolumeWrites = volumeWrites;
    try {
      await volumeGate?.future;
      if (volumeFailure case final failure?) throw failure;
      state = state.copyWith(volume: volume);
    } finally {
      volumeWrites--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends ChangeNotifier implements PlaybackSession {
  @override
  final SyncRecord media;
  final bool gatedOpen;
  final double initialVolume;
  final _closed = Completer<void>();
  Completer<void>? closeGate;
  Future<void>? _closing;
  _Session(this.media, {this.gatedOpen = false, this.initialVolume = 100});
  @override
  final _Player player = _Player();
  @override
  final position = ValueNotifier(Duration.zero);
  @override
  bool ready = false;
  @override
  bool closed = false;
  @override
  String error = '';
  @override
  bool firstFrameRendered = false;
  bool blocked = false, presentation = true;
  Object? setPlayingFailure;
  int checkpoints = 0;
  final playRequests = <bool>[];
  final audibleStarts = <double>[];
  final seeks = <Duration>[];
  final closeHooks = <Future<void> Function()>[];
  void changed() => notifyListeners();

  @override
  int get timelineRevision => 0;
  @override
  int get backgroundPauseRevision => 0;
  @override
  bool get remotePlayback => false;
  @override
  bool get backgroundPlaybackBlocked => blocked;
  @override
  void addCloseHook(Future<void> Function() hook) => closeHooks.add(hook);
  @override
  void removeCloseHook(Future<void> Function() hook) => closeHooks.remove(hook);

  @override
  Future<void> open({bool? play, bool resume = true}) async {
    playRequests.add(play ?? true);
    if (gatedOpen) await _closed.future;
    if (closed) return;
    ready = true;
    player.state = player.state.copyWith(
      playing: !blocked && play == true,
      volume: initialVolume,
    );
    if (player.state.playing) audibleStarts.add(player.state.volume);
    notifyListeners();
  }

  @override
  void setBackgroundPlaybackBlocked(
    bool value, {
    bool restoreOnForeground = false,
  }) {
    blocked = value;
    if (value) player.state = player.state.copyWith(playing: false);
  }

  @override
  void setDanmakuPresentationActive(bool value) => presentation = value;

  @override
  void checkpoint({bool capturePreview = true}) => checkpoints++;

  @override
  Future<void> setPlaying(bool value) async {
    if (setPlayingFailure case final failure?) throw failure;
    player.state = player.state.copyWith(playing: value && !blocked);
    if (player.state.playing) audibleStarts.add(player.state.volume);
    notifyListeners();
  }

  @override
  Future<void> seek(Duration value) async => seeks.add(value);

  @override
  Future<void> close() => _closing ??= () async {
    closed = true;
    player.state = player.state.copyWith(playing: false);
    if (!_closed.isCompleted) _closed.complete();
    for (final hook in List.of(closeHooks)) {
      await hook();
    }
    closeHooks.clear();
    await closeGate?.future;
    position.dispose();
  }();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
