import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/playback_source.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  test(
    'resolved offline playback opens local data without remote connection',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      final file = await File(
        '${model.documents.path}/offline/video.mkv',
      ).create(recursive: true);
      await file.writeAsBytes(List.filled(100, 1));
      model.store.setLocal('location:video', {
        'source': 'remote-smb',
        'path': 'share/video.mkv',
        'size': 999,
      });
      model.resolvedLocation = {
        'source': 'local',
        'path': file.path,
        'size': 100,
        'offline': true,
      };
      model.credentials.complete(null);
      model.source.complete(LocalSource());

      await session.open();

      expect(session.ready, isTrue);
      expect(model.openedSources, ['local']);
      expect(session.playbackUri, file.uri.toString());
      expect(model.store.local('location:video')['source'], 'remote-smb');
      expect(model.store.local('location:video')['size'], 999);
    },
  );

  test(
    'background pause during offline validation suppresses late autoplay',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      final resolution = model.locationGate =
          Completer<Map<String, dynamic>?>();
      model.credentials.complete(null);
      model.source.complete(_Source());
      final opening = session.open(play: true);
      session.setBackgroundPlaybackBlocked(true);
      session.setBackgroundPlaybackBlocked(false);
      resolution.complete({
        'source': 'local',
        'path': '/offline/video.mkv',
        'size': 100,
        'offline': true,
      });

      await opening;

      expect(session.ready, isTrue);
      expect(session.player.playRequests, [false]);
      expect(session.player.state.playing, isFalse);
    },
  );

  for (final pausePlayback in [true, false]) {
    test('invisible startup stops first-frame polling '
        '(pause playback: $pausePlayback)', () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      model.source.complete(_Source());
      await session.open();
      session.player.state = session.player.state.copyWith(
        videoParams: const VideoParams(w: 640, h: 360),
      );
      session.video.rect.value = const Rect.fromLTWH(0, 0, 640, 360);
      session.video.firstFrame.complete();
      await session.player.platform.frameReadStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(session.player.platform.frameReads, greaterThan(1));
      if (pausePlayback) {
        session.setBackgroundPlaybackBlocked(true);
      } else {
        session.setDanmakuPresentationActive(false);
      }
      final reads = session.player.platform.frameReads;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(session.player.platform.frameReads, reads);
      expect(session.firstFrameRendered, isFalse);
      expect(session.player.state.playing, !pausePlayback);

      session.player.platform.frame = '{"picture-type":"I"}';
      session.setBackgroundPlaybackBlocked(false);
      session.setDanmakuPresentationActive(true);
      await Future<void>.delayed(Duration.zero);
      expect(session.firstFrameRendered, isTrue);
      expect(session.player.state.playing, !pausePlayback);
    });
  }

  test(
    'a late first-frame result cannot restart hidden startup polling',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      model.source.complete(_Source());
      await session.open();
      final pending = session.player.platform.frameReadGate =
          Completer<String>();
      session.player.state = session.player.state.copyWith(
        videoParams: const VideoParams(w: 640, h: 360),
      );
      session.video.rect.value = const Rect.fromLTWH(0, 0, 640, 360);
      session.video.firstFrame.complete();
      await session.player.platform.frameReadStarted.future;
      session.setDanmakuPresentationActive(false);
      pending.complete('');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(session.player.platform.frameReads, 1);
      expect(session.firstFrameRendered, isFalse);
      session.player.platform.frameReadGate = null;
      session.player.platform.frame = '{"picture-type":"I"}';
      session.setDanmakuPresentationActive(true);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.platform.frameReads, 2);
      expect(session.firstFrameRendered, isTrue);
    },
  );

  for (final foregroundBeforeOpen in [false, true]) {
    test('backgrounding during source preparation suppresses autoplay '
        '(foreground before open: $foregroundBeforeOpen)', () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      final opening = session.open(play: true);
      session.setBackgroundPlaybackBlocked(true);
      if (foregroundBeforeOpen) {
        session.setBackgroundPlaybackBlocked(false);
      }
      model.source.complete(_Source());
      await opening.timeout(const Duration(seconds: 2));
      expect(session.ready, isTrue);
      expect(session.player.playRequests, [false]);
      expect(session.player.state.playing, isFalse);
      session.setBackgroundPlaybackBlocked(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
      expect(session.player.playRequests, [false]);
    });
  }

  for (final foregroundBeforeOpen in [false, true]) {
    test('a late native open cannot undo a background pause '
        '(foreground before completion: $foregroundBeforeOpen)', () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      final gate = session.player.openGate = Completer<void>();
      model.credentials.complete(null);
      model.source.complete(_Source());
      final opening = session.open(play: true);
      await session.player.openStarted.future;
      expect(session.player.playRequests, [true]);
      session.setBackgroundPlaybackBlocked(true);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.pauses, 1);
      if (foregroundBeforeOpen) {
        session.setBackgroundPlaybackBlocked(false);
      }
      gate.complete();
      await opening.timeout(const Duration(seconds: 2));
      expect(session.player.state.playing, isFalse);
      expect(session.player.pauses, greaterThanOrEqualTo(2));
      session.setBackgroundPlaybackBlocked(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
    });
  }

  test(
    'background gate also rejects a late playing event after startup',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      model.source.complete(_Source());
      await session.open();
      session.setBackgroundPlaybackBlocked(true);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
      session.player.emitPlaying(true);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
      session.setBackgroundPlaybackBlocked(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
    },
  );

  for (final wasPlaying in [true, false]) {
    test(
      'foreground restores original playing=$wasPlaying without frames',
      () async {
        final model = _Model();
        final session = _Session(model);
        _cleanup(model, session);
        model.credentials.complete(null);
        model.source.complete(_Source());
        await session.open(play: wasPlaying);
        session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
        await Future<void>.delayed(Duration.zero);
        expect(session.player.state.playing, isFalse);
        session.setBackgroundPlaybackBlocked(false);
        await Future<void>.delayed(Duration.zero);
        expect(session.player.state.playing, wasPlaying);
        expect(session.player.plays, wasPlaying ? 1 : 0);
      },
    );
  }

  for (final duringNativeOpen in [true, false]) {
    test(
      'mobile restore waits for startup (native=$duringNativeOpen)',
      () async {
        final model = _Model();
        final session = _Session(model);
        _cleanup(model, session);
        model.credentials.complete(null);
        final gate = duringNativeOpen
            ? session.player.openGate = Completer<void>()
            : null;
        if (duringNativeOpen) model.source.complete(_Source());
        final opening = session.open(play: true);
        if (duringNativeOpen) await session.player.openStarted.future;
        session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
        session.setBackgroundPlaybackBlocked(false);
        if (duringNativeOpen) {
          gate!.complete();
        } else {
          model.source.complete(_Source());
        }
        await opening;
        await Future<void>.delayed(Duration.zero);
        expect(session.player.state.playing, isTrue);
        expect(session.player.plays, 1);
      },
    );
  }

  test('slow pause and repeated background cycles restore once', () async {
    final model = _Model();
    final session = _Session(model);
    _cleanup(model, session);
    model.credentials.complete(null);
    model.source.complete(_Source());
    await session.open();
    final pause = session.player.pauseGate = Completer<void>();
    session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
    session.setBackgroundPlaybackBlocked(false);
    session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
    session.setBackgroundPlaybackBlocked(false);
    await Future<void>.delayed(Duration.zero);
    expect(session.player.plays, 0);
    final settled = session.settleBackgroundPlayback();
    pause.complete();
    await settled;
    expect(session.player.state.playing, isTrue);
    expect(session.player.plays, 1);
  });

  test(
    'returning to background while native resume waits reasserts pause',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      model.source.complete(_Source());
      await session.open();
      session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
      await Future<void>.delayed(Duration.zero);
      final play = session.player.playGate = Completer<void>();
      session.setBackgroundPlaybackBlocked(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.plays, 1);
      session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
      play.complete();
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
      session.setBackgroundPlaybackBlocked(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isTrue);
      expect(session.player.plays, 2);
    },
  );

  test('manual pause cancels an in-flight foreground restore', () async {
    final model = _Model();
    final session = _Session(model);
    _cleanup(model, session);
    model.credentials.complete(null);
    model.source.complete(_Source());
    await session.open();
    session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
    await Future<void>.delayed(Duration.zero);
    final play = session.player.playGate = Completer<void>();
    session.setBackgroundPlaybackBlocked(false);
    await Future<void>.delayed(Duration.zero);
    final pausing = session.togglePlayback();
    play.complete();
    await pausing;
    expect(session.player.state.playing, isFalse);
    session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
    session.setBackgroundPlaybackBlocked(false);
    await Future<void>.delayed(Duration.zero);
    expect(session.player.state.playing, isFalse);
  });

  for (final requestedInBackground in [false, true]) {
    test(
      'queued play cannot cross a background cycle (hidden=$requestedInBackground)',
      () async {
        final model = _Model();
        final session = _Session(model);
        _cleanup(model, session);
        model.credentials.complete(null);
        model.source.complete(_Source());
        await session.open();
        await session.setPlaying(false);
        final pause = session.player.pauseGate = Completer<void>();
        session.setBackgroundPlaybackBlocked(true);
        if (!requestedInBackground) session.setBackgroundPlaybackBlocked(false);
        final playing = session.setPlaying(true);
        await Future<void>.delayed(Duration.zero);
        if (!requestedInBackground) session.setBackgroundPlaybackBlocked(true);
        session.setBackgroundPlaybackBlocked(false);
        pause.complete();
        await playing;
        expect(session.player.plays, 0);
        expect(session.player.state.playing, false);
      },
    );
  }

  test(
    'explicit pause pending on native player survives background restore',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      model.source.complete(_Source());
      await session.open();
      final gate = session.player.pauseGate = Completer<void>();
      final pausing = session.setPlaying(false);
      session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
      gate.complete();
      await pausing;
      session.setBackgroundPlaybackBlocked(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
      expect(session.player.plays, 0);
    },
  );

  for (final duringNativeOpen in [false, true]) {
    test(
      'explicit startup pause cancels autoplay and restore (native=$duringNativeOpen)',
      () async {
        final model = _Model();
        final session = _Session(model);
        _cleanup(model, session);
        model.credentials.complete(null);
        final gate = duringNativeOpen
            ? session.player.openGate = Completer<void>()
            : null;
        if (duringNativeOpen) model.source.complete(_Source());
        final opening = session.open(play: true);
        if (duringNativeOpen) await session.player.openStarted.future;
        await session.setPlaying(false);
        session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
        session.setBackgroundPlaybackBlocked(false);
        if (duringNativeOpen) {
          gate!.complete();
        } else {
          model.source.complete(_Source());
        }
        await opening;
        await Future<void>.delayed(Duration.zero);
        expect(session.player.state.playing, isFalse);
        expect(session.player.plays, 0);
      },
    );
  }

  for (final playing in [true, false]) {
    test(
      'PiP handback while hidden restores playing=$playing only in foreground',
      () async {
        final model = _Model();
        final session = _Session(model);
        _cleanup(model, session);
        model.credentials.complete(null);
        model.source.complete(_Source());
        await session.open(play: false);
        session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
        await session.restoreTransferredPlayback(playing);
        expect(session.player.state.playing, isFalse);
        expect(session.player.plays, 0);
        session.setBackgroundPlaybackBlocked(false);
        await session.settleBackgroundPlayback();
        expect(session.player.state.playing, playing);
        expect(session.player.plays, playing ? 1 : 0);
      },
    );
  }

  test(
    'initially backgrounded startup has no playing state to restore',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      model.source.complete(_Source());
      session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
      await session.open(play: true);
      session.setBackgroundPlaybackBlocked(false);
      await Future<void>.delayed(Duration.zero);
      expect(session.player.state.playing, isFalse);
      expect(session.player.plays, 0);
    },
  );

  test(
    'closing before a slow background pause completes cancels restore',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      model.source.complete(_Source());
      await session.open();
      final pause = session.player.pauseGate = Completer<void>();
      session.setBackgroundPlaybackBlocked(true, restoreOnForeground: true);
      session.setBackgroundPlaybackBlocked(false);
      final closing = session.close();
      pause.complete();
      await closing;
      expect(session.player.plays, 0);
      expect(session.player.disposed, isTrue);
    },
  );

  test('an allowed playback session retains requested autoplay', () async {
    final model = _Model();
    final session = _Session(model);
    _cleanup(model, session);
    model.credentials.complete(null);
    model.source.complete(_Source());
    session.setBackgroundPlaybackBlocked(false);
    await session.open(play: true);
    expect(session.player.playRequests, [true]);
    expect(session.player.state.playing, isTrue);
    expect(session.player.pauses, 0);
  });

  test('closing during source connection disposes a late adapter', () async {
    final model = _Model();
    final session = _Session(model);
    final source = _Source();
    _cleanup(model, session);
    model.credentials.complete(null);
    final opening = session.open();
    await model.adapterOpened.future;
    await session.close().timeout(const Duration(seconds: 2));
    await opening.timeout(const Duration(seconds: 2));
    expect(session.player.opens, 0);
    expect(session.player.disposed, isTrue);
    model.source.complete(source);
    await Future<void>.delayed(Duration.zero);
    expect(source.closed, isTrue);
  });

  test(
    'external subtitle discovery waits for the first decoded frame',
    () async {
      final model = _Model();
      final session = _Session(model);
      final source = _Source();
      _cleanup(model, session);
      model.source.complete(source);
      model.credentials.complete(null);

      await session.open();
      expect(session.ready, isTrue);
      expect(source.listCalls, 0);
      session.player.state = const PlayerState(
        videoParams: VideoParams(w: 640, h: 360),
      );
      session.video.rect.value = const Rect.fromLTWH(0, 0, 640, 360);
      session.player.platform.frame = '{"picture-type":"I"}';
      session.video.firstFrame.complete();
      await source.listStarted.future.timeout(const Duration(seconds: 2));
      expect(session.firstFrameRendered, isTrue);
      expect(source.listCalls, 1);
      expect(
        session.startupTimings.keys,
        containsAll([
          'source',
          'native',
          'previews',
          'loadRequested',
          'firstFrame',
        ]),
      );
    },
  );

  test(
    'HTTP playback probes and reads through the same worker connection',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <(String, int)>[];
      server.listen((request) async {
        requests.add((request.method, request.connectionInfo!.remotePort));
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.contentLength = 100;
        if (request.method != 'HEAD') {
          final range = ByteRange.parse(request.headers.value('range'), 100)!;
          request.response.statusCode = 206;
          request.response.contentLength = range.length;
          request.response.headers.set(
            'Content-Range',
            'bytes ${range.start}-${range.end}/100',
          );
          request.response.add(List.filled(range.length, 1));
        }
        await request.response.close();
      });
      model.source.complete(
        _WorkerHttpSource('http://127.0.0.1:${server.port}'),
      );
      await session.open().timeout(const Duration(seconds: 3));
      expect(session.error, isEmpty);
      expect(session.ready, isTrue);
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(session.playbackUri!));
        request.headers.set('Range', 'bytes=0-15');
        final response = await request.close();
        expect(
          await response.expand((bytes) => bytes).toList(),
          List.filled(16, 1),
        );
        expect(requests.map((request) => request.$1), ['HEAD', 'GET']);
        expect(requests.map((request) => request.$2).toSet(), hasLength(1));
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'closing during a stalled HTTP probe releases startup and its socket',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      model.credentials.complete(null);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<void>(), disconnected = Completer<void>();
      Socket? socket;
      addTearDown(() async {
        socket?.destroy();
        await server.close(force: true);
      });
      server.listen((request) async {
        socket = await request.response.detachSocket(writeHeaders: false);
        socket!.listen(
          (_) {},
          onDone: disconnected.complete,
          onError: (Object _) {},
        );
        connected.complete();
      });
      model.source.complete(
        _WorkerHttpSource('http://127.0.0.1:${server.port}'),
      );
      final opening = session.open();
      await connected.future.timeout(const Duration(seconds: 3));
      await session.close().timeout(const Duration(seconds: 3));
      await opening.timeout(const Duration(seconds: 3));
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(session.player.disposed, isTrue);
      expect(session.player.opens, 0);
      expect(session.error, isEmpty);
    },
  );

  test(
    'danmaku matching starts while video source preparation is waiting',
    () async {
      final model = _Model();
      final session = _Session(model);
      final api = _Api();
      _cleanup(model, session);
      model.credentials.complete(api);

      final opening = session.open();
      await api.searchStarted.future.timeout(const Duration(seconds: 2));
      expect(model.source.isCompleted, isFalse);
      expect(session.ready, isFalse);
      expect(session.player.opens, 0);
      expect(session.danmaku, isNotNull);
      expect(api.searches, ['Example / 01']);

      model.source.complete(_Source());
      await opening.timeout(const Duration(seconds: 2));
      expect(session.ready, isTrue);
      expect(session.player.opens, 1);
      expect(session.error, isEmpty);
    },
  );

  test(
    'automatic version selection binds danmaku and resume before source startup',
    () async {
      final model = _Model();
      final session = _Session(model);
      _cleanup(model, session);
      final selection = model.selectionGate = Completer<MediaPlaybackChoice>();
      final api = _Api();
      model.credentials.complete(api);
      final selected = SyncRecord(
        id: 'preferred',
        kind: 'media',
        data: {'series': 'Selected Version', 'episode': '01'},
      );
      model.store.setLocal('location:preferred', {
        'source': 'local',
        'path': '/preferred.mkv',
      });
      model.store.save('progress', 'preferred', {
        'position': 15,
        'duration': 100,
      });
      final opening = session.open(play: true);
      await Future<void>.delayed(Duration.zero);
      expect(api.searches, isEmpty);
      expect(model.openedSources, isEmpty);
      session.setBackgroundPlaybackBlocked(true);
      session.setBackgroundPlaybackBlocked(false);
      selection.complete(
        MediaPlaybackChoice(selected, PlaybackSourcePreference.original),
      );
      await api.searchStarted.future;
      expect(api.searches, ['Selected Version / 01']);
      expect(session.media.id, 'preferred');
      expect(model.activePlaybackMediaId, 'preferred');
      model.source.complete(_Source());
      await opening;
      expect(session.ready, isTrue);
      expect(session.player.playRequests, [false]);
      expect(session.playbackUri, contains('preferred.mkv'));
      expect(session.player.requestedStart, const Duration(seconds: 15));
    },
  );

  test('slow danmaku credentials never hold video open or close', () async {
    final model = _Model();
    final session = _Session(model);
    _cleanup(model, session);
    model.source.complete(_Source());

    await session.open().timeout(const Duration(seconds: 2));
    expect(session.ready, isTrue);
    expect(session.player.opens, 1);
    expect(model.credentials.isCompleted, isFalse);
    expect(session.danmaku, isNull);

    await session.close().timeout(const Duration(seconds: 2));
    expect(session.player.disposed, isTrue);
    expect(model.credentials.isCompleted, isFalse);
    final api = _Api();
    model.credentials.complete(api);
    await Future<void>.delayed(Duration.zero);
    expect(session.danmaku, isNull);
    expect(api.searches, isEmpty);
    expect(session.notice, isEmpty);
  });

  test(
    'danmaku uses the recognized title without cleaning its symbols',
    () async {
      const title = '用【循环利息】强制收回借出的魔力 / Another: World?!';
      final model = _Model();
      final session = _Session(
        model,
        data: {
          'fileName': 'Different.Release.S02E03.mkv',
          'series': '用 强制收回借出的魔力',
          'metadataTitle': title,
          'metadataProvider': 'bangumi',
          'bangumiId': '42',
          'season': '2',
          'episode': '3',
        },
      );
      final api = _Api();
      _cleanup(model, session);
      model.source.complete(_Source());
      model.credentials.complete(api);

      await session.open();
      await api.searchStarted.future;
      await Future<void>.delayed(Duration.zero);

      expect(api.searches, ['$title / 3']);
      expect(api.matches, ['$title S02E03']);
      expect(api.titleMatches, [true]);
      expect(session.danmakuIdentity.anime, title);
    },
  );

  test('danmaku retry picks up an AI identity saved during playback', () async {
    final model = _Model();
    final session = _Session(model);
    final api = _Api();
    _cleanup(model, session);
    model.source.complete(_Source());
    model.credentials.complete(api);
    await session.open();
    await api.searchStarted.future;
    await Future<void>.delayed(Duration.zero);
    await session.updateSettings({'danmuVisible': false});
    // AI recognition commits the official catalogue title plus its parsed
    // season / episode into the same media record as manual recognition.
    model.store.save('media', 'video', {
      'series': 'AI original title',
      'metadataTitle': '用【循环利息】强制收回借出的魔力',
      'season': '1',
      'episode': '4',
    });

    await session.updateSettings({'danmuVisible': true});
    await Future<void>.delayed(Duration.zero);

    expect(api.searches, ['Example / 01', '用【循环利息】强制收回借出的魔力 / 4']);
    expect(session.danmakuIdentity.anime, '用【循环利息】强制收回借出的魔力');
    expect(session.danmakuIdentity.episode, '4');
  });

  test('a danmaku credential failure does not fail video startup', () async {
    final model = _Model();
    final session = _Session(model);
    _cleanup(model, session);
    model.source.complete(_Source());
    final opening = session.open();
    await model.adapterOpened.future;
    model.credentials.completeError(
      StateError('credential storage unavailable'),
    );

    await opening.timeout(const Duration(seconds: 2));
    expect(session.ready, isTrue);
    expect(session.player.opens, 1);
    expect(session.error, isEmpty);
    expect(session.notice, '无法读取弹幕配置，请在设置中重新保存。');
  });

  test('a late danmaku session inherits hidden inline presentation', () async {
    final model = _Model();
    final session = _Session(model);
    final api = _Api();
    _cleanup(model, session);
    session.setDanmakuPresentationActive(false);
    model.source.complete(_Source());
    final opening = session.open();
    model.credentials.complete(api);
    await opening;
    await api.searchStarted.future;
    final danmaku = session.danmaku!;
    danmaku.episodeId = '42';
    danmaku.configure(isPlaying: true);
    expect(danmaku.visible, isTrue);
    expect(danmaku.playing, isTrue);
    expect(danmaku.active, isFalse);
    session.setDanmakuPresentationActive(true);
    expect(danmaku.active, isTrue);
    session.setDanmakuPresentationActive(false);
  });

  test(
    'showing danmaku restarts an initial match cancelled by hiding',
    () async {
      final model = _Model();
      final session = _Session(model);
      final api = _GatedApi();
      _cleanup(model, session);
      model.source.complete(_Source());
      model.credentials.complete(api);
      await session.open().timeout(const Duration(seconds: 2));
      await api.firstMatch.future.timeout(const Duration(seconds: 2));
      expect(session.danmaku!.busy, isTrue);
      expect(session.danmaku!.episodeId, isNull);

      await session.updateSettings({'danmuVisible': false});
      expect(api.matchRequests.single.cancelled, isTrue);
      expect(session.danmaku!.busy, isFalse);
      final loaded = Completer<void>();
      session.danmaku!.addListener(() {
        if (session.danmaku!.episodeId == '42' && !loaded.isCompleted) {
          loaded.complete();
        }
      });
      await session.updateSettings({'danmuVisible': true});
      await loaded.future.timeout(const Duration(seconds: 2));
      expect(api.matchRequests, hasLength(2));
      expect(api.matchRequests.last.cancelled, isFalse);
      expect(session.danmaku!.visible, isTrue);
      expect(session.danmaku!.comments.single.text, 'loaded after showing');
      expect(session.danmaku!.error, isEmpty);
    },
  );
}

