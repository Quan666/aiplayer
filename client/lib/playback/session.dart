import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import '../core/network.dart';
import '../core/logger.dart';
import '../data/app_model.dart';
import '../data/preferences.dart';
import '../data/playback_source.dart';
import '../data/store.dart';
import '../data/media_technical_info.dart';
import '../data/media_identity.dart';
import '../danmaku/session.dart';
import '../sources/source.dart';
import '../sources/range_bridge.dart';
import 'resume.dart';
import 'checkpoints.dart';
import 'subtitle_fonts.dart';
import '../subtitles/choice.dart';
import '../subtitles/document.dart';
import '../subtitles/chinese.dart';
import '../subtitles/ai.dart';
import '../subtitles/io.dart';
import '../subtitles/mkv.dart';

// One directory-sized task, with only its input crossing the isolate boundary.
// A large NAS folder must not sort/rank its entries on the rendering isolate.
Future<List<SourceEntry>> _rankExternalSubtitles(
  List<SourceEntry> entries,
  String videoName,
  String language,
) => Isolate.run(() {
  final ranked =
      [
        for (final entry in entries)
          if (!entry.directory && isSubtitle(entry.name))
            (entry, externalSubtitleRank(videoName, entry.name, language)),
      ]..sort((a, b) {
        final rank = b.$2.compareTo(a.$2);
        return rank == 0 ? a.$1.name.compareTo(b.$1.name) : rank;
      });
  return [for (final item in ranked) item.$1];
});

class PlaybackSession extends ChangeNotifier {
  // libass's embedded-font provider matches the legacy family (name ID 1),
  // not the variable font's typographic family "Noto Sans SC" (name ID 16).
  static const _subtitleFontFamily = 'Noto Sans SC Thin';
  final AppModel model;
  SyncRecord _media;
  SyncRecord get media => _media;
  final PlaybackSourcePreference sourcePreference;
  final Map<String, dynamic>? expectedBinding;
  late final Player player = Player(
    configuration: const PlayerConfiguration(
      libass: true,
      libassAndroidFont: 'assets/fonts/NotoSansSC-Regular.ttf',
      libassAndroidFontName: _subtitleFontFamily,
    ),
  );
  late final VideoController video = VideoController(
    player,
    configuration: VideoControllerConfiguration(
      hwdec: model.preferences.hardwareDecoding ? 'auto-safe' : 'no',
    ),
  );
  SourceAdapter? source;
  RangeBridge? bridge;
  String? playbackUri;
  DanmakuSession? danmaku;
  bool _danmakuStarted = false;
  bool _danmakuPresentationActive = true;

  void setDanmakuPresentationActive(bool value) {
    if (closed || value == _danmakuPresentationActive) return;
    _danmakuPresentationActive = value;
    danmaku?.setPresentationActive(value);
    _refreshFirstFramePresentation();
  }

  final _subscriptions = <StreamSubscription>[];
  Timer? _errorTimer, _technicalTimer;
  late final _checkpoints = PlaybackCheckpoints(
    isPlaying: () =>
        ready &&
        !closed &&
        !_transient &&
        !remotePlayback &&
        player.state.playing &&
        !player.state.buffering,
    saveProgress: saveProgress,
    capturePreview: _captureProgressPreview,
    onError: (error) =>
        AppLog.instance.warning('观看记录', safeFailure(error).message),
  );
  (Duration, int)? _lastPreviewCapture;
  (Uint8List, double)? _pendingPreviewSave;
  Future<void>? _previewSaveWork;
  Future<void> _progressWork = Future.value();
  Future<void> _technicalWork = Future.value();
  Future<void>? _diagnosticWork;
  String? _technicalFingerprint;
  int _technicalAttempts = 0;
  bool _technicalComplete = false;
  bool _firstFrameRendered = false, _playbackErrorPending = false;
  bool _firstFrameSignalled = false, _watchingVideoOutput = false;
  Timer? _firstFrameRetry;
  Future<void>? _firstFrameWork;
  bool get firstFrameRendered => _firstFrameRendered;
  bool get _transient => media.data['transient'] == true;
  final _startupClock = Stopwatch();
  final _startupCancel = CancelToken();
  final _startupTimings = <String, int>{};
  Map<String, int> get startupTimings => Map.unmodifiable(_startupTimings);
  String? _subtitleSearchPath;
  Map<String, dynamic>? _playbackLocation;
  Future<Map<String, dynamic>?>? _playbackLocationWork;
  static const _playbackErrorMessage = '播放发生错误，可尝试软解或重新打开视频。';
  final _clock = Stopwatch();
  // Position has its own notifier: moving the seek thumb must not rebuild the
  // video, settings, or every control. Danmaku uses the interpolated clock.
  final position = ValueNotifier<Duration>(Duration.zero);
  int timelineRevision = 0;
  // Counts distinct EOF transitions, so listeners can consume each completion
  // once even when unrelated settings or metadata also notify them.
  int completionRevision = 0;
  bool _completed = false;
  bool autoFullscreenAttempted = false;
  bool _previewsPaused = false;
  double _anchor = 0;
  bool ready = false, closed = false, software = false;
  String error = '', notice = '', decoder = '等待解码器启动';
  double subtitleOffset = 0;
  List<SourceEntry> externalSubtitles = [];
  final _subtitleFiles = <File>[];
  final _embeddedSubtitleTracks = <SubtitleTrack>[];
  final _knownSubtitleSelections =
      <String, (SubtitleTrack, SubtitleDocument?, String)>{};
  bool _externalSubtitleAdded = false;
  String _subtitleTransformation = '';

  SubtitleTrack? _originalSubtitle;
  SubtitleDocument? _originalDocument;
  CancelToken? _subtitleCancel;
  Future<void> _subtitleWork = Future.value();
  int _subtitleGeneration = 0;
  bool _subtitleUserSelected = false, _subtitleAutoSelected = false;
  bool subtitleTaskBusy = false, subtitleTransformed = false;
  String subtitleTaskStatus = '', subtitleTaskError = '';
  double subtitleTaskProgress = 0;
  String? _appliedSubtitleLanguage;
  bool? _appliedSimplify;
  SubtitleTrack get _selectedSubtitle =>
      _originalSubtitle ??
      player.state.tracks.subtitle
          .where((t) => t.id == player.state.track.subtitle.id)
          .firstOrNull ??
      player.state.track.subtitle;
  bool get selectedSubtitleIsImage {
    final track = _selectedSubtitle;
    return isImageSubtitle(image: track.image, codec: track.codec);
  }

  bool get hasSubtitleForTools =>
      _selectedSubtitle.id != 'auto' &&
      _selectedSubtitle.id != 'no' &&
      !selectedSubtitleIsImage;
  bool get _shouldAutomaticallySimplify {
    final track = _selectedSubtitle;
    return model.preferences.subtitleSimplify &&
        hasSubtitleForTools &&
        shouldAutomaticallySimplifySubtitle(track.language, track.title);
  }

  final Map<String, Object> _applied = {};
  Object? _requestedPreferences, _appliedPreferences;
  Future<void> _preferenceWork = Future.value();
  Future<void> _nativeOpening = Future.value();
  bool _backgroundPlaybackBlocked = false, _nativeOpenInProgress = false;
  int _backgroundPauseRevision = 0;
  Future<void>? _backgroundPauseWork;
  Future<void>? _backgroundRestoreWork;
  bool _resumeAfterBackground = false, _openingWantsPlay = false;
  bool? _pendingPlayingIntent;
  int _playbackIntentRevision = 0;
  bool get backgroundPlaybackBlocked => _backgroundPlaybackBlocked;
  int get backgroundPauseRevision => _backgroundPauseRevision;

