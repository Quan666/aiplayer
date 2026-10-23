import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../data/store.dart';
import 'api.dart';
import 'release_name.dart';

class DanmakuSession extends ChangeNotifier {
  final AppStore store;
  final DanmuApiClient api;
  final String mediaId;
  List<DanmakuComment> comments = [];
  List<DanmakuComment>? _cachedComments;
  List<EpisodeMatch> candidates = [];
  String? episodeId;
  String label = '', error = '';
  double shift = 0, offset = 0;
  bool visible = true, playing = false, busy = false;
  int interval = 30, _generation = 0;
  bool _disposed = false, _presentationActive = true;
  CancelToken? _request, _refreshRequest;
  Timer? _timer;
  DateTime? _retryAfter;
  DanmakuSession(this.store, this.api, this.mediaId);
  bool get active =>
      !_disposed &&
      _presentationActive &&
      visible &&
      playing &&
      episodeId != null &&
      interval > 0;

  /// Presentation lifetime is separate from the video clock: audio and PiP can
  /// keep playing while their invisible inline comments need no network work.
  void setPresentationActive(bool value) {
    if (_disposed || _presentationActive == value) return;
    _presentationActive = value;
    if (!value) {
      _stopRefresh();
    } else {
      _schedule(immediate: true);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _failure(Object failure) {
    final message = failure is AppFailure
        ? AppLog.instance.sanitize(failure.message)
        : '弹幕加载失败，请稍后重试。';
    if (error != message) {
      AppLog.instance.warning('弹幕', message);
    }
    error = message;
    if (failure is AppFailure) {
      if (failure.status == 429 || failure.status == 404) {
        _retryAfter = DateTime.now().add(const Duration(minutes: 5));
      }
      if (failure.status == 401 || failure.status == 403) interval = 0;
    }
  }

  bool _current(int generation) => !_disposed && _generation == generation;
  CancelToken _begin() {
    _request?.cancel();
    _stopRefresh();
    _generation++;
    busy = true;
    error = '';
    _notify();
    return _request = CancelToken();
  }

  Future<void> identify(ReleaseName guess, {bool restore = true}) async {
    final cancel = _begin(), generation = _generation;
    try {
      final missingIds = <String>{};
      AppFailure? missing;
      Future<bool> load(EpisodeMatch match, {String? savedLabel}) async {
        if (missingIds.contains(match.episodeId)) return false;
        try {
          await _load(match, cancel, generation, savedLabel: savedLabel);
          return true;
        } on AppFailure catch (failure) {
          if (failure.status != 404) rethrow;
          missingIds.add(match.episodeId);
          missing = failure;
          return false;
        }
      }

      final saved = store.get('match', mediaId);
      if (restore &&
          saved != null &&
          !saved.deleted &&
          saved.data['provider'] == api.origin.origin) {
        final d = saved.data;
        offset = (d['offset'] as num?)?.toDouble() ?? 0;
        final restored = await load(
          EpisodeMatch(
            '${d['episodeId']}',
            d['label'] ?? '',
            '',
            (d['shift'] as num?)?.toDouble() ?? 0,
          ),
          savedLabel: d['label'],
        );
        if (restored || !_current(generation)) return;
      }
      var found = <EpisodeMatch>[];
      if (guess.anime.length >= 2 && guess.episode.isNotEmpty) {
        try {
          found = await api.search(
            guess.anime,
            episode: guess.episode,
            cancel: cancel,
          );
        } on Cancelled {
          rethrow;
        } on AppFailure catch (e) {
          if ([401, 403, 429].contains(e.status)) rethrow;
          /* name matching can still succeed */
        }
        if (!_current(generation)) return;
        if (found.length == 1 &&
            (guess.season.isEmpty ||
                parseReleaseName(found.first.animeTitle).season ==
                    guess.season)) {
          if (await load(found.first) || !_current(generation)) return;
        }
      }
      final result = await api.match(guess.matchName, cancel: cancel);
      if (!_current(generation)) return;
      candidates = {
        for (final v in [...found, ...result.matches])
          if (!missingIds.contains(v.episodeId)) v.episodeId: v,
      }.values.toList();
      if (result.matched && await load(result.matches.single)) return;
      if (!_current(generation)) return;
      candidates.removeWhere((match) => missingIds.contains(match.episodeId));
      if (candidates.isEmpty && missing != null) {
        throw missing!;
      }
      error = candidates.isEmpty ? '未找到弹幕，请修改作品名称或集数。' : '请选择正确的作品和集数。';
    } on Cancelled {
      /* superseded */
    } catch (e) {
      if (_current(generation)) _failure(e);
    } finally {
      if (_current(generation)) {
        if (busy || error.isNotEmpty) {
          busy = false;
          _notify();
        }
        _schedule();
      }
    }
  }

  Future<void> search(String anime, String episode) async {
    final cancel = _begin(), generation = _generation;
    try {
      final found = await api.search(anime, episode: episode, cancel: cancel);
      if (_current(generation)) {
        candidates = found;
        error = found.isEmpty ? '未找到匹配结果。' : '';
      }
    } on Cancelled {
      /* superseded */
    } catch (e) {
      if (_current(generation)) _failure(e);
    } finally {
      if (_current(generation)) {
        busy = false;
        _notify();
        _schedule();
      }
    }
  }

  Future<void> select(EpisodeMatch match, {String? savedLabel}) async {
    final cancel = _begin(), generation = _generation;
    try {
      await _load(match, cancel, generation, savedLabel: savedLabel);
    } on Cancelled {
      /* superseded */
    } catch (e) {
      if (_current(generation)) _failure(e);
    } finally {
      if (_current(generation)) {
        if (busy || error.isNotEmpty) {
          busy = false;
          _notify();
        }
        _schedule();
      }
    }
  }

  Future<void> _load(
    EpisodeMatch match,
    CancelToken cancel,
    int generation, {
    String? savedLabel,
  }) async {
    final cacheEpoch = store.local('cacheClearEpoch');
    final key = api.cacheKey(match.episodeId);
    List<DanmakuComment>? cached;
    try {
      final saved = store.cachedJson(key);
      if (saved != null) cached = await decodeCachedComments(saved);
    } catch (_) {
      // An unreadable local cache must not prevent fetching fresh comments.
    }
    if (!_current(generation)) return;
    final values =
        cached ?? await api.comments(match.episodeId, cancel: cancel);
    if (!_current(generation)) return;
    comments = values;
    _cachedComments = cached;
    episodeId = match.episodeId;
    label = savedLabel ?? match.label;
    shift = match.shift;
    candidates = [];
    _retryAfter = null;
    _saveMatch();
    busy = false;
    _notify();
    // Render the first snapshot before encoding or persisting large caches.
    try {
      if (cached == null) {
        final encoded = await encodeComments(values);
        if (!_current(generation)) return;
        if (cacheEpoch != store.local('cacheClearEpoch')) return;
        store.cacheJson(key, encoded);
        _cachedComments = values;
      }
    } catch (_) {
      /* playback does not depend on cache space */
    }
  }

  void _saveMatch() {
    if (episodeId != null) {
      store.save('match', mediaId, {
        'provider': api.origin.origin,
        'episodeId': episodeId,
        'label': label,
        'shift': shift,
        'offset': offset,
      });
    }
  }

  void setOffset(double value) {
    if (!value.isFinite) return;
    offset = value.clamp(-86400, 86400);
    _saveMatch();
    _notify();
  }

  void configure({bool? show, bool? isPlaying, int? seconds}) {
    final previous = (visible, playing, interval);
    if (show != null) visible = show;
    if (isPlaying != null) playing = isPlaying;
    if (seconds != null && (seconds == 0 || seconds >= 30 && seconds <= 3600)) {
      interval = seconds;
    }
    if (previous == (visible, playing, interval)) return;
    if (!visible) {
      _request?.cancel();
      _generation++;
      busy = false;
    }
    if (!active) {
      _stopRefresh();
    } else {
      _schedule();
    }
    _notify();
  }

  void _stopRefresh() {
    _timer?.cancel();
    _timer = null;
    _refreshRequest?.cancel();
    _refreshRequest = null;
  }

  void _schedule({bool immediate = false}) {
    if (busy || !active || _timer != null || _refreshRequest != null) return;
    var delay = immediate ? Duration.zero : Duration(seconds: interval);
    if (_retryAfter != null) {
      final remaining = _retryAfter!.difference(DateTime.now());
      if (remaining > delay) delay = remaining;
    }
    _timer = Timer(delay, () {
      _timer = null;
      refresh();
    });
  }

  Future<void> refresh() async {
    if (busy || !active || _refreshRequest != null) return;
    final cacheEpoch = store.local('cacheClearEpoch');
    final generation = _generation, id = episodeId!, cancel = CancelToken();
    _refreshRequest = cancel;
    try {
      final values = await api.comments(id, cancel: cancel);
      if (!_current(generation) ||
          !active ||
          cancel.cancelled ||
          id != episodeId) {
        return;
      }
      final changed = !listEquals(values, comments),
          hadError = error.isNotEmpty;
      if (changed) comments = values;
      error = '';
      _retryAfter = null;
      if (changed || hadError) _notify();
      try {
        if (!identical(_cachedComments, comments)) {
          final snapshot = comments;
          final encoded = await encodeComments(snapshot);
          if (!_current(generation) || cancel.cancelled) return;
          if (cacheEpoch != store.local('cacheClearEpoch')) return;
          store.cacheJson(api.cacheKey(id), encoded);
          _cachedComments = snapshot;
        }
      } catch (_) {}
    } on Cancelled {
      /* pause or switching */
    } on AppFailure catch (e) {
      if (_current(generation) && !cancel.cancelled && id == episodeId) {
        _failure(e);
        _notify();
      }
    } finally {
      if (identical(_refreshRequest, cancel)) _refreshRequest = null;
      if (_current(generation)) _schedule();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _request?.cancel();
    _stopRefresh();
    super.dispose();
  }
}