void _cleanup(_Model model, _Session session) {
  addTearDown(() async {
    if (!model.source.isCompleted) model.source.complete(_Source());
    if (!model.credentials.isCompleted) model.credentials.complete(null);
    await session.close();
    session.video.rect.dispose();
    model.dispose();
  });
}

class _Session extends PlaybackSession {
  _Session(AppModel model, {Map<String, dynamic>? data})
    : super(
        model,
        SyncRecord(
          id: 'video',
          kind: 'media',
          data: data ?? {'series': 'Example', 'episode': '01'},
        ),
      );

  final _player = _Player();
  final _video = _Video();
  @override
  _Player get player => _player;
  @override
  _Video get video => _video;
}

class _Model extends ChangeNotifier implements AppModel {
  _Model() {
    final fonts = Directory('${documents.path}/subtitle-fonts')..createSync();
    File('${fonts.path}/NotoSansSC-Regular.ttf').writeAsBytesSync([1]);
    store.setLocal('location:video', {'source': 'local', 'path': '/video.mkv'});
  }

  final credentials = Completer<DanmuApiClient?>();
  final source = Completer<SourceAdapter>();
  final adapterOpened = Completer<void>();
  final openedSources = <String>[];
  Map<String, dynamic>? resolvedLocation;
  Completer<Map<String, dynamic>?>? locationGate;
  Completer<MediaPlaybackChoice>? selectionGate;
  final _preferences = <String, dynamic>{};
  @override
  final store = AppStore(':memory:');
  @override
  final documents = Directory.systemTemp.createTempSync('danmaku-startup-');
  @override
  String? activePlaybackMediaId;
  @override
  AppPreferences get preferences => AppPreferences(_preferences);
  @override
  Future<void> updatePreferences(Map<String, dynamic> patch) async {
    _preferences.addAll(patch);
    notifyListeners();
  }