  /// A native pause can be overtaken by a pending open. Retain the policy
  /// through source preparation, decoder opening and late playing events.
  /// Mobile callers can restore the interrupted playback intent on foreground.
  /// An initially hidden session has no foreground playback to restore.
  void setBackgroundPlaybackBlocked(
    bool value, {
    bool restoreOnForeground = false,
  }) {
    if (closed || value == _backgroundPlaybackBlocked) return;
    if (value) {
      _resumeAfterBackground =
          restoreOnForeground &&
          (_pendingPlayingIntent ??
              (_resumeAfterBackground ||
                  player.state.playing ||
                  (_openCalled && !ready && _openingWantsPlay)));
    }
    _backgroundPlaybackBlocked = value;
    _refreshFirstFramePresentation();
    if (!value) {
      _restoreAfterBackground();
      return;
    }
    _backgroundPauseRevision++;
    if (ready || _nativeOpenInProgress) unawaited(_pauseForBackground());
  }

  Future<void> _pauseForBackground() {
    if (closed) return Future.value();
    return _backgroundPauseWork ??= Future<void>.sync(player.pause)
        .catchError((Object error) {
          AppLog.instance.warning('后台暂停', safeFailure(error).message);
        })
        .whenComplete(() => _backgroundPauseWork = null);
  }

  void _restoreAfterBackground() {
    if (closed ||
        !ready ||
        _backgroundPlaybackBlocked ||
        !_resumeAfterBackground ||
        _backgroundRestoreWork != null) {
      return;
    }
    if (remotePlayback || player.state.completed || error.isNotEmpty) {
      _resumeAfterBackground = false;
      return;
    }
    final revision = _backgroundPauseRevision;
    final intent = _playbackIntentRevision;
    bool current() =>
        !closed &&
        !_backgroundPlaybackBlocked &&
        _resumeAfterBackground &&
        !remotePlayback &&
        !player.state.completed &&
        error.isEmpty &&
        revision == _backgroundPauseRevision &&
        intent == _playbackIntentRevision;
    _backgroundRestoreWork =
        () async {
              // A slow native pause must finish before the corresponding resume.
              await _backgroundPauseWork;
              if (!current()) return;
              await player.play();
              if (current()) _resumeAfterBackground = false;
              if (!closed && _backgroundPlaybackBlocked) {
                await _pauseForBackground();
              }
            }()
            .catchError((Object error) {
              _resumeAfterBackground = false;
              AppLog.instance.warning('恢复播放', safeFailure(error).message);
            })
            .whenComplete(() {
              _backgroundRestoreWork = null;
              // Coalesce rapid background/foreground cycles into one latest intent.
              if (revision != _backgroundPauseRevision) {
                _restoreAfterBackground();
              }
            });
  }

  bool _openCalled = false;
  Future<void>? _closeFuture;
  bool remotePlayback = false;
  final _closeHooks = <Future<void> Function()>{};
  void addCloseHook(Future<void> Function() hook) => _closeHooks.add(hook);
  void removeCloseHook(Future<void> Function() hook) =>
      _closeHooks.remove(hook);
  PlaybackSession(
    this.model,
    SyncRecord media, {
    this.sourcePreference = PlaybackSourcePreference.automatic,
    Map<String, dynamic>? expectedBinding,
  }) : _media = media,
       expectedBinding = playbackBindingSnapshot(expectedBinding) {
    model.addListener(_preferencesChanged);
  }

  /// Playback, subtitle extraction, seeking previews and casting must use the
  /// same physical file even if a download finishes while this session plays.
  Future<Map<String, dynamic>?> resolvePlaybackLocation() {
    if (closed) return Future.error(const Cancelled());
    return _playbackLocationWork ??= _resolvePlaybackLocation();
  }

  Future<Map<String, dynamic>?> _resolvePlaybackLocation() async {
    final choice =
        sourcePreference == PlaybackSourcePreference.automatic &&
            expectedBinding == null
        ? await subtitleCancelable(
            model.preferredPlaybackChoice(media, cancel: _startupCancel),
            _startupCancel,
          )
        : MediaPlaybackChoice(
            media,
            sourcePreference,
            expectedBinding: expectedBinding,
          );
    _startupCancel.check();
    final changed = _media.id != choice.media.id;
    _media = choice.media;
    if (_openCalled) model.activePlaybackMediaId = media.id;
    if (changed) notifyListeners();
    final location = await subtitleCancelable(
      model.playbackLocation(
        media,
        preference: choice.preference,
        expectedBinding: choice.expectedBinding,
      ),
      _startupCancel,
    );
    _startupCancel.check();
    _playbackLocation = location == null
        ? null
        : Map<String, dynamic>.unmodifiable(location);
    return _playbackLocation;
  }

  void _preferencesChanged() {
    if (!ready || closed) return;
    final key = _preferencesKey(model.preferences);
    if (key == _requestedPreferences) return;
    _requestedPreferences = key;
    _preferenceWork = _preferenceWork
        .then((_) => _applyPreferences())
        .catchError((Object e) {
          _requestedPreferences = null;
          AppLog.instance.error('播放设置', safeFailure(e).message);
          if (!closed) {
            notice = '部分播放设置未能应用，请重新打开视频。';
            _notify();
          }
        });
  }

  // Library metadata and synchronization also notify AppModel. Only changes
  // consumed by the native player or danmaku session need this async work.
  static Object _preferencesKey(AppPreferences p) => (
    p.volume,
    p.playbackRate,
    p.hardwareDecoding,
    p.subtitlesEnabled,
    p.subtitleScale,
    p.subtitleDelay,
    p.subtitleLanguage,
    p.subtitleSimplify,
    p.audioDelay,
    p.subtitlePosition,
    p.subtitleColor,
    p.subtitleBorderSize,
    p.danmuVisible,
    p.refreshInterval,
  );

  Future<void> updateSettings(Map<String, dynamic> changes) async {
    await model.updatePreferences(changes);
    await _preferenceWork;
  }

  Future<void> togglePlayback() async {
    if (closed) return;
    await setPlaying(
      !(_pendingPlayingIntent ??
          (_resumeAfterBackground || player.state.playing)),
    );
  }

  Future<void> setPlaying(bool playing) => _setPlaying(playing);

  /// Native PiP hands back its latest intent, including when the inline player
  /// must wait for foreground before it can continue.
  Future<void> restoreTransferredPlayback(bool playing) =>
      _setPlaying(playing, restoreWhenForeground: true);

