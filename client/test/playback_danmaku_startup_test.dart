import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/danmaku/api.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/playback/session.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
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

  test('a danmaku credential failure does not fail video startup', () async {
    final model = _Model();
    final session = _Session(model);
    _cleanup(model, session);
    model.source.complete(_Source());
    final opening = session.open();
    model.credentials.completeError(
      StateError('credential storage unavailable'),
    );

    await opening.timeout(const Duration(seconds: 2));
    expect(session.ready, isTrue);
    expect(session.player.opens, 1);
    expect(session.error, isEmpty);
    expect(session.notice, '无法读取弹幕配置，请在设置中重新保存。');
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
  _Session(AppModel model)
    : super(
        model,
        SyncRecord(
          id: 'video',
          kind: 'media',
          data: {'series': 'Example', 'episode': '01'},
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
  Future<SourceAdapter> adapter(String id) => source.future;
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
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: 'video.mkv', path: path, size: 100);
  @override
  Future<List<SourceEntry>> list(String path) async => [];
}

class _Api implements DanmuApiClient {
  final searches = <String>[];
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
    CancelToken? cancel,
  }) async => (matched: false, matches: <EpisodeMatch>[]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedApi extends _Api {
  final firstMatch = Completer<void>();
  final matchRequests = <CancelToken>[];
  @override
  Future<({bool matched, List<EpisodeMatch> matches})> match(
    String fileName, {
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
  final state = const PlayerState();
  @override
  final platform = _Native();
  @override
  final stream = const PlayerStream(
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
    Stream.empty(),
    Stream.empty(),
  );
  int opens = 0;
  bool disposed = false;
  @override
  Future<void> open(Playable playable, {bool play = true}) async => opens++;
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> dispose() async => disposed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Native implements PlatformPlayer {
  Future<void> setProperty(String name, String value) async {}
  Future<String> getProperty(String name) async => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Video implements VideoController {
  @override
  final rect = ValueNotifier<Rect?>(null);
  @override
  final waitUntilFirstFrameRendered = Completer<void>().future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