  @override
  Future<DanmuApiClient?> danmu() => credentials.future;
  @override
  Future<SourceAdapter> adapter(String id) {
    openedSources.add(id);
    if (!adapterOpened.isCompleted) adapterOpened.complete();
    return source.future;
  }

  @override
  Future<MediaPlaybackChoice> preferredPlaybackChoice(
    SyncRecord media, {
    CancelToken? cancel,
  }) async =>
      await selectionGate?.future ??
      MediaPlaybackChoice(media, PlaybackSourcePreference.automatic);

  @override
  Future<Map<String, dynamic>?> playbackLocation(
    SyncRecord media, {
    PlaybackSourcePreference preference = PlaybackSourcePreference.automatic,
    Map<String, dynamic>? expectedBinding,
  }) async =>
      await locationGate?.future ??
      resolvedLocation ??
      Map<String, dynamic>.from(store.local('location:${media.id}'));
  @override
  Future<void> pausePreviews() async {}
  @override
  void resumePreviews() {}
  @override
  String progressKey(SyncRecord media) => media.id;
  @override
  void changed() => notifyListeners();
  @override
  void dispose() {
    store.dispose();
    documents.deleteSync(recursive: true);
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Source extends LocalSource {
  bool closed = false;
  int listCalls = 0;
  final listStarted = Completer<void>();
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: 'video.mkv', path: path, size: 100);
  @override
  Future<List<SourceEntry>> list(String path) async {
    listCalls++;
    if (!listStarted.isCompleted) listStarted.complete();
    return [];
  }

  @override
  Future<void> close() async => closed = true;
}

class _WorkerHttpSource extends HttpSource {
  _WorkerHttpSource(super.address);
  @override
  Future<SourceEntry> stat(String path) =>
      throw StateError('Playback stat must use the HTTP bridge worker');
}

class _Api implements DanmuApiClient {
  final searches = <String>[];
  final matches = <String>[];
  final titleMatches = <bool>[];
  final searchStarted = Completer<void>();
  @override
  final origin = Uri.parse('https://danmaku.example');
  @override
  Future<List<EpisodeMatch>> search(
    String anime, {
    String episode = '',
    CancelToken? cancel,
  }) async {
    searches.add('$anime / $episode');
    if (!searchStarted.isCompleted) searchStarted.complete();
    return [];
  }