  Future<void> _setPlaying(
    bool playing, {
    bool restoreWhenForeground = false,
  }) async {
    if (closed) return;
    _resumeAfterBackground = restoreWhenForeground && playing;
    _pendingPlayingIntent = playing;
    _openingWantsPlay = playing;
    final intent = ++_playbackIntentRevision;
    final pauseRevision = _backgroundPauseRevision;
    final initiallyAllowedToPlay = !_backgroundPlaybackBlocked;
    try {
      await _backgroundRestoreWork;
      await _backgroundPauseWork;
      if (closed || intent != _playbackIntentRevision) return;
      if (playing &&
          initiallyAllowedToPlay &&
          pauseRevision == _backgroundPauseRevision &&
          !_backgroundPlaybackBlocked) {
        await player.play();
        if (intent == _playbackIntentRevision && !_backgroundPlaybackBlocked) {
          _resumeAfterBackground = false;
        }
        if (!closed && _backgroundPlaybackBlocked) await _pauseForBackground();
      } else {
        await player.pause();
      }
    } finally {
      if (intent == _playbackIntentRevision) {
        _pendingPlayingIntent = null;
        if (restoreWhenForeground) _restoreAfterBackground();
      }
    }
  }

  /// Settle lifecycle commands before transferring playback to a native owner.
  Future<void> settleBackgroundPlayback() async {
    while (!closed) {
      final pause = _backgroundPauseWork, restore = _backgroundRestoreWork;
      if (pause == null && restore == null) return;
      await pause;
      await restore;
    }
  }

  Future<void> temporaryRate(double rate) async {
    if (closed) return;
    await player.setRate(rate);
  }

  Future<void> _applyPreferences() async {
    if (closed) return;
    final p = model.preferences;
    final key = _preferencesKey(p);
    _requestedPreferences = key;
    if (key == _appliedPreferences) return;
    Future<void> apply(
      String key,
      Object value,
      Future<void> Function() action,
    ) async {
      if (closed || _applied[key] == value) return;
      await action();
      _applied[key] = value;
    }

    await apply('volume', p.volume, () => player.setVolume(p.volume));
    await apply('rate', p.playbackRate, () => player.setRate(p.playbackRate));
    await apply('hwdec', p.hardwareDecoding, () async {
      await _native.setProperty(
        'hwdec',
        p.hardwareDecoding ? 'auto-safe' : 'no',
      );
      software = !p.hardwareDecoding;
    });
    await apply('subtitles', p.subtitlesEnabled, () async {
      await _native.setProperty(
        'sub-visibility',
        p.subtitlesEnabled ? 'yes' : 'no',
      );
    });
    await apply('subScale', p.subtitleScale, () async {
      await _native.setProperty('sub-scale', '${p.subtitleScale}');
    });
    await apply('subDelay', p.subtitleDelay, () async {
      await _native.setProperty('sub-delay', '${p.subtitleDelay}');
      subtitleOffset = p.subtitleDelay;
    });
    await apply('subLanguage', p.subtitleLanguage, () async {
      await _native.setProperty(
        'slang',
        mpvSubtitleLanguages(p.subtitleLanguage),
      );
    });
    for (final property in <String, Object>{
      'audio-delay': p.audioDelay,
      'sub-pos': p.subtitlePosition,
      'sub-color': p.subtitleColor,
      'sub-border-size': p.subtitleBorderSize,
    }.entries) {
      await apply(property.key, property.value, () async {
        await _native.setProperty(property.key, '${property.value}');
      });
    }
    if (_appliedSubtitleLanguage != p.subtitleLanguage) {
      _appliedSubtitleLanguage = p.subtitleLanguage;
      _subtitleAutoSelected = false;
      _subtitleUserSelected = false;
      if (ready) unawaited(_autoChooseSubtitle());
    }
    if (_appliedSimplify != p.subtitleSimplify) {
      _appliedSimplify = p.subtitleSimplify;
      if (ready &&
          _shouldAutomaticallySimplify &&
          hasSubtitleForTools &&
          !subtitleTaskBusy) {
        unawaited(simplifySubtitle());
      } else if (ready &&
          !p.subtitleSimplify &&
          _subtitleTransformation == 'simplified') {
        unawaited(restoreOriginalSubtitle());
      }
    }
    danmaku?.configure(show: p.danmuVisible, seconds: p.refreshInterval);
    if (!p.danmuVisible && danmaku?.episodeId == null) {
      // Hiding cancels an in-flight first match. Showing it must start again.
      _danmakuStarted = false;
    }
    if (p.danmuVisible && danmaku != null && !_danmakuStarted) {
      _identifyDanmaku();
    }
    _appliedPreferences = key;
    _notify();
  }

  Future<void> selectSubtitle(SubtitleTrack track) async {
    if (closed) return;
    _subtitleUserSelected = true;
    cancelSubtitleTask();
    final token = CancelToken();
    _subtitleCancel = token;
    final known = _knownSubtitleSelections[track.id];
    _originalDocument = known?.$2;
    _originalSubtitle = track.id == 'no' || track.id == 'auto'
        ? null
        : known?.$1 ?? track;
    _subtitleTransformation = known?.$3 ?? '';
    subtitleTransformed = _subtitleTransformation.isNotEmpty;
    if (track.uri) {
      final path = _localSubtitlePath(track.id);
      final stat = await subtitleCancelable(LocalSource().stat(path), token);
      if (stat.size > 16 * 1024 * 1024) {
        throw const AppFailure('外挂字幕超过 16 MiB，暂不支持加载。');
      }
      final bytes = await readSubtitleRange(
        LocalSource(),
        path,
        0,
        stat.size,
        token,
      );
      try {
        _originalDocument = SubtitleDocument(
          decodeSubtitle(bytes),
          p.extension(path),
        );
      } on AppFailure catch (e) {
        if (!e.message.startsWith('字幕不是 UTF-8')) rethrow;
      }
      token.check();
      _externalSubtitleAdded = true;
    }
    await updateSettings({'subtitlesEnabled': track.id != 'no'});
    token.check();
    await player.setSubtitleTrack(track);
    if (track.uri) {
      await _rememberSubtitleSelection(track, _originalDocument, '', token);
    }
    if (track.id == 'auto') {
      _subtitleUserSelected = false;
      _subtitleAutoSelected = false;
      await _autoChooseSubtitle();
    } else if (_shouldAutomaticallySimplify &&
        track.id != 'no' &&
        !subtitleTransformed) {
      unawaited(simplifySubtitle());
    }
    _notify();
  }

  String _localSubtitlePath(String path) {
    final uri = Uri.tryParse(path);
    if (uri?.scheme == 'file') return uri!.toFilePath();
    if (!p.isAbsolute(path) && uri?.hasScheme == true) {
      throw const AppFailure('请先下载并加载外挂字幕文件，再进行文字转换。');
    }
    return path;
  }

  Future<void> _rememberSubtitleSelection(
    SubtitleTrack original,
    SubtitleDocument? document,
    String transformation,
    CancelToken token,
  ) async {
    if (closed || token.cancelled) return;
    final String id = await _native.getProperty('sid');
    if (!closed && !token.cancelled && int.tryParse(id) != null) {
      _knownSubtitleSelections[id] = (original, document, transformation);
    }
  }

