import 'dart:async';
import 'dart:math';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/music_controller.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'selecting during source startup cancels before opening the next decoder',
    () async {
      final fixture = _Fixture(gateSession: true);
      final opening = fixture.controller.start();
      await Future<void>.delayed(Duration.zero);
      final first = fixture.sessions.single;
      expect(first.ready, isFalse);
      fixture.gateSession = false;
      final replacement = fixture.controller.select(2);
      await Future.wait([opening, replacement]);
      expect(first.closed, isTrue);
      expect(fixture.sessions.length, 2);
      expect(fixture.sessions.last.media.id, '2.flac');
      expect(fixture.sessions.last.ready, isTrue);
      await fixture.close();
    },
  );

  test('queue keeps ordering, explicit skip and bounded shuffle history', () {
    final queue = MusicQueue(3, random: Random(7));
    expect(queue.previous(), isNull);
    queue.select(queue.next()!);
    expect(queue.index, 1);
    queue.select(2);
    expect(queue.next(), isNull);
    queue.mode = MusicPlayMode.repeatAll;
    expect(queue.next(), 0);
    queue.select(0);
    expect(queue.previous(), 2);
    queue.mode = MusicPlayMode.repeatOne;
    expect(queue.next(automatic: true), 0);
    expect(queue.next(), 1);
    queue.mode = MusicPlayMode.shuffle;
    final shuffled = queue.next()!;
    expect(shuffled, isNot(0));
    queue.select(shuffled);
    expect(queue.previous(), 0);
    expect(() => queue.select(3), throwsRangeError);
  });

  test(
    'rapid selection cancels preparation and only opens latest track',
    () async {
      final fixture = _Fixture();
      final model = fixture.model;
      final firstGate = model.gate = Completer<void>();
      final opening = fixture.controller.start();
      await model.started.future;
      final second = fixture.controller.select(1);
      final third = fixture.controller.select(2);
      firstGate.complete();
      await Future.wait([opening, second, third]);
      expect(model.requested, ['0.flac', '2.flac']);
      expect(fixture.sessions.map((session) => session.media.id), ['2.flac']);
      expect(fixture.sessions.single.playRequests, [true]);
      await fixture.close();
    },
  );

  test(
    'pause then resume during preparation never causes late autoplay',
    () async {
      final fixture = _Fixture();
      final gate = fixture.model.gate = Completer<void>();
      final opening = fixture.controller.start();
      await fixture.model.started.future;
      fixture.controller.setBackgrounded(true);
      fixture.controller.setBackgrounded(false);
      gate.complete();
      await opening;
      expect(fixture.sessions.single.playRequests, [false]);
      expect(fixture.sessions.single.playing, isFalse);
      await fixture.close();
    },
  );

  test('EOF never queues work while paused without pumping a frame', () async {
    final fixture = _Fixture();
    await fixture.controller.start();
    final session = fixture.sessions.single;
    fixture.controller.setBackgrounded(true);
    expect(session.blocked, isTrue);
    expect(session.playing, isFalse);
    session.complete();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.model.requested, ['0.flac']);
    fixture.controller.setBackgrounded(false);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.model.requested, ['0.flac']);
    expect(session.playing, isFalse);
    await fixture.close();
  });

  test(
    'pausing cancels automatic next preparation and allows manual retry',
    () async {
      final fixture = _Fixture();
      await fixture.controller.start();
      fixture.model.gate = Completer<void>();
      fixture.model.started = Completer<void>();
      fixture.sessions.single.complete();
      await fixture.model.started.future;
      fixture.controller.setBackgrounded(true);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.sessions.length, 1);
      expect(fixture.controller.loading, isFalse);
      fixture.controller.setBackgrounded(false);
      expect(fixture.sessions.length, 1);
      fixture.model.gate = null;
      await fixture.controller.togglePlayback();
      expect(fixture.sessions.length, 2);
      expect(fixture.sessions.last.media.id, '1.flac');
      await fixture.close();
    },
  );

  test('explicit background audio setting permits EOF progression', () async {
    final fixture = _Fixture(pauseOnBackground: false);
    await fixture.controller.start();
    fixture.controller.setBackgrounded(true);
    expect(fixture.sessions.single.blocked, isFalse);
    fixture.sessions.single.complete();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.sessions.length, 2);
    expect(fixture.sessions.last.playRequests, [true]);
    await fixture.close();
  });

  test(
    'close cancels preparation and late completion cannot open a decoder',
    () async {
      final fixture = _Fixture();
      fixture.model.gate = Completer<void>();
      final opening = fixture.controller.start();
      await fixture.model.started.future;
      await fixture.controller.close();
      await opening;
      fixture.model.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.sessions, isEmpty);
      expect(fixture.controller.closed, isTrue);
      await fixture.close();
    },
  );
}

class _Fixture {
  final _Model model;
  final sessions = <_Session>[];
  late final MusicPlaybackController controller;
  bool gateSession;
  _Fixture({bool pauseOnBackground = true, this.gateSession = false})
    : model = _Model(pauseOnBackground) {
    controller = MusicPlaybackController(
      model: model,
      sourceId: 'nas',
      entries: List.generate(
        3,
        (i) => SourceEntry(name: '$i.flac', path: '$i.flac'),
      ),
      mobileLifecycle: true,
      connectMediaControls: false,
      createSession: (model, record) {
        final session = _Session(record, gate: gateSession);
        sessions.add(session);
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
  _Model(this.pauseOnBackground);
  @override
  AppPreferences get preferences =>
      AppPreferences({'pauseOnBackground': pauseOnBackground});
  final requested = <String>[];
  Completer<void> started = Completer<void>();
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

class _Session extends ChangeNotifier implements PlaybackSession {
  @override
  final SyncRecord media;
  final bool gate;
  final _closedSignal = Completer<void>();
  _Session(this.media, {this.gate = false});
  bool blocked = false, playing = false;
  final playRequests = <bool>[];
  @override
  bool ready = false;
  @override
  bool closed = false;
  @override
  String error = '';
  @override
  String audioTitle = '';
  @override
  int completionRevision = 0;
  @override
  Future<void> open({bool? play, bool resume = true}) async {
    playRequests.add(play ?? true);
    if (gate) await _closedSignal.future;
    if (closed) return;
    playing = play ?? true;
    ready = true;
  }

  @override
  void setBackgroundPlaybackBlocked(
    bool value, {
    bool restoreOnForeground = false,
  }) {
    blocked = value;
    if (blocked) playing = false;
  }

  @override
  void checkpoint({bool capturePreview = true}) {}
  @override
  Future<void> close() async {
    closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete();
  }

  void complete() {
    playing = false;
    completionRevision++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