  @override
  Future<({bool matched, List<EpisodeMatch> matches})> match(
    String fileName, {
    bool isTitle = false,
    CancelToken? cancel,
  }) async {
    matches.add(fileName);
    titleMatches.add(isTitle);
    return (matched: false, matches: <EpisodeMatch>[]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedApi extends _Api {
  final firstMatch = Completer<void>();
  final matchRequests = <CancelToken>[];
  @override
  Future<({bool matched, List<EpisodeMatch> matches})> match(
    String fileName, {
    bool isTitle = false,
    CancelToken? cancel,
  }) async {
    matchRequests.add(cancel!);
    if (matchRequests.length == 1) {
      firstMatch.complete();
      await cancel.whenCancelled;
      throw const Cancelled();
    }
    return (
      matched: true,
      matches: [const EpisodeMatch('42', 'Example', '01')],
    );
  }

  @override
  String cacheKey(String episodeId) => 'test:danmaku:$episodeId';
  @override
  Future<List<DanmakuComment>> comments(
    String id, {
    CancelToken? cancel,
  }) async => [const DanmakuComment(1, 'loaded after showing', 0xffffff, 0)];
}

class _Player implements Player {
  @override
  PlayerState state = const PlayerState();
  @override
  final _Native platform = _Native();
  @override
  late final stream = PlayerStream(
    const Stream.empty(),
    _playing.stream,
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
    Stream.empty(),
  );
  int opens = 0;
  int pauses = 0;
  int plays = 0;
  Completer<void>? pauseGate, playGate;
  final playRequests = <bool>[];
  Duration? requestedStart;
  final _playing = StreamController<bool>.broadcast();
  final openStarted = Completer<void>();
  Completer<void>? openGate;
  bool disposed = false;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    playRequests.add(play);
    if (playable is Media) requestedStart = playable.start;
    openStarted.complete();
    await openGate?.future;
    emitPlaying(play);
  }

  void emitPlaying(bool value) {
    state = state.copyWith(playing: value);
    _playing.add(value);
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> pause() async {
    pauses++;
    await pauseGate?.future;
    emitPlaying(false);
  }

  @override
  Future<void> play() async {
    plays++;
    await playGate?.future;
    emitPlaying(true);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _playing.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Native implements PlatformPlayer {
  String frame = '';
  int frameReads = 0;
  final frameReadStarted = Completer<void>();
  Completer<String>? frameReadGate;
  Future<void> setProperty(String name, String value) async {}
  Future<String> getProperty(String name) async {
    if (name != 'video-frame-info') return '';
    frameReads++;
    if (!frameReadStarted.isCompleted) frameReadStarted.complete();
    return frameReadGate?.future ?? frame;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Video implements VideoController {
  final firstFrame = Completer<void>();
  @override
  final rect = ValueNotifier<Rect?>(null);
  @override
  Future<void> get waitUntilFirstFrameRendered => firstFrame.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