  Future<void> _autoChooseSubtitle() async {
    if (closed ||
        !ready ||
        _subtitleUserSelected ||
        _subtitleAutoSelected ||
        !model.preferences.subtitlesEnabled) {
      return;
    }
    final tracks = _embeddedSubtitleTracks;
    if (tracks.isEmpty) return;
    _subtitleAutoSelected = true;
    final language = model.preferences.subtitleLanguage;
    final ranked = tracks.toList()
      ..sort((a, b) {
        final result =
            subtitleLanguageRank(
              b.language,
              b.title,
              language,
              isDefault: b.isDefault == true,
            ).compareTo(
              subtitleLanguageRank(
                a.language,
                a.title,
                language,
                isDefault: a.isDefault == true,
              ),
            );
        return result != 0
            ? result
            : tracks.indexOf(a).compareTo(tracks.indexOf(b));
      });
    final best = language == 'auto'
        ? tracks.where((t) => t.isDefault == true).firstOrNull ?? tracks.first
        : ranked.first;
    _originalSubtitle = best;
    await player.setSubtitleTrack(best);
    if (!closed && _shouldAutomaticallySimplify) {
      unawaited(simplifySubtitle());
    }
    _notify();
  }

  Future<void> _prepareSubtitleFonts() async {
    final directory = await preparePlaybackFonts(model.documents);
    if (closed) return;
    // The family is a fallback. Do not override ASS author-selected fonts;
    // mpv retains all embedded font attachments from the current video.
    for (final entry in {
      'sub-fonts-dir': directory.path,
      'sub-font': _subtitleFontFamily,
      'embeddedfonts': 'yes',
      'sub-ass': 'yes',
      'sub-ass-override': 'no',
      'sub-auto': 'no',
      'sub-codepage': 'auto',
    }.entries) {
      await _native.setProperty(entry.key, entry.value);
    }
  }

  double get seconds =>
      _anchor +
      (player.state.playing && !player.state.buffering
          ? _clock.elapsedMicroseconds / 1000000 * player.state.rate
          : 0);

  Future<void> seek(Duration target) async {
    if (closed) return;
    // Discard retained on-screen danmaku on an explicit seek, including small
    // seeks that cannot be distinguished reliably from clock corrections.
    timelineRevision++;
    await player.seek(target);
    _notify();
  }

  void _notify() {
    if (!closed) notifyListeners();
  }

  dynamic get _native => player.platform;

  bool get _canConfirmFirstFrame =>
      !closed &&
      ready &&
      !_backgroundPlaybackBlocked &&
      _danmakuPresentationActive &&
      !player.state.buffering;

  void _refreshFirstFramePresentation() {
    if (!_canConfirmFirstFrame) {
      _firstFrameRetry?.cancel();
      _firstFrameRetry = null;
      return;
    }
    _videoOutputChanged();
  }

  void _videoOutputChanged() {
    if (!_canConfirmFirstFrame ||
        !ready ||
        _firstFrameRendered ||
        !_firstFrameSignalled ||
        _firstFrameWork != null) {
      return;
    }
    final output = video.rect.value;
    final params = player.state.videoParams;
    // Desktop media_kit allocates a 1x1 placeholder texture and reports it as
    // its first frame. Keep the cover/loading state until decoded dimensions
    // and the real output surface are both available.
    if (output == null ||
        output.width <= 1 ||
        output.height <= 1 ||
        (params.dw ?? params.w ?? 0) <= 0 ||
        (params.dh ?? params.h ?? 0) <= 0) {
      return;
    }
    _firstFrameWork = _confirmFirstFrame().whenComplete(() {
      _firstFrameWork = null;
      if (_canConfirmFirstFrame && !_firstFrameRendered) {
        _firstFrameRetry ??= Timer(const Duration(milliseconds: 32), () {
          _firstFrameRetry = null;
          _videoOutputChanged();
        });
      }
    });
  }

  Future<void> _confirmFirstFrame() async {
    // Android's controller also completes its first-frame future when setting
    // the Surface size. Require an actual decoded frame and a settled buffer.
    try {
      final frame = await _native.getProperty('video-frame-info');
      if (!_canConfirmFirstFrame ||
          frame == null ||
          frame.isEmpty ||
          frame == '{}' ||
          frame == 'null') {
        return;
      }
      _firstFrameRendered = true;
      _startupTimings['firstFrame'] = _startupClock.elapsedMilliseconds;
      video.rect.removeListener(_videoOutputChanged);
      _watchingVideoOutput = false;
      _firstFrameRetry?.cancel();
      AppLog.instance.info(
        '播放',
        '首帧 ${_startupClock.elapsedMilliseconds} ms'
            '（来源 ${_startupTimings['source'] ?? 0} ms，'
            '内核准备 ${_startupTimings['native'] ?? 0} ms，'
            '预览退出 ${_startupTimings['previews'] ?? 0} ms）',
      );
      _recoverPlaybackError();
      _scheduleTechnicalInfo();
      _notify();
      // Directory enumeration shares the SMB worker with video reads. Let the
      // decoder deliver its first frame before optional subtitle discovery.
      final path = _subtitleSearchPath;
      if (path != null) unawaited(_findSubtitles(path));
    } catch (_) {
      // A frame is unavailable while mpv is still preparing its output.
    }
  }

  Future<void> _prepareNativePlayback() async {
    await Future.wait([
      _prepareSubtitleFonts(),
      _applyPreferences(),
      () async {
        // Keep read-ahead in RAM. The bridge already exposes local HTTP, so
        // mpv's disk cache adds writes even for fast LAN/file playback.
        await _native.setProperty('cache-on-disk', 'no');
        await _native.setProperty('cache-pause-initial', 'no');
        await _native.setProperty('cache-pause-wait', '0.15');
      }(),
    ]);
  }

  Future<(String, String)> _preparePlaybackSource() async {
    final location = await resolvePlaybackLocation();
    _startupCancel.check();
    if (location == null) throw const AppFailure('请先关联本机视频位置。');
    // Matching and cached subtitles must bind to the selected file version.
    unawaited(_prepareDanmaku());
    final sourceId = location['source'] as String;
    final opened = await _openSource(sourceId, _startupCancel);
    if (closed) {
      await opened.close();
      return ('', '');
    }
    source = opened;
    final path = location['path'] as String;
    final SourceEntry stat;
    final String uri;
    if (opened is LocalSource) {
      stat = await subtitleCancelable(opened.stat(path), _startupCancel);
      uri = path;
    } else {
      // The bridge owns network reads. In particular, HTTP stat and the first
      // GET must use its same worker/client to reuse the warmed TCP/TLS socket.
      final serving = await RangeBridge.open(
        opened,
        path,
        cancel: _startupCancel,
      );
      bridge = serving;
      stat = serving.entry;
      uri = serving.uri.toString();
    }
    if (closed) return ('', '');
    if (location['offline'] != true && location['size'] != stat.size) {
      await model.store.updatePlaybackLocationSize(
        media.id,
        sourceId: sourceId,
        path: path,
        size: stat.size,
      );
      if (closed) return ('', '');
    }
    _technicalFingerprint = MediaTechnicalInfo.fingerprint(model.store, media);
    playbackUri = opened is LocalSource ? File(path).uri.toString() : uri;
    if (!stat.seekable) notice = '此来源未声明范围读取能力，拖动可能不可用。';
    return (uri, path);
  }

  Future<T> _measureStartup<T>(String phase, Future<T> Function() work) async {
    final clock = Stopwatch()..start();
    try {
      return await work();
    } finally {
      _startupTimings[phase] = clock.elapsedMilliseconds;
    }
  }

