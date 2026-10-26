import 'dart:convert';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import '../core/logger.dart';
import '../core/network.dart';

class DanmakuComment {
  final double time;
  final String text;
  final int color, mode;
  final String? userId;
  const DanmakuComment(
    this.time,
    this.text,
    this.color,
    this.mode, [
    this.userId,
  ]);
  Map<String, dynamic> toJson() => {
    'time': time,
    'text': text,
    'color': color,
    'mode': mode,
    if (userId != null) 'userId': userId,
  };
  @override
  bool operator ==(Object other) =>
      other is DanmakuComment &&
      time == other.time &&
      text == other.text &&
      color == other.color &&
      mode == other.mode &&
      userId == other.userId;
  @override
  int get hashCode => Object.hash(time, text, color, mode, userId);
}

List<DanmakuComment> normalizeComments(List<dynamic> input) {
  final output = <DanmakuComment>[];
  for (final item in input) {
    if (item is! Map) continue;
    dynamic time = item['time'],
        text = item['text'],
        color = item['color'],
        mode = item['mode'] ?? 0,
        user = item['userId'];
    if (item['p'] is String) {
      final p = (item['p'] as String).split(',');
      if (p.length < 3) continue;
      time = p[0];
      mode = {'1': 0, '5': 1, '4': 2}[p[1]];
      color = p.length >= 7 ? p[3] : p[2];
      user = p.length >= 7
          ? p[6]
          : p.length > 3
          ? p[3]
          : null;
      text = item['m'];
    }
    final t = double.tryParse('$time'), m = int.tryParse('$mode');
    if (t == null ||
        !t.isFinite ||
        t < 0 ||
        m == null ||
        ![0, 1, 2].contains(m) ||
        text is! String) {
      continue;
    }
    text = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    if (text.isEmpty) continue;
    var rgb = int.tryParse('$color');
    if (color is String &&
        RegExp(r'^#[a-f0-9]{6}$', caseSensitive: false).hasMatch(color)) {
      rgb = int.parse(color.substring(1), radix: 16);
    }
    if (rgb == null || rgb < 0 || rgb > 0xffffff) rgb = 0xffffff;
    output.add(
      DanmakuComment(
        t,
        text,
        rgb,
        m,
        user is String && user.trim().isNotEmpty ? user.trim() : null,
      ),
    );
  }
  // Preserve source order among comments sharing a timestamp.
  final indexed = output.indexed.toList()
    ..sort((a, b) {
      final c = a.$2.time.compareTo(b.$2.time);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  // Snapshot identity is the revision used by the presentation worker.
  return List<DanmakuComment>.unmodifiable(indexed.map((e) => e.$2));
}

Future<List<DanmakuComment>> normalizeCommentsAsync(
  List<dynamic> input,
) async => input.length < 1000
    ? normalizeComments(input)
    : await Isolate.run(() => normalizeComments(input));

List<DanmakuComment>? _decodeCachedComments(String text) {
  final value = jsonDecode(text);
  if (value is! List || value.isEmpty) return null;
  final comments = normalizeComments(value);
  return comments.isEmpty ? null : comments;
}

Future<List<DanmakuComment>?> decodeCachedComments(String text) async =>
    text.length < 64 * 1024
    ? _decodeCachedComments(text)
    : await Isolate.run(() => _decodeCachedComments(text));

String _encodeComments(List<DanmakuComment> comments) =>
    jsonEncode(comments.map((comment) => comment.toJson()).toList());

Future<String> encodeComments(List<DanmakuComment> comments) async =>
    comments.length < 1000
    ? _encodeComments(comments)
    : await Isolate.run(() => _encodeComments(comments));

class EpisodeMatch {
  final String episodeId, animeTitle, episodeTitle;
  final double shift;
  final int? commentCount;
  const EpisodeMatch(
    this.episodeId,
    this.animeTitle,
    this.episodeTitle, [
    this.shift = 0,
    this.commentCount,
  ]);
  String get label => '$animeTitle · $episodeTitle';
}

bool validEpisodeId(String id) => RegExp(r'^[1-9]\d{0,18}$').hasMatch(id);

int? _commentCount(Object? value) {
  final count = value is int
      ? value
      : value is String
      ? int.tryParse(value, radix: 10)
      : null;
  return count != null && count >= 0 ? count : null;
}

class DanmuApiClient {
  static const defaultOrigin = 'https://danmu-api.cutejk.com';
  final Uri origin;
  final String _token;
  final JsonTransport transport;
  DanmuApiClient(String address, String token, {JsonTransport? transport})
    : origin = _origin(address),
      _token = _checkToken(token),
      transport = transport ?? IoJsonTransport();
  static Uri _origin(String value) {
    final u = Uri.tryParse(value);
    if (u == null ||
        u.scheme != 'https' ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        !['', '/'].contains(u.path) ||
        u.hasQuery ||
        u.hasFragment) {
      throw const AppFailure('弹幕 API 地址须为 HTTPS 站点地址，不含路径或参数。');
    }
    return Uri.parse(u.origin);
  }

  static String _checkToken(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
      throw const AppFailure('请在设置中填写有效的弹幕 API Token。');
    }
    return value;
  }

  String cacheKey(String episodeId) => sha256
      .convert(utf8.encode('${origin.origin}/$_token/$episodeId/color-v2'))
      .toString();
  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    CancelToken? cancel,
  }) async {
    final operation = switch (path) {
      'search/episodes' => '弹幕搜索',
      'match' => '弹幕匹配',
      _ => '弹幕下载',
    };
    final clock = Stopwatch()..start();
    try {
      return await transport.send(
        origin.replace(path: '/$_token/api/v2/$path', queryParameters: query),
        method: body == null ? 'GET' : 'POST',
        body: body,
        cancel: cancel,
      );
    } on AppFailure catch (failure) {
      if (failure.status == 404) {
        throw AppFailure(
          path.startsWith('comment/')
              ? '该剧集的弹幕请求返回 HTTP 404，请重新匹配；若所有视频均失败，请检查服务地址和 Token。'
              : '$operation请求返回 HTTP 404，请检查服务地址、Token 及接口兼容性。',
          404,
        );
      }
      rethrow;
    } finally {
      // Record slow stages without authenticated URLs or response contents.
      if (clock.elapsedMilliseconds >= 1000 && cancel?.cancelled != true) {
        AppLog.instance.info(
          '弹幕',
          '$operation ${clock.elapsedMilliseconds} ms',
        );
      }
    }
  }

  Future<List<EpisodeMatch>> search(
    String anime, {
    String episode = '',
    CancelToken? cancel,
  }) async {
    if (anime.trim().length < 2) throw const AppFailure('作品名称至少需要 2 个字符。');
    if (episode.isNotEmpty &&
        !RegExp(
          r'^(?:[CSO])?\d{1,5}$',
          caseSensitive: false,
        ).hasMatch(episode)) {
      throw const AppFailure('集数请填写数字，或 C1 / S1 / O1。');
    }
    final data = await _request(
      'search/episodes',
      query: {
        'anime': anime.trim(),
        if (episode.isNotEmpty) 'episode': episode,
      },
      cancel: cancel,
    );
    if (data['animes'] is! List) throw const AppFailure('弹幕服务搜索响应格式无效。');
    final result = <EpisodeMatch>[], ids = <String>{};
    for (final a in data['animes']) {
      if (a is! Map || a['episodes'] is! List) continue;
      for (final e in a['episodes']) {
        if (e is! Map) continue;
        final id = '${e['episodeId']}';
        if (!validEpisodeId(id) || !ids.add(id)) continue;
        result.add(
          EpisodeMatch(
            id,
            '${a['animeTitle'] ?? ''}',
            '${e['episodeTitle'] ?? ''}',
            0,
            _commentCount(e['commentCount']),
          ),
        );
      }
    }
    return result;
  }

  Future<({bool matched, List<EpisodeMatch> matches})> match(
    String fileName, {
    bool isTitle = false,
    CancelToken? cancel,
  }) async {
    // A recognized work title can contain slashes (e.g. Fate/stay night).
    // Only raw file paths need their directory components removed.
    final name = isTitle
        ? fileName.trim()
        : fileName.split(RegExp(r'[/\\]')).last.trim();
    if (name.isEmpty || name.length > 1000) throw const AppFailure('视频识别参数无效。');
    final data = await _request(
      'match',
      body: {'fileName': name},
      cancel: cancel,
    );
    if (data['matches'] is! List || data['isMatched'] is! bool) {
      throw const AppFailure('弹幕服务匹配响应格式无效。');
    }
    final matches = <EpisodeMatch>[];
    for (final m in data['matches']) {
      if (m is! Map || !validEpisodeId('${m['episodeId']}')) continue;
      final shift = double.tryParse('${m['shift']}') ?? 0;
      matches.add(
        EpisodeMatch(
          '${m['episodeId']}',
          '${m['animeTitle'] ?? ''}',
          '${m['episodeTitle'] ?? ''}',
          shift.isFinite && shift.abs() <= 86400 ? shift : 0,
          _commentCount(m['commentCount']),
        ),
      );
    }
    return (
      matched: data['isMatched'] == true && matches.length == 1,
      matches: matches,
    );
  }

  Future<List<DanmakuComment>> comments(
    String id, {
    CancelToken? cancel,
  }) async {
    if (!validEpisodeId(id)) throw const AppFailure('弹幕剧集编号无效。');
    final data = await _request(
      'comment/$id',
      query: {'format': 'json', 'withRelated': 'true', 'chConvert': '0'},
      cancel: cancel,
    );
    if (data['comments'] is! List) throw const AppFailure('弹幕服务弹幕响应格式无效。');
    cancel?.check();
    final comments = await normalizeCommentsAsync(data['comments']);
    cancel?.check();
    return comments;
  }
}
