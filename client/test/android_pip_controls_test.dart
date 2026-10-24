import 'dart:async';

import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/playback/window_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.aiplayer/window_mode');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late _Session session;
  late PlayerWindowMode mode;

  Future<void> native(String method, dynamic arguments) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  Map<dynamic, dynamic> getRequest() =>
      calls.lastWhere((call) => call.method == 'enter').arguments as Map;

  setUp(() {
    calls.clear();
    session = _Session();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'supported' || call.method == 'enter') return true;
      return null;
    });
    mode = PlayerWindowMode(isIOS: false, isAndroid: true)
      ..bindSession(session);
  });
  tearDown(() async {
    await mode.close();
    session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'entry includes paused state and video bounds in physical pixels',
    () async {
      await mode.enter(
        aspectRatio: 16 / 9,
        sourceRect: const Rect.fromLTRB(2, 20, 402, 245),
        pixelRatio: 2,
      );
      final request = getRequest();
      expect(request['playing'], false);
      expect(request['requestId'], greaterThan(0));
      expect(request['sourceRect'], {
        'left': 4.0,
        'top': 40.0,
        'right': 804.0,
        'bottom': 490.0,
      });
    },
  );

  test('native play and pause work without another Flutter frame', () async {
    await mode.enter(aspectRatio: 16 / 9);
    final requestId = getRequest()['requestId'];
    await native('playback', {'requestId': requestId, 'playing': true});
    expect(session.player.state.playing, true);
    await native('playback', {'requestId': requestId, 'playing': false});
    expect(session.player.state.playing, false);
    expect(session.userPlaybackCommands, [true, false]);
    final state = calls.lastWhere((call) => call.method == 'setPlayback');
    expect(state.arguments, {'requestId': requestId, 'playing': false});
  });

  test(
    'unrelated notifications never repeatedly update native actions',
    () async {
      session.refresh();
      await mode.enter(aspectRatio: 16 / 9);
      final initial = calls
          .where((call) => call.method == 'setPlayback')
          .length;
      for (var index = 0; index < 20; index++) {
        session.refresh();
      }
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((call) => call.method == 'setPlayback').length,
        initial,
      );
      await session.setPlaying(true);
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((call) => call.method == 'setPlayback').length,
        initial + 1,
      );
      await native('changed', false);
      await session.setPlaying(false);
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((call) => call.method == 'setPlayback').length,
        initial + 1,
      );
    },
  );

  test(
    'dismissed and previous-entry controls cannot change playback',
    () async {
      await mode.enter(aspectRatio: 16 / 9);
      final oldRequestId = getRequest()['requestId'];
      await native('changed', false);
      await native('playback', {'requestId': oldRequestId, 'playing': true});
      expect(session.userPlaybackCommands, isEmpty);
      await mode.enter(aspectRatio: 16 / 9);
      final requestId = getRequest()['requestId'];
      expect(requestId, isNot(oldRequestId));
      await native('playback', {'requestId': oldRequestId, 'playing': true});
      expect(session.userPlaybackCommands, isEmpty);
      await native('playback', {'requestId': requestId, 'playing': true});
      expect(session.userPlaybackCommands, [true]);
    },
  );

  test(
    'rebinding detaches old playback events and rejects old controls',
    () async {
      await mode.enter(aspectRatio: 16 / 9);
      final requestId = getRequest()['requestId'];
      final previous = session;
      session = _Session();
      mode.bindSession(session);
      final initial = calls.length;
      await previous.setPlaying(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls.length, initial);
      await native('playback', {'requestId': requestId, 'playing': true});
      expect(session.userPlaybackCommands, isEmpty);
      previous.dispose();
    },
  );

  test('closed or remote sessions reject delayed native controls', () async {
    await mode.enter(aspectRatio: 16 / 9);
    final requestId = getRequest()['requestId'];
    session.remotePlayback = true;
    await native('playback', {'requestId': requestId, 'playing': true});
    session.remotePlayback = false;
    session.closed = true;
    await native('playback', {'requestId': requestId, 'playing': true});
    expect(session.userPlaybackCommands, isEmpty);
  });
}

class _Session extends ChangeNotifier implements PlaybackSession {
  @override
  final _Player player = _Player();
  @override
  bool ready = true, closed = false, remotePlayback = false;
  final userPlaybackCommands = <bool>[];

  @override
  Future<void> setPlaying(bool playing) async {
    userPlaybackCommands.add(playing);
    player.state = player.state.copyWith(playing: playing);
    notifyListeners();
  }

  void refresh() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState state = const PlayerState();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