  Future<void> open({bool? play, bool resume = true}) async {
    if (closed || _openCalled) return;
    _openCalled = true;
    _openingWantsPlay = play ?? model.preferences.autoPlay;
    final openingIntentRevision = _playbackIntentRevision;
    final openingPauseRevision = _backgroundPauseRevision;
    final initiallyAllowedToPlay = !_backgroundPlaybackBlocked;
    _startupClock.start();
    model.activePlaybackMediaId = media.id;
    try {
      _previewsPaused = true;
      // Source connection, decoder configuration and preview cleanup are
      // independent. Do not add their latency together before decoding.
      late (String, String) preparedSource;
      _nativeOpening = Future.wait<void>([
        _measureStartup('previews', model.pausePreviews),
        _measureStartup('native', _prepareNativePlayback),
        _measureStartup(
          'source',
          _preparePlaybackSource,
        ).then((value) => preparedSource = value),
      ]).then((_) {});
      await _nativeOpening;
      if (closed) return;
      final (uri, path) = preparedSource;
      _subtitleSearchPath = path;
      _subscriptions.add(
        player.stream.position.listen((position) {
          _anchor = position.inMicroseconds / 1000000;
          _clock.reset();
          final advanced = position > this.position.value;
          this.position.value = position;
          if (_firstFrameRendered &&
              advanced &&
              player.state.playing &&
              !player.state.buffering) {
            _recoverPlaybackError();
          }
        }),
      );
      void state() {
        _clock.reset();
        _anchor = player.state.position.inMicroseconds / 1000000;
        _checkpoints.updatePlaybackState();
        _refreshFirstFramePresentation();
        danmaku?.configure(
          isPlaying: player.state.playing && !player.state.buffering,
        );
        _notify();
      }

      _subscriptions.add(
        player.stream.playing.listen((_) {
          state();
          if (_backgroundPlaybackBlocked && player.state.playing) {
            unawaited(_pauseForBackground());
          }
          if (!player.state.playing) checkpoint();
        }),
      );
      _subscriptions.add(player.stream.buffering.listen((_) => state()));
      _subscriptions.add(player.stream.rate.listen((_) => state()));
      _subscriptions.add(player.stream.volume.listen((_) => _notify()));
      _subscriptions.add(
        player.stream.duration.listen((_) {
          _recordMetadata();
          _notify();
        }),
      );
      _subscriptions.add(
        player.stream.videoParams.listen((_) {
          _videoOutputChanged();
          _recordMetadata();
          _notify();
        }),
      );
      _subscriptions.add(
        player.stream.tracks.listen((tracks) {
          if (!_externalSubtitleAdded &&
              _embeddedSubtitleTracks.isEmpty &&
              tracks.subtitle.any((t) => t.id != 'auto' && t.id != 'no')) {
            _embeddedSubtitleTracks.addAll(
              tracks.subtitle.where(
                (t) => t.id != 'auto' && t.id != 'no' && !t.uri && !t.data,
              ),
            );
          }
          if (ready) unawaited(_autoChooseSubtitle());
          _notify();
        }),
      );
      _subscriptions.add(
        player.stream.completed.listen((complete) {
          if (closed || complete == _completed) return;
          _completed = complete;
          if (complete) {
            // Snapshot this episode before notifying auto-next listeners. The
            // worker persists progress and watched atomically without making
            // an EOF transition wait for SQLite's writer lock on the UI isolate.
            unawaited(
              saveProgress(completed: true).then(
                (_) {
                  if (!closed) model.changed();
                },
                onError: (Object error) =>
                    AppLog.instance.warning('观看记录', safeFailure(error).message),
              ),
            );
            completionRevision++;
            _notify();
          }
        }),
      );
      _subscriptions.add(player.stream.error.listen(_playbackError));
      // mpv reports failed hardware decoder attempts as errors even when it
      // successfully falls back. A decoded first frame proves startup recovered.
      video.rect.addListener(_videoOutputChanged);
      _watchingVideoOutput = true;
      unawaited(
        video.waitUntilFirstFrameRendered
            .then<void>((_) {
              if (closed) return;
              _firstFrameSignalled = true;
              _videoOutputChanged();
            })
            .catchError((Object _) {}),
      );
      _clock.start();
      final progress = model.store.get('progress', model.progressKey(media));
      final resumePosition =
          !_transient && resume && model.preferences.resumePlayback
          ? playbackResumeSeconds(
              position: (progress?.data['position'] as num?)?.toDouble() ?? 0,
              duration: (progress?.data['duration'] as num?)?.toDouble(),
            )
          : 0.0;
      _startupTimings['loadRequested'] = _startupClock.elapsedMilliseconds;
      _nativeOpening = () async {
        if (closed) return;
        _nativeOpenInProgress = true;
        try {
          await player.open(
            Media(
              uri,
              start: Duration(milliseconds: (resumePosition * 1000).round()),
            ),
            play:
                _openingWantsPlay &&
                initiallyAllowedToPlay &&
                !_backgroundPlaybackBlocked &&
                openingPauseRevision == _backgroundPauseRevision,
          );
        } finally {
          _nativeOpenInProgress = false;
        }
        if (!initiallyAllowedToPlay ||
            _backgroundPlaybackBlocked ||
            (openingIntentRevision != _playbackIntentRevision &&
                !_openingWantsPlay) ||
            openingPauseRevision != _backgroundPauseRevision) {
          // A pause issued while open was pending may precede its final play
          // command. Always place another pause after the completed open.
          await _backgroundPauseWork;
          await _pauseForBackground();
        }
      }();
      await _nativeOpening;
      if (closed) return;
      ready = true;
      _restoreAfterBackground();
      _videoOutputChanged();
      model.activePlaybackMediaId = media.id;
      _scheduleTechnicalInfo();
      unawaited(_autoChooseSubtitle());
      AppLog.instance.info('播放', '视频已打开');
      _checkpoints.start();
      _notify();
      unawaited(refreshDiagnostics());
    } catch (e) {
      if (!closed) {
        error = safeFailure(e, action: '打开视频失败').message;
        AppLog.instance.error('播放', error);
        _notify();
        _resumePreviews();
      }
    }
  }

  Future<void> _prepareDanmaku() async {
    // Credential lookup and matching run alongside source connection/decoding.
    // An optional service failure must never delay video or subtitle startup.
    try {
      final api = await model.danmu();
      if (closed || api == null) return;
      danmaku = DanmakuSession(model.store, api, media.id)
        ..addListener(_notify)
        ..setPresentationActive(_danmakuPresentationActive);
      danmaku!.configure(
        isPlaying: player.state.playing && !player.state.buffering,
        show: model.preferences.danmuVisible,
        seconds: model.preferences.refreshInterval,
      );
      if (danmaku!.visible) _identifyDanmaku();
      _notify();
    } catch (_) {
      if (closed) return;
      notice = '无法读取弹幕配置，请在设置中重新保存。';
      _notify();
    }
  }

  /// Reuse catalogue / AI identity, including corrections made during playback.
  ReleaseName get danmakuIdentity {
    final current = model.store.get('media', media.id);
    return mediaRecordIdentity(
      current != null && !current.deleted ? current.data : media.data,
    );
  }

  void _identifyDanmaku() {
    _danmakuStarted = true;
    unawaited(danmaku!.identify(danmakuIdentity));
  }

  Future<void> _findSubtitles(String path) async {
    if (closed) return;
    try {
      if (source is HttpSource && !(source as HttpSource).webdav) return;
      final directory = source is LocalSource
          ? p.dirname(path)
          : p.posix.dirname(path);
      final entries = await source!.list(directory == '.' ? '' : directory);
      if (closed) return;
      final language = model.preferences.subtitleLanguage;
      final name = p.basename(path);
      final ranked = await _rankExternalSubtitles(entries, name, language);
      if (closed) return;
      externalSubtitles = ranked;
      _notify();
      final best = externalSubtitles.firstOrNull;
      final same =
          best != null && externalSubtitleRank(name, best.name, language) >= 0
          ? best
          : null;
      if (same != null &&
          !_subtitleUserSelected &&
          model.preferences.subtitlesEnabled &&
          model.preferences.autoLoadExternalSubtitles) {
        await loadSubtitle(same, automatic: true);
      }
    } catch (e) {
      if (e is Cancelled || closed) return;
      subtitleTaskError = safeFailure(e, action: '查找外挂字幕失败').message;
      AppLog.instance.warning('外挂字幕', subtitleTaskError);
      _notify();
    }
  }

  Future<void> loadSubtitle(SourceEntry entry, {bool automatic = false}) async {
    if (closed || source == null) return;
    if (!automatic) _subtitleUserSelected = true;
    cancelSubtitleTask();
    final token = CancelToken();
    _subtitleCancel = token;
    final generation = _subtitleGeneration;
    final location = _playbackLocation;
    if (location == null) throw const AppFailure('视频来源尚未准备好。');
    final adapter = await _openSource(location['source'] as String, token);
    try {
      final stat = await subtitleCancelable(adapter.stat(entry.path), token);
      if (stat.size > 16 * 1024 * 1024) {
        throw const AppFailure('外挂字幕超过 16 MiB，暂不支持加载。');
      }
      final bytes = await readSubtitleRange(
        adapter,
        entry.path,
        0,
        stat.size,
        token,
      );
      token.check();
      if (closed || generation != _subtitleGeneration) return;
      final format = p
          .extension(entry.name)
          .replaceFirst('.', '')
          .toLowerCase();
      SubtitleDocument? document;
      try {
        document = SubtitleDocument(decodeSubtitle(bytes), format);
      } on AppFailure catch (e) {
        // Legacy encodings can still be decoded by mpv; report the limitation
        // only when text conversion is explicitly requested.
        if (!e.message.startsWith('字幕不是 UTF-8')) rethrow;
      }
      final file = await _subtitleFile(bytes, format);
      token.check();
      if (closed || generation != _subtitleGeneration) return;
      final track = SubtitleTrack.uri(file.path, title: entry.name);
      _originalSubtitle = track;
      _originalDocument = document;
      subtitleTransformed = false;
      _subtitleTransformation = '';
      _externalSubtitleAdded = true;
      await updateSettings({'subtitlesEnabled': true});
      token.check();
      await player.setSubtitleTrack(track);
      await _rememberSubtitleSelection(track, document, '', token);
      token.check();
      subtitleTaskStatus = '外挂字幕已加载';
      subtitleTaskError = '';
      AppLog.instance.info('外挂字幕', '外挂字幕已加载。');
      _notify();
      if (_shouldAutomaticallySimplify) unawaited(simplifySubtitle());
    } finally {
      await adapter.close();
    }
  }

  Future<SourceAdapter> _openSource(String sourceId, CancelToken token) async {
    token.check();
    final pending = model.adapter(sourceId);
    var taken = false;
    // A connector can finish opening after cancellation. Close that late
    // adapter without keeping video teardown waiting for its handshake.
    unawaited(
      pending.then<void>((adapter) {
        if (token.cancelled && !taken) {
          unawaited(adapter.close().catchError((Object _) {}));
        }
      }, onError: (Object _, StackTrace _) {}),
    );
    final adapter = await subtitleCancelable(pending, token);
    taken = true;
    return adapter;
  }

  Future<File> _subtitleFile(List<int> bytes, String format) async {
    if (!['srt', 'ass', 'ssa', 'vtt'].contains(format)) {
      throw const AppFailure('不支持此字幕格式。');
    }
    final directory = Directory(p.join(model.documents.path, 'subtitle-cache'));
    await directory.create(recursive: true);
    final file = File(
      p.join(
        directory.path,
        '${DateTime.now().microsecondsSinceEpoch}.$format',
      ),
    );
    _subtitleFiles.add(file);
    await file.writeAsBytes(bytes, flush: true);
    if (closed) {
      try {
        await file.delete();
      } catch (_) {}
    }
    return file;
  }

  void cancelSubtitleTask() {
    _subtitleGeneration++;
    _subtitleCancel?.cancel();
    _subtitleCancel = null;
    subtitleTaskBusy = false;
    subtitleTaskStatus = '';
    subtitleTaskError = '';
    subtitleTaskProgress = 0;
    _notify();
  }

  Future<SubtitleDocument> _subtitleDocument(CancelToken token) async {
    if (_originalDocument != null) return _originalDocument!;
    final track = _originalSubtitle ?? player.state.track.subtitle;
    if (track.id == 'no' || track.id == 'auto') {
      throw const AppFailure('请先选择一个字幕轨道或加载外挂字幕。');
    }
    if (isImageSubtitle(image: track.image, codec: track.codec)) {
      throw const AppFailure('图片字幕无法直接繁简转换或 AI 翻译，请加载 ASS / SRT 文字字幕。');
    }
    _originalSubtitle = track;
    if (track.uri) {
      final path = _localSubtitlePath(track.id);
      final stat = await subtitleCancelable(File(path).stat(), token);
      if (stat.size > 16 * 1024 * 1024) {
        throw const AppFailure('字幕超过 16 MiB，暂不支持转换。');
      }
      final data = await readSubtitleRange(
        LocalSource(),
        path,
        0,
        stat.size,
        token,
      );
      return SubtitleDocument(decodeSubtitle(data), p.extension(path));
    }
    final index = _embeddedSubtitleTracks.indexWhere((t) => t.id == track.id);
    if (index < 0) throw const AppFailure('无法找到原始字幕轨道，请重新选择内嵌字幕或加载外挂字幕。');
    final location = _playbackLocation;
    if (location == null) throw const AppFailure('视频来源尚未准备好。');
    final adapter = await _openSource(location['source'] as String, token);
    try {
      final path = location['path'] as String;
      final stat = await subtitleCancelable(adapter.stat(path), token);
      if (!stat.seekable) {
        throw const AppFailure('来源不支持 Range，无法有界读取内嵌字幕。请加载外挂字幕。');
      }
      final extracted = await extractMkvSubtitle(
        read: (offset, length) =>
            readSubtitleRange(adapter, path, offset, length, token),
        fileSize: stat.size,
        subtitleIndex: index,
        cancel: token,
        onProgress: (done, total) {
          if (!token.cancelled && !closed) {
            subtitleTaskStatus = '读取内嵌字幕 $done / $total';
            subtitleTaskProgress = total == 0 ? 0 : done / total;
            _notify();
          }
        },
      );
      token.check();
      return SubtitleDocument(extracted.text, extracted.format);
    } finally {
      await adapter.close();
    }
  }

  Future<void> _transformSubtitle(bool ai) {
    cancelSubtitleTask();
    final token = CancelToken();
    _subtitleCancel = token;
    final generation = _subtitleGeneration;
    subtitleTaskBusy = true;
    subtitleTaskStatus = '正在读取字幕';
    _notify();
    final previous = _subtitleWork;
    final work = () async {
      await previous;
      try {
        token.check();
        final document = await _subtitleDocument(token);
        token.check();
        _originalDocument = document;
        String text;
        if (ai) {
          final settings = model.settings;
          final secret =
              await subtitleCancelable(
                model.secrets.read(key: 'aiSubtitleToken'),
                token,
              ) ??
              '';
          AppLog.instance.rememberSecret(secret);
          token.check();
          final config = SubtitleAiConfig(
            origin:
                '${settings['aiSubtitleOrigin'] ?? 'https://api.openai.com/v1'}',
            token: secret,
            model: '${settings['aiSubtitleModel'] ?? ''}',
            target: '${settings['aiSubtitleTarget'] ?? '简体中文'}',
            prompt: '${settings['aiSubtitlePrompt'] ?? defaultSubtitlePrompt}',
          );
          final translator = SubtitleTranslator(
            load: (key) {
              final value = model.store.local(key);
              return value is Map ? Map<String, dynamic>.from(value) : null;
            },
            save: (key, value) {
              token.check();
              model.store.setLocal(key, value);
            },
          );
          text = await translator.translate(
            document,
            config,
            token,
            onProgress: (done, total) {
              if (!token.cancelled && !closed) {
                subtitleTaskStatus = '翻译 $done / $total';
                subtitleTaskProgress = done / total;
                _notify();
              }
            },
          );
        } else {
          subtitleTaskStatus = '正在转换为简体';
          _notify();
          final converter = await subtitleCancelable(
            ChineseConverter.load(),
            token,
          );
          token.check();
          text = converter.document(document);
        }
        token.check();
        final file = await _subtitleFile(utf8.encode(text), document.format);
        token.check();
        if (closed || generation != _subtitleGeneration) return;
        _externalSubtitleAdded = true;
        await player.setSubtitleTrack(
          SubtitleTrack.uri(
            file.path,
            title: ai ? 'AI 翻译' : '简体字幕',
            language: 'zh-Hans',
          ),
        );
        token.check();
        _subtitleTransformation = ai ? 'ai' : 'simplified';
        await _rememberSubtitleSelection(
          _originalSubtitle!,
          document,
          _subtitleTransformation,
          token,
        );
        token.check();
        subtitleTransformed = true;
        subtitleTaskStatus = ai ? '翻译完成' : '已转换为简体';
        subtitleTaskProgress = 1;
        AppLog.instance.info('字幕', ai ? '字幕翻译完成。' : '字幕繁简转换完成。');
      } catch (e) {
        if (e is Cancelled || token.cancelled || closed) return;
        subtitleTaskStatus = '';
        subtitleTaskError = safeFailure(
          e,
          action: ai ? '字幕翻译失败' : '字幕转换失败',
        ).message;
        AppLog.instance.warning('字幕', subtitleTaskError);
      } finally {
        if (!closed && generation == _subtitleGeneration) {
          subtitleTaskBusy = false;
          _notify();
        }
      }
    }();
    _subtitleWork = work;
    return work;
  }

  Future<void> simplifySubtitle() => _transformSubtitle(false);
  Future<void> translateSubtitle() => _transformSubtitle(true);
  Future<void> restoreOriginalSubtitle() async {
    cancelSubtitleTask();
    final original = _originalSubtitle;
    if (original != null && !closed) await player.setSubtitleTrack(original);
    _subtitleTransformation = '';
    subtitleTransformed = false;
    _notify();
  }

  void _playbackError(String message) {
    if (closed) return;
    AppLog.instance.error('播放内核', message);
    _playbackErrorPending = true;
    // Keep the diagnostic immediately, but allow automatic decoder fallback or
    // network recovery before displaying a persistent error over a valid frame.
    _errorTimer ??= Timer(const Duration(milliseconds: 1200), () {
      _errorTimer = null;
      if (closed || !_playbackErrorPending) return;
      error = _playbackErrorMessage;
      _notify();
    });
  }

  void _recoverPlaybackError() {
    if (closed || !_playbackErrorPending) return;
    _playbackErrorPending = false;
    _errorTimer?.cancel();
    _errorTimer = null;
    AppLog.instance.info('播放', '错误后已继续输出画面');
    if (error == _playbackErrorMessage) {
      error = '';
      _notify();
    }
  }

  void _recordMetadata() {
    if (closed || player.state.duration <= Duration.zero) return;
    final video = player.state.videoParams;
    final rotated = (video.rotate ?? 0).abs() % 180 == 90;
    final width = video.dw ?? video.w, height = video.dh ?? video.h;
    model.recordMediaMetadata(
      media.id,
      duration: player.state.duration.inMilliseconds / 1000,
      width: rotated ? height : width,
      height: rotated ? width : height,
    );
    _scheduleTechnicalInfo();
  }

  void _scheduleTechnicalInfo() {
    if (closed ||
        !ready ||
        _technicalComplete ||
        _technicalAttempts >= 3 ||
        _technicalTimer != null) {
      return;
    }
    // Native startup publishes several related changes. Read one coalesced
    // snapshot, then retry only a bounded number of times for late bitrate data.
    _technicalTimer = Timer(const Duration(milliseconds: 700), () {
      _technicalTimer = null;
      _technicalWork = _technicalWork
          .then((_) => _captureTechnicalInfo())
          .catchError((Object error) {
            AppLog.instance.warning('视频规格', safeFailure(error).message);
          });
    });
  }

  Future<void> _captureTechnicalInfo() async {
    if (closed || _technicalComplete || _technicalAttempts >= 3) return;
    _technicalAttempts++;
    Future<String> property(String name) async {
      try {
        final value = '${await _native.getProperty(name)}'.trim();
        return value == 'null' || value == 'unknown' ? '' : value;
      } catch (_) {
        return '';
      }
    }

    final values = await Future.wait([
      property('file-format'),
      property('current-tracks/video/codec'),
      property('video-bitrate'),
    ]);
    if (closed) return;
    var codec = values[1];
    if (codec.isEmpty) codec = await property('video-format');
    if (codec.isEmpty) codec = await property('video-codec');
    if (closed ||
        MediaTechnicalInfo.fingerprint(model.store, media) !=
            _technicalFingerprint) {
      return;
    }
    final params = player.state.videoParams;
    final bitrate = double.tryParse(values[2]);
    final actualBitrate = bitrate != null && bitrate.isFinite && bitrate > 0
        ? bitrate.round()
        : null;
    final info = MediaTechnicalInfo(
      container: videoContainerLabel(values[0]),
      codec: videoCodecLabel(codec),
      width: params.w,
      height: params.h,
      bitrate: actualBitrate,
      duration: player.state.duration.inMilliseconds / 1000,
    );
    info.save(model.store, media);
    _technicalComplete =
        values[0].isNotEmpty &&
        codec.isNotEmpty &&
        (params.w ?? 0) > 0 &&
        (params.h ?? 0) > 0 &&
        actualBitrate != null;
    if (!_technicalComplete) _scheduleTechnicalInfo();
  }

  void _resumePreviews() {
    if (!_previewsPaused) return;
    _previewsPaused = false;
    model.resumePreviews();
  }

  Future<void> setSubtitleOffset(double value) =>
      updateSettings({'subtitleDelay': value});

  Future<Uint8List> captureScreenshot({bool includeSubtitles = true}) async {
    if (closed || !ready) throw const AppFailure('视频尚未打开，暂时无法截图。');
    final params = player.state.videoParams;
    final pixels = (params.dw ?? params.w ?? 0) * (params.dh ?? params.h ?? 0);
    if (pixels > 34000000) throw const AppFailure('视频画面过大，暂不支持截图。');
    final bytes = await player.screenshot(
      format: 'image/jpeg',
      includeLibassSubtitles: includeSubtitles,
    );
    if (bytes == null || bytes.isEmpty) {
      throw const AppFailure('尚未取得视频画面，请等待视频显示后重试。');
    }
    return bytes;
  }

  Future<void> setSoftware(bool value) async {
    await updateSettings({'hardwareDecoding': !value});
    await refreshDiagnostics();
  }

  Future<void> refreshDiagnostics() => _diagnosticWork ??= _readDiagnostics()
      .whenComplete(() => _diagnosticWork = null);

  Future<void> _readDiagnostics() async {
    if (closed) return;
    try {
      final hw = await _native.getProperty('hwdec-current');
      final codec = await _native.getProperty('video-codec');
      if (!closed) {
        final value = '${hw == '' || hw == 'no' ? '软件解码' : hw} · $codec';
        if (decoder != value) {
          decoder = value;
          _notify();
        }
      }
    } catch (_) {
      /* no video yet */
    }
  }

  void checkpoint({bool capturePreview = true}) {
    if (_transient || closed || !ready || remotePlayback) return;
    _checkpoints.checkpoint(capturePreview: capturePreview);
  }

  Future<void> _captureProgressPreview() async {
    if (_transient ||
        !ready ||
        remotePlayback ||
        player.state.playing ||
        player.state.buffering ||
        player.state.completed ||
        player.state.position <= Duration.zero) {
      return;
    }
    final params = player.state.videoParams;
    final pixels = (params.dw ?? params.w ?? 0) * (params.dh ?? params.h ?? 0);
    if (pixels <= 0 || pixels > 34000000) return;
    final snapshot = (player.state.position, timelineRevision);
    if (_lastPreviewCapture == snapshot) return;
    final current = snapshot.$1.inMilliseconds / 1000;
    // Do not poll or wait for a network seek here. Keep the existing cover and
    // let a visible library row request extraction if no stable frame exists.
    if (await _native.getProperty('seeking') != 'no') return;
    final before = double.tryParse(await _native.getProperty('time-pos'));
    if (before == null || !before.isFinite || (before - current).abs() > .15) {
      return;
    }
    final bytes = await player.screenshot(
      format: 'image/jpeg',
      includeLibassSubtitles: false,
    );
    final after = double.tryParse(await _native.getProperty('time-pos'));
    if (bytes == null ||
        bytes.isEmpty ||
        after == null ||
        !after.isFinite ||
        (after - current).abs() > .15 ||
        player.state.playing ||
        snapshot != (player.state.position, timelineRevision) ||
        await _native.getProperty('seeking') != 'no') {
      return;
    }
    _lastPreviewCapture = snapshot;
    // The native frame is now owned by Dart. Resizing, compression and disk
    // I/O do not extend the player's disposal barrier or block navigation.
    _pendingPreviewSave = (bytes, current);
    _previewSaveWork ??= _savePreviewFrames().whenComplete(() {
      _previewSaveWork = null;
    });
    model.trackPlaybackPreviewWork(_previewSaveWork!);
  }

  Future<void> _savePreviewFrames() async {
    while (_pendingPreviewSave != null) {
      final (bytes, position) = _pendingPreviewSave!;
      _pendingPreviewSave = null;
      try {
        await model.savePlaybackPreview(media.id, bytes, position: position);
      } catch (error) {
        AppLog.instance.warning('观看记录', safeFailure(error).message);
      }
    }
  }

  Future<void> saveProgress({bool completed = false}) {
    completed |= player.state.completed;
    if (_transient ||
        remotePlayback ||
        !ready ||
        (!completed && player.state.duration <= Duration.zero)) {
      return Future.value();
    }
    final duration =
        (completed && player.state.duration <= Duration.zero
                ? player.state.position
                : player.state.duration)
            .inMilliseconds /
        1000;
    final position = completed
        ? duration
        : player.state.position.inMilliseconds / 1000;
    final progressId = model.progressKey(media);
    final data = <String, dynamic>{
      'position': position,
      'duration': duration,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'devicePlatform': Platform.operatingSystem,
    };
    final watchedId = completed || position / duration >= .95
        ? model.watchedKey(media)
        : null;
    // Snapshot before queuing: a slow write must never replace a later seek or
    // exit checkpoint with a position read after that event. SQLite persistence
    // owns its worker; this future only preserves ordering and schedules sync.
    final saving = _progressWork.then((_) async {
      final changed = await model.store.savePlaybackProgress(
        progressId,
        data,
        watchedId: watchedId,
      );
      if (changed) model.requestProgressSync();
    });
    // Return errors to this caller without poisoning subsequent checkpoints.
    _progressWork = saving.catchError((Object _) {});
    return saving;
  }

  /// Every caller observes the same completion, including route disposal while
  /// an explicit back/replace operation is already closing the native player.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closed = true;
    _resumeAfterBackground = false;
    _startupCancel.cancel();
    _firstFrameRetry?.cancel();
    if (_watchingVideoOutput) {
      video.rect.removeListener(_videoOutputChanged);
      _watchingVideoOutput = false;
    }
    _checkpoints.stop();
    for (final hook in _closeHooks.toList()) {
      try {
        await hook();
      } catch (_) {
        /* Cleanup remains independent. */
      }
    }
    _closeHooks.clear();
    try {
      if (ready) await player.pause();
      await saveProgress();
    } catch (e) {
      AppLog.instance.warning('观看记录', safeFailure(e).message);
    }
    model.removeListener(_preferencesChanged);
    cancelSubtitleTask();
    _errorTimer?.cancel();
    _technicalTimer?.cancel();
    _clock.stop();
    danmaku?.removeListener(_notify);
    danmaku?.dispose();
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        AppLog.instance.warning('关闭播放', safeFailure(e).message);
      }
    }

    // Never dispose mpv underneath an open/property/screenshot command. Subtitle
    // HTTP, secure-storage and adapter-open waits are cancellation-aware.
    await cleanup(() => _subtitleWork);
    await cleanup(() => _nativeOpening);
    await cleanup(() async => _backgroundPauseWork);
    await cleanup(() async => _backgroundRestoreWork);
    await cleanup(() async {
      await _firstFrameWork;
    });
    await cleanup(() => _technicalWork);
    await cleanup(() async => _diagnosticWork);
    await cleanup(() => _preferenceWork);
    for (final subscription in _subscriptions) {
      await cleanup(subscription.cancel);
    }
    await cleanup(_checkpoints.close);
    await cleanup(() => _progressWork);
    await cleanup(player.dispose);
    position.dispose();
    await cleanup(() async {
      await bridge?.close();
    });
    await cleanup(() async {
      await source?.close();
    });
    for (final file in _subtitleFiles) {
      try {
        await file.delete();
      } catch (_) {}
    }
    if (model.activePlaybackMediaId == media.id) {
      model.activePlaybackMediaId = null;
    }
    _resumePreviews();
    if (_transient) await cleanup(() => model.disposeExternalMedia(media.id));
    model.changed();
  }
}
