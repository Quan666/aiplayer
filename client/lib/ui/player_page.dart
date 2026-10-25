import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../danmaku/overlay.dart';
import '../data/app_model.dart';
import '../data/store.dart';
import '../playback/session.dart';
import '../playback/display.dart';
import '../playback/input.dart';
import '../playback/playlist.dart';
import '../playback/seek_preview.dart';
import '../playback/seek_timeline.dart';
import '../playback/window_mode.dart';
import '../playback/desktop_window.dart';
import '../playback/fullscreen_transition.dart';
import 'cast_sheet.dart';
import '../core/logger.dart';
import '../subtitles/tools_panel.dart';
import 'player_controls_settings.dart';
import 'player_danmaku_panel.dart';
import 'player_loading.dart';
import 'player_model_changes.dart';
import 'player_seek_readout.dart';
import 'player_theme.dart';
import 'glass.dart';
import 'library_page.dart';
import 'media_artwork.dart';

String clockText(Duration value) {
  final total = value.inSeconds.clamp(0, 1 << 40);
  return '${total >= 3600 ? '${total ~/ 3600}:' : ''}${(total ~/ 60 % 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
}

bool? _cachedVideoIsLandscape(AppModel model, SyncRecord media) {
  final dimensions = model.mediaDimensions(media);
  return dimensions == null
      ? null
      : videoIsLandscape(width: dimensions.width, height: dimensions.height);
}

/// Programmatic requests use the same frame-preserving switch as the playlist.
class PlayerPageController {
  Future<void> Function(SyncRecord)? _select;

  Future<bool> selectMedia(SyncRecord media) async {
    final select = _select;
    if (select == null) return false;
    await select(media);
    return true;
  }
}

class PlayerPage extends StatefulWidget {
  static final Set<Future<void>> _pendingDisposals = {};

  /// Route removal is synchronous, but native playback and system UI cleanup
  /// are not. All player entry points await this before opening a new video.
  static Future<void> waitForDisposals() async {
    while (_pendingDisposals.isNotEmpty) {
      await Future.wait(_pendingDisposals.toList());
    }
  }

  static void _trackDisposal(Future<void> cleanup) {
    _pendingDisposals.add(cleanup);
    unawaited(
      cleanup.then((_) {
        _pendingDisposals.remove(cleanup);
      }),
    );
  }

  final AppModel model;
  final SyncRecord media;
  final PlayerPageController? controller;
  final Future<void> Function()? onClose;

  /// Exercise mobile lifecycle policy with a real decoder on a desktop test host.
  @visibleForTesting
  final bool? mobilePlaybackLifecycle;
  const PlayerPage({
    super.key,
    required this.model,
    required this.media,
    this.controller,
    this.onClose,
    this.mobilePlaybackLifecycle,
  });
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late PlaybackSession session = PlaybackSession(widget.model, widget.media);
  bool _switchingMedia = false;
  int _handledCompletionRevision = 0;
  bool? _fullscreenLandscape;
  bool _leaving = false, _nativeFullscreen = false, _disposed = false;
  bool _backgrounded = false;
  final _fullscreenTransitions = FullscreenTransition();
  final _mediaTransitions = FullscreenTransition();
  int _fullscreenRevision = 0;
  Object? _surfaceState, _videoWidgetKey;
  Widget? _videoWidget;
  PlaybackSession? _retiringSession;
  Widget? _retiringSurface;
  PlaybackSession? _presentingSession;
  bool _framePresented = false;
  Timer? _orientationDeadline;
  bool _waitingForOrientation = false;
  final display = PlayerDisplay();
  final windowMode = PlayerWindowMode();
  final _settingsAnchor = GlobalKey();
  final _speedAnchor = GlobalKey();
  final _modelChanges = PlayerModelChanges();
  Widget _playerSurface(Widget child) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: PlayerTheme.of(context).systemOverlay,
    child: PlayerTheme.surface(child),
  );
  @override
  void initState() {
    super.initState();
    widget.controller?._select = selectMedia;
    WidgetsBinding.instance.addObserver(this);
    _backgrounded = playbackIsBackgrounded(
      WidgetsBinding.instance.lifecycleState,
    );
    _syncBackgroundPlayback();
    session.addListener(_changed);
    windowMode.bindSession(session);
    windowMode.addListener(_windowChanged);
    _modelChanges.update(widget.model, session.media);
    widget.model.addListener(_modelChanged);
    unawaited(
      display.watchOrientation(widget.model.preferences.autoRotateFullscreen),
    );
    // This route already occupies the complete player viewport. Native
    // fullscreen does not need a second route or a second controls tree.
    unawaited(_openSession());
  }

  @override
  void didUpdateWidget(PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._select = null;
      widget.controller?._select = selectMedia;
    }
  }

  Future<void> _openSession() async {
    if (PlayerDisplay.supported && widget.model.preferences.enterFullscreen) {
      session.autoFullscreenAttempted = true;
      // Issue system-bar/orientation changes before decoding can expose a
      // first frame at the old viewport size.
      await _enterFullscreen();
    }
    if (!_disposed && !_leaving) await session.open();
  }

  double? get _videoAspectRatio {
    final params = session.player.state.videoParams;
    final actual = videoAspectRatio(
      width: params.dw ?? params.w,
      height: params.dh ?? params.h,
      rotation: params.rotate ?? 0,
    );
    if (actual != null) return actual;
    final cached = widget.model.mediaDimensions(session.media);
    return videoAspectRatio(width: cached?.width, height: cached?.height);
  }

  Widget get _videoSurface {
    final key = (
      session,
      _videoAspectRatio,
      widget.model.preferences.keepScreenOn,
      widget.model.preferences.videoFit,
    );
    if (_videoWidgetKey == key && _videoWidget != null) return _videoWidget!;
    _videoWidgetKey = key;
    return _videoWidget = Video(
      key: ValueKey(session),
      controller: session.video,
      onEnterFullscreen: _enterFullscreen,
      // media_kit invokes this even when PopScope rejects a pop. The
      // page owns restoration, after an explicit exit or disposal.
      onExitFullscreen: () async {},
      wakelock: widget.model.preferences.keepScreenOn,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
      fit: switch (widget.model.preferences.videoFit) {
        'cover' => BoxFit.cover,
        'fill' => BoxFit.fill,
        _ => BoxFit.contain,
      },
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        visible: false,
      ),
      controls: null,
      aspectRatio: _videoAspectRatio,
    );
  }

  void _changed() {
    _presentFirstFrame();
    _scheduleNextEpisode();
    if (_nativeFullscreen && !windowMode.active && !session.closed) {
      unawaited(_fullscreenTransitions.run(_syncVideoOrientation));
    }
    // Controls already listen to the session. Volume, buffering and subtitle
    // task updates must not replace Video's parameters/controls builder too.
    final next = (
      session.ready,
      session.firstFrameRendered,
      session.error,
      _videoAspectRatio,
    );
    if (next == _surfaceState) return;
    _surfaceState = next;
    if (mounted) setState(() {});
  }

  void _presentFirstFrame() {
    if (!session.firstFrameRendered || _presentingSession == session) return;
    final current = session;
    _presentingSession = current;
    // Texture size notifications precede composition. Keep the cover or the
    // paused previous texture through the frame which attaches the new output.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _leaving || session != current) return;
        final previous = _retiringSession;
        setState(() {
          _framePresented = true;
          _retiringSession = null;
          _retiringSurface = null;
        });
        if (previous != null) PlayerPage._trackDisposal(previous.close());
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _refreshControls() {
    unawaited(
      display.watchOrientation(widget.model.preferences.autoRotateFullscreen),
    );
    if (_nativeFullscreen &&
        !windowMode.active &&
        !_switchingMedia &&
        !session.closed) {
      unawaited(_fullscreenTransitions.run(_syncVideoOrientation));
    }
    if (mounted) setState(() {});
  }

  void _modelChanged() {
    _syncBackgroundPlayback();
    _scheduleNextEpisode();
    if (_modelChanges.update(widget.model, session.media)) _refreshControls();
  }

  void _scheduleNextEpisode() {
    if (_disposed ||
        _leaving ||
        _switchingMedia ||
        session.closed ||
        !session.ready ||
        session.completionRevision == _handledCompletionRevision) {
      return;
    }
    _handledCompletionRevision = session.completionRevision;
    if (!widget.model.preferences.autoNextEpisode ||
        session.backgroundPlaybackBlocked ||
        session.remotePlayback ||
        session.error.isNotEmpty) {
      return;
    }
    final completed = session;
    final completionRevision = completed.completionRevision;
    final timelineRevision = completed.timelineRevision;
    final backgroundPauseRevision = completed.backgroundPauseRevision;
    // Session notifications also rebuild the controls. Let those notifications
    // finish before replacing their session or touching the native player.
    scheduleMicrotask(() async {
      if (!mounted ||
          _disposed ||
          _leaving ||
          _switchingMedia ||
          !identical(session, completed) ||
          completed.closed ||
          completed.backgroundPlaybackBlocked ||
          completed.backgroundPauseRevision != backgroundPauseRevision ||
          completed.remotePlayback ||
          completed.error.isNotEmpty ||
          !completed.player.state.completed ||
          completed.completionRevision != completionRevision ||
          completed.timelineRevision != timelineRevision ||
          !widget.model.preferences.autoNextEpisode) {
        return;
      }
      try {
        final playlist = playbackPlaylist(widget.model, completed.media);
        final index = playlist.indexWhere(
          (item) => item.id == completed.media.id,
        );
        if (index < 0 || index + 1 >= playlist.length) return;
        await selectMedia(playlist[index + 1], autoAdvance: true);
      } catch (error) {
        AppLog.instance.error(
          '自动续播',
          safeFailure(error, action: '播放下一集失败').message,
        );
        if (mounted && !_leaving && !_disposed) showFailure(context, error);
      }
    });
  }

  Future<void> _syncVideoOrientation() async {
    if (!PlayerDisplay.supported || !_nativeFullscreen) return;
    final params = session.player.state.videoParams;
    final landscape =
        videoIsLandscape(
          width: params.dw ?? params.w,
          height: params.dh ?? params.h,
          rotation: params.rotate ?? 0,
        ) ??
        _cachedVideoIsLandscape(widget.model, session.media);
    if (landscape == null || landscape == _fullscreenLandscape) return;
    _fullscreenLandscape = landscape;
    _orientationDeadline?.cancel();
    _waitingForOrientation = true;
    // Android applies rotation asynchronously after the channel reply. Keep
    // the video covered until the viewport has the requested shape. A bounded
    // fallback also supports multi-window/OS modes that decline rotation.
    _orientationDeadline = Timer(const Duration(milliseconds: 750), () {
      _waitingForOrientation = false;
      if (mounted && !_disposed) setState(() {});
    });
    if (mounted) setState(() {});
    await SystemChrome.setPreferredOrientations(
      landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
  }

  void _windowChanged() {
    final state = WidgetsBinding.instance.lifecycleState;
    if (playbackIsBackgrounded(state)) _backgrounded = true;
    _syncBackgroundPlayback();
    _refreshControls();
  }

  Future<void> _enterFullscreen() {
    if (_disposed || _leaving || session.closed) return Future.value();
    if (_nativeFullscreen) return _fullscreenTransitions.idle;
    final revision = ++_fullscreenRevision;
    setState(() => _nativeFullscreen = true);
    return _fullscreenTransitions.run(() => _applyFullscreen(revision));
  }

  Future<void> _applyFullscreen(int revision) async {
    try {
      if (_disposed || _leaving || session.closed) return;
      if (!PlayerDisplay.supported) {
        if (windowMode.active) await windowMode.exit();
        final entered = await DesktopWindow.setFullscreen(true);
        if (!entered && mounted && revision == _fullscreenRevision) {
          setState(() => _nativeFullscreen = false);
        }
        return;
      }
      await _syncVideoOrientation();
      if (_disposed || _leaving || !_nativeFullscreen) return;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (_disposed || _leaving || !_nativeFullscreen) return;
      await PlayerDisplay.setImmersive(true);
    } catch (error) {
      if (mounted && revision == _fullscreenRevision) {
        setState(() => _nativeFullscreen = false);
        showFailure(context, error);
      }
    }
  }

  Future<void> _exitFullscreen() {
    if (!_nativeFullscreen) return _fullscreenTransitions.idle;
    ++_fullscreenRevision;
    if (mounted) {
      setState(() => _nativeFullscreen = false);
    } else {
      _nativeFullscreen = false;
    }
    return _fullscreenTransitions.run(_restoreFullscreen);
  }

  Future<void> _orientFullscreen(String direction) =>
      _fullscreenTransitions.run(() async {
        if (_disposed || _leaving || !_nativeFullscreen) return;
        await SystemChrome.setPreferredOrientations([
          direction == 'landscapeLeft'
              ? DeviceOrientation.landscapeLeft
              : DeviceOrientation.landscapeRight,
        ]);
      });

  Future<void> _restoreFullscreen() async {
    if (!PlayerDisplay.supported) {
      await DesktopWindow.setFullscreen(false);
    } else {
      await PlayerDisplay.restoreSystemUi(
        restoreOrientation: _leaving || _disposed,
      );
    }
  }

  Future<void> _disposePlayback() async {
    // Run every cleanup even if an optional platform channel fails. Logging is
    // sanitized and this barrier always resolves, so one failure cannot strand
    // external-open handling or leave the decoder alive.
    for (final cleanup in [
      () async {
        await _fullscreenTransitions.idle;
      },
      () async {
        // An explicit fullscreen toggle keeps the video's orientation. Once
        // playback leaves, release it even if fullscreen was already off.
        if (_nativeFullscreen) {
          await _exitFullscreen();
        } else if (PlayerDisplay.supported) {
          await PlayerDisplay.restoreSystemUi();
        }
      },
      display.dispose,
      windowMode.close,
      session.close,
      () async {
        await _retiringSession?.close();
      },
    ]) {
      try {
        await cleanup();
      } catch (error) {
        AppLog.instance.error(
          '播放器',
          safeFailure(error, action: '关闭失败').message,
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      _syncBackgroundPlayback();
    } else if (playbackIsBackgrounded(state)) {
      _saveBackgroundState();
    }
  }

  void _syncBackgroundPlayback() => session.setBackgroundPlaybackBlocked(
    playbackShouldPauseInBackground(
      mobile: widget.mobilePlaybackLifecycle ?? PlayerDisplay.supported,
      backgrounded: _backgrounded,
      pauseOnBackground: widget.model.preferences.pauseOnBackground,
      pictureInPicture: windowMode.active,
    ),
    restoreOnForeground: true,
  );

  void _saveBackgroundState() {
    _backgrounded = true;
    _syncBackgroundPlayback();
    if (session.closed) return;
    session.checkpoint();
    unawaited(display.restoreBrightness());
  }

  @override
  void dispose() {
    _disposed = true;
    widget.controller?._select = null;
    _orientationDeadline?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_changed);
    windowMode.removeListener(_windowChanged);
    widget.model.removeListener(_modelChanged);
    PlayerPage._trackDisposal(_disposePlayback());
    super.dispose();
  }

  Future<void> leave() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    // Decoder disposal and progress thumbnails continue behind the disposal
    // barrier; they must not block the user's navigation gesture.
    if (!session.closed) {
      unawaited(session.setPlaying(false).catchError((Object _) {}));
    }
    if (widget.onClose != null) {
      await widget.onClose!();
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> selectMedia(SyncRecord media, {bool autoAdvance = false}) {
    // Capture before queuing: another selection or a background/resume cycle
    // can finish while this request waits for an earlier native transition.
    final expectedSession = session;
    final expectedPauseRevision = session.backgroundPauseRevision;
    bool requestIsCurrent() =>
        !autoAdvance ||
        (identical(session, expectedSession) &&
            session.backgroundPauseRevision == expectedPauseRevision &&
            !session.backgroundPlaybackBlocked);
    return _mediaTransitions.run(() async {
      if (!requestIsCurrent()) return;
      await _selectMedia(
        media,
        autoAdvance: autoAdvance,
        requestIsCurrent: requestIsCurrent,
      );
    });
  }

  Future<void> _selectMedia(
    SyncRecord media, {
    bool autoAdvance = false,
    required bool Function() requestIsCurrent,
  }) async {
    if (!mounted ||
        _disposed ||
        _leaving ||
        media.id == session.media.id ||
        !requestIsCurrent()) {
      return;
    }
    _switchingMedia = true;
    final previous = session;
    try {
      if (windowMode.active) await windowMode.exit();
      if (!mounted || _disposed || _leaving || !requestIsCurrent()) return;
      await previous.setPlaying(false);
      if (!mounted || _disposed || _leaving || !requestIsCurrent()) return;
      if (_retiringSession == null && _framePresented) {
        _retiringSession = previous;
        _retiringSurface = _videoSurface;
      }
      windowMode.unbindSession(previous);
      previous.removeListener(_changed);
      final next = PlaybackSession(widget.model, media);
      next.autoFullscreenAttempted = true;
      next.addListener(_changed);
      windowMode.bindSession(next);
      _handledCompletionRevision = 0;
      setState(() {
        session = next;
        _framePresented = false;
        _surfaceState = null;
      });
      _syncBackgroundPlayback();
      if (_nativeFullscreen) {
        unawaited(_fullscreenTransitions.run(_syncVideoOrientation));
      }
      // Keep the same route, display ownership, and orientation while the next
      // video opens. Only confirmed portrait dimensions change orientation.
      if (_retiringSession != previous) {
        PlayerPage._trackDisposal(previous.close());
      }
      await next.open(play: autoAdvance ? true : null, resume: !autoAdvance);
    } finally {
      _switchingMedia = false;
      if (mounted && !_leaving) _changed();
    }
  }

  Future<void> tracks(bool audio) async {
    if (audio) {
      await audioTracks();
      return;
    }
    await showModalBottomSheet(
      context: PlayerTheme.routeContext(context),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: PlayerTheme.of(context).barrierColor,
      builder: (c) => _playerSurface(
        PlayerSheet(
          child: AnimatedBuilder(
            animation: session,
            builder: (c, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '字幕',
                      style: PlayerTheme.of(context).panelTitleStyle,
                    ),
                  ),
                  SubtitleToolsPanel(session: session),
                  ListTile(
                    dense: true,
                    minTileHeight: PlayerTheme.choiceRowWithSubtitleHeight,
                    title: const Text('时间偏移'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _PlayerButton(
                          tooltip: '字幕提前',
                          icon: Icons.remove_rounded,
                          size: 34,
                          iconSize: 18,
                          onPressed: () => session.setSubtitleOffset(
                            session.subtitleOffset - .5,
                          ),
                        ),
                        SizedBox(
                          width: 62,
                          child: Text(
                            '${session.subtitleOffset.toStringAsFixed(1)} 秒',
                            textAlign: TextAlign.center,
                            style: PlayerTheme.of(context).smallLabelStyle,
                          ),
                        ),
                        _PlayerButton(
                          tooltip: '字幕延后',
                          icon: Icons.add_rounded,
                          size: 34,
                          iconSize: 18,
                          onPressed: () => session.setSubtitleOffset(
                            session.subtitleOffset + .5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    dense: true,
                    minTileHeight: PlayerTheme.choiceRowHeight,
                    leading: const Icon(Icons.file_open_outlined, size: 19),
                    title: const Text('选择本地外挂字幕'),
                    onTap: () async {
                      try {
                        final picked = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['srt', 'ass', 'ssa', 'vtt'],
                        );
                        final path = picked?.files.single.path;
                        if (path != null && !session.closed) {
                          await session.selectSubtitle(SubtitleTrack.uri(path));
                          if (c.mounted) Navigator.pop(c);
                        }
                      } catch (error) {
                        if (c.mounted) showFailure(c, error);
                      }
                    },
                  ),
                  const Divider(height: 12),
                  for (final track in session.player.state.tracks.subtitle)
                    _trackRow(
                      track.id == 'no'
                          ? '关闭字幕'
                          : track.id == 'auto'
                          ? '自动选择'
                          : track.title ?? track.language ?? track.id,
                      centerSelection: true,
                      selected:
                          session.player.state.track.subtitle.id == track.id,
                      onTap: () async {
                        try {
                          await session.selectSubtitle(track);
                          if (c.mounted) Navigator.pop(c);
                        } catch (error) {
                          if (c.mounted) showFailure(c, error);
                        }
                      },
                    ),
                  for (final entry in session.externalSubtitles)
                    _trackRow(
                      entry.name,
                      centerSelection: true,
                      selected:
                          session.player.state.track.subtitle.title ==
                          entry.name,
                      onTap: () async {
                        try {
                          await session.loadSubtitle(entry);
                          if (c.mounted) Navigator.pop(c);
                        } catch (error) {
                          if (c.mounted) showFailure(c, error);
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _trackRow(
    String label, {
    required bool selected,
    bool centerSelection = false,
    int maxLines = 2,
    required VoidCallback onTap,
  }) => PlayerScrollToSelection(
    selected: centerSelection && selected,
    child: PlayerChoiceTile(
      selected: selected,
      title: Text(
        label,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: PlayerTheme.of(context).playlistItemStyle(selected: selected),
      ),
      onTap: onTap,
    ),
  );

  String _audioTrackLabel(AudioTrack track) => switch (track.id) {
    'auto' => '自动选择',
    'no' => '关闭音轨',
    _ => track.title ?? track.language ?? track.id,
  };

  Future<void> audioTracks() async {
    final current = session;
    final selected = await showPlayerPopover<AudioTrack>(
      context: context,
      anchor: _settingsAnchor,
      width: playerMenuWidth(
        context,
        current.player.state.tracks.audio.take(20).map(_audioTrackLabel),
      ).clamp(PlayerTheme.menuMinWidth, PlayerTheme.audioMenuMaxWidth),
      builder: (c) => AnimatedBuilder(
        animation: current,
        builder: (_, _) {
          final tracks = current.player.state.tracks.audio;
          return PlayerMenuList(
            key: const ValueKey('player-audio-popup'),
            selectedIndex:
                tracks.indexWhere(
                  (track) => track.id == current.player.state.track.audio.id,
                ) +
                1,
            itemExtent: PlayerTheme.choiceExtent(c),
            padding: PlayerTheme.choiceMenuPadding,
            itemCount: tracks.isEmpty ? 2 : tracks.length + 1,
            itemBuilder: (_, index) {
              if (index == 0) {
                return PlayerChoiceTile(
                  title: Text(
                    '音轨',
                    style: PlayerTheme.of(context).selectedLabelStyle,
                  ),
                );
              }
              if (tracks.isEmpty) {
                return const PlayerChoiceTile(title: Text('暂无可用音轨'));
              }
              final track = tracks[index - 1];
              return _trackRow(
                _audioTrackLabel(track),
                maxLines: 1,
                selected: current.player.state.track.audio.id == track.id,
                onTap: () => Navigator.pop(c, track),
              );
            },
          );
        },
      ),
    );
    if (selected == null ||
        !mounted ||
        current.closed ||
        !identical(current, session)) {
      return;
    }
    try {
      await current.player.setAudioTrack(selected);
    } catch (error) {
      if (mounted) showFailure(context, error);
    }
  }

  Future<void> playbackSpeed() async {
    final current = session;
    const rates = [.25, .5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];
    final rate = await showPlayerPopover<double>(
      context: context,
      anchor: _speedAnchor,
      width: PlayerTheme.speedMenuWidth,
      builder: (c) => PlayerMenuList(
        key: const ValueKey('player-speed-popup'),
        selectedIndex: rates.indexOf(current.player.state.rate) + 1,
        itemExtent: PlayerTheme.choiceExtent(c),
        padding: PlayerTheme.choiceMenuPadding,
        itemCount: rates.length + 1,
        itemBuilder: (_, index) {
          if (index == 0) {
            return PlayerChoiceTile(
              title: Text(
                '播放速度',
                style: PlayerTheme.of(context).selectedLabelStyle,
              ),
            );
          }
          final value = rates[index - 1];
          return _trackRow(
            '$value×',
            maxLines: 1,
            selected: current.player.state.rate == value,
            onTap: () => Navigator.pop(c, value),
          );
        },
      ),
    );
    if (rate != null &&
        mounted &&
        !current.closed &&
        identical(current, session)) {
      await current.updateSettings({'playbackRate': rate});
    }
  }

  Future<void> danmakuPanel() async {
    final d = session.danmaku;
    if (d == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中填写弹幕服务 Token，然后重新打开视频。')),
      );
      return;
    }
    await showModalBottomSheet(
      context: PlayerTheme.routeContext(context),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: PlayerTheme.of(context).barrierColor,
      builder: (c) => _playerSurface(
        PlayerSheet(
          child: PlayerDanmakuPanel(session: session, danmaku: d),
        ),
      ),
    );
  }

  Future<void> quickSettings() async {
    final action = await showPlayerSettingsMenu<String>(
      context: context,
      builder: (c) {
        final entries = [
          _OptionRow(
            icon: Icons.audiotrack_rounded,
            label: '音轨',
            value: _audioTrackLabel(session.player.state.track.audio),
            onTap: () => Navigator.pop(c, 'audio'),
          ),
          _OptionRow(
            icon: Icons.subtitles_outlined,
            label: '字幕',
            onTap: () => Navigator.pop(c, 'subtitle'),
          ),
          _OptionRow(
            icon: Icons.chat_bubble_outline_rounded,
            label: '弹幕',
            onTap: () => Navigator.pop(c, 'danmaku'),
          ),
          const Divider(height: 12),
          _OptionRow(
            icon: Icons.tune_rounded,
            label: '高级选项',
            onTap: () => Navigator.pop(c, 'advanced'),
          ),
        ];
        return PlayerMenuList(
          key: const ValueKey('player-settings-popup'),
          padding: PlayerTheme.choiceMenuPadding,
          itemCount: entries.length,
          itemBuilder: (_, index) => entries[index],
        );
      },
    );
    if (!mounted || session.closed) return;
    switch (action) {
      case 'audio':
        await tracks(true);
      case 'subtitle':
        await tracks(false);
      case 'danmaku':
        await danmakuPanel();
      case 'advanced':
        await advancedSettings();
    }
  }

  Future<void> advancedSettings() async {
    final action = await showModalBottomSheet<String>(
      context: PlayerTheme.routeContext(context),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: PlayerTheme.of(context).barrierColor,
      builder: (c) => _playerSurface(
        PlayerSheet(
          child: PlayerQuickSettings(
            session: session,
            onDanmaku: () => Navigator.pop(c, 'danmaku'),
            onDiagnostics: () => Navigator.pop(c, 'diagnostics'),
          ),
        ),
      ),
    );
    if (!mounted || session.closed) return;
    switch (action) {
      case 'danmaku':
        await danmakuPanel();
      case 'diagnostics':
        await diagnostics();
    }
  }

  Future<void> diagnostics() async {
    await session.refreshDiagnostics();
    if (!mounted) return;
    await showDialog(
      context: PlayerTheme.routeContext(context),
      barrierColor: PlayerTheme.of(context).barrierColor,
      builder: (c) => _playerSurface(
        StatefulBuilder(
          builder: (c, set) => PlayerDialog(
            title: const Text('播放诊断'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.decoder),
                const SizedBox(height: 12),
                Text(
                  '位置 ${clockText(session.player.state.position)} / ${clockText(session.player.state.duration)}',
                ),
                if (session.notice.isNotEmpty) Text(session.notice),
                SwitchListTile(
                  title: const Text('强制软件解码'),
                  value: session.software,
                  onChanged: (value) async {
                    try {
                      await session.setSoftware(value);
                      if (c.mounted) set(() {});
                    } catch (e) {
                      if (c.mounted) showFailure(c, e);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _playerSurface(
    PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) leave();
      },
      child: Scaffold(
        backgroundColor: PlayerTheme.of(context).videoBackground,
        body: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              key: ValueKey(session),
              child: IgnorePointer(child: _videoSurface),
            ),
            if (_retiringSurface != null)
              RepaintBoundary(
                key: ValueKey<PlaybackSession>(_retiringSession!),
                child: IgnorePointer(child: _retiringSurface!),
              ),
            if (!_framePresented && _retiringSurface == null)
              if (widget.model.thumbnailPath(session.media.id) case final path?)
                Positioned.fill(
                  key: const ValueKey('player-opening-cover'),
                  child: IgnorePointer(
                    child: MediaArtwork(
                      thumbnail: path,
                      fit: switch (widget.model.preferences.videoFit) {
                        'cover' => BoxFit.cover,
                        'fill' => BoxFit.fill,
                        _ => BoxFit.contain,
                      },
                      placeholder: const SizedBox.shrink(),
                    ),
                  ),
                ),
            if (_retiringSurface == null &&
                widget.model.thumbnailPath(session.media.id) == null &&
                PlayerDisplay.supported &&
                _nativeFullscreen &&
                (_fullscreenLandscape == null ||
                    (_waitingForOrientation &&
                        (MediaQuery.sizeOf(context).width >=
                                MediaQuery.sizeOf(context).height) !=
                            _fullscreenLandscape)))
              Positioned.fill(
                key: const ValueKey('player-viewport-transition'),
                child: ColoredBox(
                  color: PlayerTheme.of(context).videoBackground,
                ),
              ),
            Positioned.fill(
              key: const ValueKey('player-controls-layer'),
              child: RepaintBoundary(
                child: _PlayerControls(
                  key: ValueKey(session),
                  session: session,
                  fullscreen: _nativeFullscreen,
                  onEnterNativeFullscreen: _enterFullscreen,
                  onOrientFullscreen: _orientFullscreen,
                  title: widget.model.displayTitle(
                    widget.model.store.get('media', session.media.id) ??
                        session.media,
                  ),
                  onBack: leave,
                  onAudio: () => tracks(true),
                  onSubtitle: () => tracks(false),
                  onDanmaku: danmakuPanel,
                  onDiagnostics: diagnostics,
                  onSettings: quickSettings,
                  settingsAnchor: _settingsAnchor,
                  onSpeed: playbackSpeed,
                  speedAnchor: _speedAnchor,
                  onSelectMedia: selectMedia,
                  onExitNativeFullscreen: _exitFullscreen,
                  display: display,
                  windowMode: windowMode,
                  model: widget.model,
                ),
              ),
            ),
            if (session.error.isNotEmpty)
              Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 76, 16, 0),
                    child: PlayerGlass(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Text(session.error),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _PlayerControls extends StatefulWidget {
  final PlaybackSession session;
  final String title;
  final AppModel model;
  final bool fullscreen;
  final Future<void> Function() onBack,
      onAudio,
      onSubtitle,
      onDanmaku,
      onDiagnostics,
      onEnterNativeFullscreen,
      onExitNativeFullscreen;
  final Future<void> Function() onSettings, onSpeed;
  final GlobalKey settingsAnchor, speedAnchor;
  final Future<void> Function(SyncRecord) onSelectMedia;
  final Future<void> Function(String) onOrientFullscreen;
  final PlayerDisplay display;
  final PlayerWindowMode windowMode;
  const _PlayerControls({
    super.key,
    required this.session,
    required this.fullscreen,
    required this.onEnterNativeFullscreen,
    required this.onOrientFullscreen,
    required this.title,
    required this.model,
    required this.onBack,
    required this.onAudio,
    required this.onSubtitle,
    required this.onDanmaku,
    required this.onDiagnostics,
    required this.onSettings,
    required this.settingsAnchor,
    required this.onSpeed,
    required this.speedAnchor,
    required this.onSelectMedia,
    required this.onExitNativeFullscreen,
    required this.display,
    required this.windowMode,
  });
  @override
  State<_PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<_PlayerControls>
    with WidgetsBindingObserver {
  bool show = true, locked = false;
  DesktopPlaybackControls? _windowControls;
  final tapIntent = PlaybackTapIntent();
  SeekPreviewController? seekPreview;
  late final seekTimeline = PlaybackSeekTimeline(
    position: s.position,
    seek: (target) => s.seek(target),
  );
  late final _timelineChanges = Listenable.merge([s.position, seekTimeline]);
  late final _feedbackChanges = Listenable.merge([_hud, seekTimeline]);
  Timer? hudTimer;
  late final hideTimer = PlaybackControlsTimer(() {
    if (mounted &&
        show &&
        ModalRoute.of(context)?.isCurrent == true &&
        heldRate == null) {
      setState(_hideControls);
    }
  });
  bool _closing = false, _rotating = false, _preparingPip = false;
  final _playlistAnchor = GlobalKey();
  final Map<int, Offset> _touches = {};
  int? _mousePointer;
  double? _pinchDistance;
  bool _pinching = false;
  bool _suppressSurfaceTap = false;
  Timer? _surfaceTapTimer;
  int _surfaceTapCount = 0;
  bool _surfaceTapTracking = false;
  bool _singleTapShowsControls = true;
  Offset _surfaceTapPosition = Offset.zero;
  Offset _surfaceTapGlobalPosition = Offset.zero;
  DateTime? _lastPointerReveal;
  final _hud = ValueNotifier<(String, IconData)?>(null);
  double? heldRate;
  double? get dragging => seekTimeline.dragging
      ? seekTimeline.target?.inMilliseconds.toDouble()
      : null;
  double gestureStart = 0,
      gestureDelta = 0,
      levelStart = 0,
      brightness = .5,
      lastVolume = 100;
  bool? brightnessGesture;
  bool get mobile => Platform.isAndroid || Platform.isIOS;
  PlaybackSession get s => widget.session;
  bool get _controlsCanAutoHide =>
      s.ready &&
      s.firstFrameRendered &&
      s.player.state.playing &&
      !s.player.state.buffering;
  Object? _controlsState;
  Object get _visibleSessionState => (
    s.closed,
    s.ready,
    s.firstFrameRendered,
    s.error,
    s.player.state.playing,
    s.player.state.buffering,
    s.player.state.duration,
    s.player.state.volume,
    s.player.state.rate,
  );
  @override
  void initState() {
    super.initState();
    s.addListener(update);
    FocusManager.instance.addEarlyKeyEventHandler(_keyEvent);
    if (!mobile) {
      _windowControls = DesktopWindow.beginPlaybackControls();
      GestureBinding.instance.pointerRouter.addGlobalRoute(_desktopPointer);
    }
    widget.display.orientation.addListener(_gravityChanged);
    WidgetsBinding.instance.addObserver(this);
    widget.display.readBrightness().then((value) {
      if (mounted) brightness = value;
    });
    final location = widget.model.store.local('location:${s.media.id}');
    if (location != null) {
      seekPreview = SeekPreviewController(
        openSource: () => widget.model.adapter('${location['source']}'),
        path: '${location['path']}',
      );
    }
    reveal();
    _controlsState = _visibleSessionState;
    _maybeAutoFullscreen();
  }

  @override
  void didUpdateWidget(_PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configureControls();
  }

  void _configureControls() {
    hideTimer.configure(
      playing: show && _controlsCanAutoHide,
      seconds: widget.model.preferences.controlsHideSeconds,
    );
    _maybeAutoFullscreen();
  }

  void update() {
    _configureControls();
    final next = _visibleSessionState;
    if (next == _controlsState) return;
    _controlsState = next;
    // Subtitle preparation and danmaku matching notify their own layers. They
    // must not rebuild the whole toolbar while work is progressing.
    if (mounted) setState(() {});
  }

  void _maybeAutoFullscreen() {
    if (!mobile ||
        !s.ready ||
        widget.windowMode.active ||
        s.closed ||
        s.autoFullscreenAttempted ||
        !widget.model.preferences.enterFullscreen) {
      return;
    }
    s.autoFullscreenAttempted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !s.closed && !widget.fullscreen) {
        widget.onEnterNativeFullscreen();
      }
    });
  }

  Future<T?> _panel<T>(
    Future<T?> Function() open, {
    bool revealControls = true,
  }) async {
    _cancelSurfaceTaps();
    hideTimer.hold();
    if (mounted && revealControls) setState(() => _setControlsVisible(true));
    try {
      return await open();
    } finally {
      hideTimer.release();
      if (mounted && !s.closed && revealControls) setState(reveal);
    }
  }

  Future<void> _settings({bool revealControls = true}) async {
    await _panel<void>(() async {
      if (revealControls && widget.settingsAnchor.currentContext == null) {
        // Pointer actions may reveal controls before opening a menu. Let
        // their anchors mount; the keyboard menu has its own fixed position.
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || s.closed) return;
        await Future<void>.delayed(
          MotionScope.duration(
            context,
            PlayerTheme.controlsEntranceMilliseconds,
          ),
        );
        await WidgetsBinding.instance.endOfFrame;
      }
      if (mounted && !s.closed) await widget.onSettings();
    }, revealControls: revealControls);
  }

  void _lock() {
    _cancelSurfaceTaps();
    _releaseSpeed();
    setState(() {
      locked = !locked;
      reveal();
    });
  }

  Future<void> _pip() async {
    if (_preparingPip || s.closed) return;
    var heldControls = false;
    try {
      if (widget.windowMode.active) {
        await widget.windowMode.exit();
        return;
      }
      if (!widget.windowMode.systemPip) await _exitFull();
      if (!mounted || s.closed) return;
      final params = s.player.state.videoParams;
      final ratio =
          videoAspectRatio(
            width: params.dw ?? params.w,
            height: params.dh ?? params.h,
            rotation: params.rotate ?? 0,
          ) ??
          16 / 9;
      final surface = context.findRenderObject();
      Rect? sourceRect;
      if (surface is RenderBox && surface.hasSize) {
        final bounds = surface.localToGlobal(Offset.zero) & surface.size;
        sourceRect = bounds;
        if (widget.model.preferences.videoFit == 'contain') {
          final fitted = applyBoxFit(
            BoxFit.contain,
            Size(ratio, 1),
            bounds.size,
          ).destination;
          sourceRect = Alignment.center.inscribe(fitted, bounds);
        }
      }
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      final entering = s;
      final pauseRevision = entering.backgroundPauseRevision;
      _cancelSurfaceTaps();
      hideTimer.hold();
      heldControls = true;
      if (widget.windowMode.systemPip) {
        setState(() => _preparingPip = true);
        // Compose the retained video without controls before Android snapshots
        // the activity for its PiP transition. Background policy is synchronous.
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted ||
          entering.closed ||
          entering != s ||
          entering.backgroundPauseRevision != pauseRevision ||
          playbackIsBackgrounded(WidgetsBinding.instance.lifecycleState)) {
        return;
      }
      await widget.windowMode.enter(
        aspectRatio: ratio,
        sourceRect: sourceRect,
        pixelRatio: pixelRatio,
      );
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (heldControls) hideTimer.release();
      if (mounted) setState(() => _preparingPip = false);
    }
  }

  Future<void> _exitFull() async {
    if (widget.fullscreen) await widget.onExitNativeFullscreen();
  }

  Future<void> _toggleFull() async {
    if (widget.fullscreen) {
      await _exitFull();
    } else {
      await widget.onEnterNativeFullscreen();
    }
  }

  Future<void> _back() async {
    if (_closing) return;
    _cancelSurfaceTaps();
    _closing = true;
    hideTimer.cancel();
    if (!s.closed) await widget.onBack();
  }

  Future<void> _gravityChanged() async {
    if (!mounted ||
        s.closed ||
        widget.windowMode.active ||
        locked ||
        _rotating ||
        !widget.model.preferences.autoRotateFullscreen ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final direction = widget.display.orientation.value;
    final params = s.player.state.videoParams;
    if (direction == null ||
        (videoIsLandscape(
                  width: params.dw ?? params.w,
                  height: params.dh ?? params.h,
                  rotation: params.rotate ?? 0,
                ) ??
                _cachedVideoIsLandscape(widget.model, s.media)) ==
            false) {
      return;
    }
    _rotating = true;
    try {
      if (direction.startsWith('landscape')) {
        if (!widget.fullscreen) await widget.onEnterNativeFullscreen();
        if (!mounted || s.closed || _closing) return;
        await widget.onOrientFullscreen(direction);
      }
      // Upright device gravity must not collapse landscape playback to a
      // portrait page. Portrait fullscreen is selected by the video's shape.
    } finally {
      _rotating = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _releaseSpeed(feedback: false);
      brightnessGesture = null;
      _finishSeek(commit: false);
      _cancelSurfaceTaps();
    } else {
      widget.display.readBrightness().then((value) {
        if (mounted) brightness = value;
      });
    }
  }

  void _feedback(String value, IconData icon, {bool persistent = false}) {
    if (!mounted || s.closed) return;
    hudTimer?.cancel();
    _hud.value = (value, icon);
    if (!persistent) {
      hudTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) _hud.value = null;
      });
    }
  }

  void _releaseSpeed({bool feedback = true}) {
    final previous = heldRate;
    heldRate = null;
    if (!feedback) {
      hudTimer?.cancel();
      _hud.value = null;
    }
    if (previous == null || s.closed) return;
    unawaited(s.temporaryRate(previous));
    if (feedback) _feedback('$previous×', Icons.speed_rounded);
  }

  void _endVertical({bool cancel = false}) {
    final kind = brightnessGesture;
    brightnessGesture = null;
    if (kind == null || s.closed) return;
    final value = cancel
        ? levelStart
        : gestureLevel(
            start: levelStart,
            deltaY: gestureDelta,
            height: context.size?.height ?? 1,
          );
    if (kind) {
      if (cancel) {
        brightness = value;
        widget.display.setBrightness(value);
      }
    } else {
      s.player.setVolume(value * 100);
      if (!cancel) s.updateSettings({'volume': value * 100});
    }
    if (mounted) setState(reveal);
  }

  void _action(String action, {bool revealControls = true}) {
    if (s.closed) return;
    final p = widget.model.preferences;
    switch (action) {
      case 'playPause':
      case 'playPauseAlternate':
        unawaited(s.togglePlayback());
      case 'seekBackward':
      case 'seekForward':
      case 'skipBackward':
      case 'skipForward':
        if (s.player.state.duration <= Duration.zero) {
          _feedback('当前视频暂不支持跳转', Icons.info_outline_rounded);
          return;
        }
        final backwards = action == 'seekBackward' || action == 'skipBackward';
        final seconds = action.startsWith('skip') ? 89 : p.seekStepSeconds;
        seekBy(backwards ? -seconds : seconds);
        _feedback(
          '${backwards ? '-' : '+'}$seconds 秒',
          backwards ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
        );
      case 'volumeUp':
      case 'volumeDown':
        final value = (s.player.state.volume + (action == 'volumeUp' ? 5 : -5))
            .clamp(0.0, 100.0);
        s.updateSettings({'volume': value});
        _feedback('音量 ${value.round()}%', Icons.volume_up_rounded);
      case 'mute':
        final current = s.player.state.volume;
        if (current > 0) lastVolume = current;
        final value = current > 0 ? 0.0 : lastVolume;
        s.updateSettings({'volume': value});
        _feedback(
          value == 0 ? '静音' : '音量 ${value.round()}%',
          value == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        );
      case 'fullscreen':
        _toggleFull();
      case 'exitFullscreen':
        if (widget.fullscreen) {
          _exitFull();
        } else {
          _back();
        }
      case 'subtitles':
        s.updateSettings({'subtitlesEnabled': !p.subtitlesEnabled});
        _feedback(
          p.subtitlesEnabled ? '字幕关闭' : '字幕开启',
          Icons.subtitles_outlined,
        );
      case 'danmaku':
        s.updateSettings({'danmuVisible': !p.danmuVisible});
        _feedback(
          p.danmuVisible ? '弹幕关闭' : '弹幕开启',
          Icons.chat_bubble_outline_rounded,
        );
      case 'settings':
        _settings(revealControls: revealControls);
    }
    if (mounted && revealControls) {
      setState(reveal);
    } else if (show) {
      // Keyboard actions keep the current visibility. If controls were
      // already visible, give that interaction a fresh auto-hide interval.
      hideTimer.arm();
    }
  }

  int get _maximumSurfaceTaps {
    final p = widget.model.preferences;
    if (!mobile || !p.gesturesEnabled || locked || s.closed) return 1;
    if (p.hasTripleTapAction) return 3;
    return p.doubleTapAction != 'none' || p.edgeDoubleTapSeek ? 2 : 1;
  }

  void _cancelSurfaceTaps({bool rebuild = true}) {
    _surfaceTapTimer?.cancel();
    _surfaceTapTimer = null;
    _surfaceTapCount = 0;
    final tracked = _surfaceTapTracking;
    _surfaceTapTracking = false;
    tapIntent.cancel();
    if (tracked && rebuild && mounted) setState(() {});
  }

  void _surfaceTapDown(SerialTapDownDetails details) {
    // A tap elsewhere starts another series. Finish the previous valid tap
    // before the outer pointer listener captures the new visibility intent.
    if (details.count == 1 || _surfaceTapCount == 0) _finishSurfaceTaps();
    _surfaceTapTimer?.cancel();
    _surfaceTapTimer = null;
    if (_maximumSurfaceTaps > 1 && mounted) {
      setState(() {
        _surfaceTapTracking = true;
        _surfaceTapGlobalPosition = details.globalPosition;
      });
    }
  }

  void _surfaceTapUp(SerialTapUpDetails details) {
    if (_suppressSurfaceTap || _pinching || s.closed || _closing) {
      _cancelSurfaceTaps();
      return;
    }
    final maximum = _maximumSurfaceTaps;
    // Controls can cancel our sequence without resetting the recognizer's
    // history. Count only taps since our last action or explicit cancellation.
    _surfaceTapCount++;
    _surfaceTapPosition = details.localPosition;
    if (_surfaceTapCount == 1) {
      _singleTapShowsControls = tapIntent.resolve(visible: show);
    } else {
      tapIntent.cancel();
    }
    _surfaceTapTimer?.cancel();
    if (_surfaceTapCount == maximum) {
      _finishSurfaceTaps();
    } else {
      // Wait to distinguish double from triple taps. Only the final action
      // runs; a triple tap must never pause first and then jump.
      _surfaceTapTimer = Timer(kDoubleTapTimeout, _finishSurfaceTaps);
    }
  }

  void _finishSurfaceTaps() {
    _surfaceTapTimer?.cancel();
    _surfaceTapTimer = null;
    final count = _surfaceTapCount;
    _surfaceTapCount = 0;
    if (_surfaceTapTracking && mounted) {
      setState(() => _surfaceTapTracking = false);
    }
    if (count == 0 || !mounted || s.closed || _closing || _suppressSurfaceTap) {
      return;
    }
    if (count == 1) {
      setState(() {
        if (_singleTapShowsControls) {
          reveal();
        } else {
          _hideControls();
        }
      });
      return;
    }
    if (_maximumSurfaceTaps == 1) return;
    final p = widget.model.preferences;
    final width = context.size?.width ?? 1;
    var action = count == 3
        ? switch (playbackTapRegion(
            localX: _surfaceTapPosition.dx,
            width: width,
          )) {
            PlaybackTapRegion.left => p.tripleTapLeftAction,
            PlaybackTapRegion.center => p.tripleTapAction,
            PlaybackTapRegion.right => p.tripleTapRightAction,
          }
        : p.doubleTapAction;
    final edge =
        _surfaceTapPosition.dx < width * .3 ||
        _surfaceTapPosition.dx > width * .7;
    if (count == 2 && p.edgeDoubleTapSeek && edge) action = 'seek';
    if (action == 'seek') {
      _action(
        _surfaceTapPosition.dx < width / 2 ? 'seekBackward' : 'seekForward',
      );
    } else if (action == 'skipForward' ||
        action == 'skipBackward' ||
        action == 'seekTo') {
      if (s.player.state.duration <= Duration.zero) {
        _feedback('当前视频暂不支持跳转', Icons.info_outline_rounded);
        return;
      }
      final seconds = p.gestureSeekSeconds;
      final backwards = action == 'skipBackward';
      if (action == 'seekTo') {
        final target = Duration(
          milliseconds: (seconds * 1000).clamp(
            0,
            s.player.state.duration.inMilliseconds,
          ),
        );
        unawaited(s.seek(target));
        _feedback('跳到 ${clockText(target)}', Icons.skip_next_rounded);
      } else {
        seekBy(backwards ? -seconds : seconds);
        _feedback(
          '${backwards ? '后退' : '前进'} ${clockText(Duration(seconds: seconds))}',
          backwards ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
        );
      }
      setState(reveal);
    } else if (action != 'none') {
      _action(action);
    }
  }

  void _pointerActivity(PointerEvent event) {
    if (event.kind != ui.PointerDeviceKind.mouse ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    // Native drag/focus changes may consume mouse-up. A hover proves that no
    // mouse button is held; stale touch bookkeeping must not disable hover.
    if (event.buttons == 0 && _mousePointer != null) {
      if (_touches.remove(_mousePointer) != null) hideTimer.release();
      _mousePointer = null;
    }
    final now = DateTime.now();
    if (show &&
        _lastPointerReveal != null &&
        now.difference(_lastPointerReveal!) <
            const Duration(milliseconds: 100)) {
      return;
    }
    _lastPointerReveal = now;
    if (show) {
      reveal();
    } else {
      tapIntent.hoverRevealed();
      setState(reveal);
    }
  }

  void _desktopPointer(PointerEvent event) {
    if (!mounted ||
        s.closed ||
        _closing ||
        (event is! PointerHoverEvent && event is! PointerMoveEvent)) {
      return;
    }
    // Receive movement even while fullscreen transitions or disappearing
    // controls change the hit-test path beneath the mouse.
    final box = context.findRenderObject();
    if (box is! RenderBox ||
        !box.hasSize ||
        !(Offset.zero & box.size).contains(box.globalToLocal(event.position))) {
      return;
    }
    _pointerActivity(event);
  }

  KeyEventResult _keyEvent(KeyEvent event) {
    if (!mounted ||
        s.closed ||
        _closing ||
        ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus?.widget is EditableText ||
        focus?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    // Handle player keys before a focused slider or button consumes arrows
    // and Space. Modal routes and text fields retain their own keyboard input.
    if (!mobile &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      // Escape remains available when shortcuts are disabled or controls are
      // locked. Holding it must not close playback after leaving fullscreen.
      if (event is KeyDownEvent) {
        unawaited(widget.fullscreen ? _exitFull() : _back());
      }
      return KeyEventResult.handled;
    }
    final p = widget.model.preferences;
    if (!p.keyboardEnabled || locked) return KeyEventResult.ignored;
    final action = shortcutAction(event, p.shortcuts);
    if (action == null) {
      // Suppressed toggle repeats must not fall through to a focused button's
      // default Space/Enter activation (which accepts repeats).
      if (event is KeyRepeatEvent &&
          shortcutAction(event, p.shortcuts, respectRepeatPolicy: false) !=
              null) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    _action(action, revealControls: false);
    return KeyEventResult.handled;
  }

  void _setControlsVisible(bool visible) {
    show = visible;
    _windowControls?.setVisible(visible && !locked);
  }

  void _hideControls() {
    _setControlsVisible(false);
    hideTimer.configure(
      playing: false,
      seconds: widget.model.preferences.controlsHideSeconds,
    );
  }

  void reveal() {
    _setControlsVisible(true);
    hideTimer.configure(
      playing: _controlsCanAutoHide,
      seconds: widget.model.preferences.controlsHideSeconds,
    );
    hideTimer.arm();
  }

  Widget _interactive(Widget child, {bool timeline = false}) => _TapPassthrough(
    // Controls revealed by the first surface tap must not intercept the
    // second/third tap at that same location (especially the central button).
    center: mobile && _surfaceTapTracking ? _surfaceTapGlobalPosition : null,
    child: Listener(
      onPointerDown: (_) {
        _cancelSurfaceTaps();
        hideTimer.hold();
      },
      onPointerUp: (_) {
        hideTimer.release();
        // Release is authoritative even if a rebuild or system interruption
        // prevents Slider's recognizer from delivering its end callback.
        if (timeline) _finishSeek();
      },
      onPointerCancel: (_) {
        hideTimer.release();
        if (timeline) _finishSeek(commit: false);
      },
      child: child,
    ),
  );

  void _finishSeek({double? target, bool commit = true}) {
    if (!seekTimeline.dragging) return;
    if (target != null) {
      seekTimeline.update(Duration(milliseconds: target.round()));
    }
    seekPreview?.end();
    seekTimeline.finish(
      commit: commit && !s.closed && s.player.state.duration > Duration.zero,
    );
    if (mounted) {
      if (show) {
        reveal();
      } else {
        setState(reveal);
      }
    }
  }

  void _beginSeek(double value) {
    if (s.closed) return;
    hideTimer.cancel();
    final target = Duration(milliseconds: value.round());
    seekTimeline.begin(target);
    seekPreview?.request(target);
  }

  void _updateSeek(double value) {
    if (s.closed || !seekTimeline.dragging) return;
    final target = Duration(milliseconds: value.round());
    seekTimeline.update(target);
    seekPreview?.request(target);
  }

  void seekBy(int seconds) {
    if (s.closed || s.player.state.duration <= Duration.zero) return;
    s.seek(
      Duration(
        milliseconds: (s.player.state.position.inMilliseconds + seconds * 1000)
            .clamp(0, s.player.state.duration.inMilliseconds),
      ),
    );
  }

  @override
  void dispose() {
    _cancelSurfaceTaps(rebuild: false);
    FocusManager.instance.removeEarlyKeyEventHandler(_keyEvent);
    if (!mobile) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_desktopPointer);
    }
    _windowControls?.dispose();
    hideTimer.dispose();
    final preview = seekPreview;
    if (preview != null) PlayerPage._trackDisposal(preview.close());
    seekTimeline.dispose();
    hudTimer?.cancel();
    widget.display.orientation.removeListener(_gravityChanged);
    _releaseSpeed(feedback: false);
    _hud.dispose();
    WidgetsBinding.instance.removeObserver(this);
    s.removeListener(update);
    super.dispose();
  }

  Widget _seekPreviewCard(Size viewport) {
    final target = Duration(milliseconds: dragging!.round());
    final width = (viewport.width * .25).clamp(140.0, 260.0);
    final controller = seekPreview;
    Widget unavailable() => ColoredBox(
      key: ValueKey('seek-preview-unavailable'),
      color: PlayerTheme.of(context).previewPlaceholderColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              color: PlayerTheme.of(context).mutedForeground,
            ),
            SizedBox(height: 6),
            Text('预览暂不可用', style: PlayerTheme.of(context).captionStyle),
          ],
        ),
      ),
    );
    Widget card(SeekPreviewFrame? frame) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerSeekReadout(
            key: const ValueKey('seek-preview-readout'),
            time: clockText(target),
            target: target,
            origin: seekTimeline.origin,
            maxWidth: (viewport.width * .75).clamp(140.0, 420.0),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(
              PlayerTheme.of(context).controlRadius,
            ),
            child: SizedBox(
              key: const ValueKey('seek-preview-frame'),
              width: width,
              height: width * 9 / 16,
              child: frame != null
                  ? Image.memory(
                      frame.bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      frameBuilder:
                          (_, child, frameNumber, synchronouslyLoaded) =>
                              synchronouslyLoaded || frameNumber != null
                              ? child
                              : ColoredBox(
                                  color: PlayerTheme.of(
                                    context,
                                  ).previewLoadingColor,
                                ),
                      errorBuilder: (_, _, _) => unavailable(),
                    )
                  : controller?.status == SeekPreviewStatus.loading
                  ? ColoredBox(
                      color: PlayerTheme.of(context).previewPlaceholderColor,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: PlayerTheme.of(context).mutedForeground,
                          ),
                        ),
                      ),
                    )
                  : unavailable(),
            ),
          ),
        ],
      );
    }

    if (controller == null) return card(null);
    return ValueListenableBuilder<SeekPreviewFrame?>(
      valueListenable: controller,
      builder: (_, frame, _) => card(frame),
    );
  }

  Widget _timeline(double duration) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _timelineChanges,
      builder: (context, _) {
        final milliseconds = seekTimeline.displayed.inMilliseconds
            .toDouble()
            .clamp(0.0, duration > 0 ? duration : 1.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: PlayerTheme.of(context).timelineSliderTheme,
              child: SizedBox(
                height: 28,
                child: Slider(
                  key: const ValueKey('player-timeline'),
                  semanticFormatterCallback: (v) =>
                      clockText(Duration(milliseconds: v.round())),
                  value: milliseconds,
                  max: duration > 0 ? duration : 1,
                  onChangeStart: _beginSeek,
                  onChanged: duration > 0 && !s.closed ? _updateSeek : null,
                  onChangeEnd: (v) {
                    _finishSeek(target: v);
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(clockText(Duration(milliseconds: milliseconds.round()))),
                  const Spacer(),
                  Text(
                    '-${clockText(s.player.state.duration - Duration(milliseconds: milliseconds.round()))}',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );

  List<SyncRecord> get _playlist => playbackPlaylist(widget.model, s.media);

  Future<void> _playMedia(SyncRecord media) async {
    if (media.id == s.media.id || _closing) return;
    _closing = true;
    try {
      await widget.onSelectMedia(media);
    } finally {
      if (mounted) _closing = false;
    }
  }

  Future<void> _showPlaylist() async {
    final items = _playlist;
    final titles = <String, String>{};
    String title(SyncRecord media) => titles.putIfAbsent(media.id, () {
      final episode = widget.model.episodeLabel(media);
      return episode.isEmpty ? widget.model.seriesTitle(media) : episode;
    });
    // Opening a long series must not query and measure every episode. Include
    // the current title in a bounded sample, then resolve other visible rows.
    final widthLabels = [
      for (final media in items.take(20)) title(media),
      title(s.media),
    ];
    final selected = await _panel<SyncRecord>(
      () => showPlayerPopover<SyncRecord>(
        context: context,
        anchor: _playlistAnchor,
        width: playerMenuWidth(context, widthLabels),
        builder: (c) => PlayerMenuList(
          key: const ValueKey('player-playlist-popup'),
          selectedIndex:
              items.indexWhere((media) => media.id == s.media.id) + 1,
          itemExtent: PlayerTheme.choiceExtent(c, twoLines: true),
          padding: PlayerTheme.choiceMenuPadding,
          itemCount: items.length + 1,
          itemBuilder: (_, index) {
            if (index == 0) {
              return PlayerChoiceTile(
                title: Text.rich(
                  TextSpan(
                    text: '播放列表',
                    children: [
                      TextSpan(
                        text: ' · ${items.length} 集',
                        style: PlayerTheme.of(context).mutedStyle,
                      ),
                    ],
                  ),
                  style: PlayerTheme.of(context).selectedLabelStyle,
                ),
              );
            }
            final media = items[index - 1];
            return PlayerChoiceTile(
              trailing: media.id == s.media.id
                  ? Icon(
                      Icons.equalizer_rounded,
                      color: PlayerTheme.of(context).foreground,
                      size: 20,
                      semanticLabel: '正在播放',
                    )
                  : null,
              title: Text(
                title(media),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PlayerTheme.of(
                  context,
                ).playlistItemStyle(selected: media.id == s.media.id),
              ),
              subtitle: _playlistProgress(media),
              selected: media.id == s.media.id,
              onTap: () => Navigator.pop(c, media),
            );
          },
        ),
      ),
    );
    if (selected != null && mounted && !s.closed) await _playMedia(selected);
  }

  Widget? _playlistProgress(SyncRecord media) {
    final progress = widget.model.progressFor(media);
    if (progress == null) return null;
    final position = (progress['position'] as num?)?.toDouble() ?? 0;
    final duration = (progress['duration'] as num?)?.toDouble() ?? 0;
    if (duration <= 0) return null;
    return Text(
      '${clockText(Duration(seconds: position.round()))} / ${clockText(Duration(seconds: duration.round()))} · ${(position / duration * 100).clamp(0, 100).round()}%',
      style: PlayerTheme.of(context).playlistProgressStyle,
    );
  }

  Future<void> _chooseFit() async {
    const fits = ['contain', 'cover', 'fill'];
    final current = fits.indexOf(widget.model.preferences.videoFit);
    final next = fits[(current + 1) % fits.length];
    if (s.closed) return;
    await s.updateSettings({'videoFit': next});
    _feedback(switch (next) {
      'cover' => '裁剪填满',
      'fill' => '拉伸填满',
      _ => '完整显示',
    }, Icons.fit_screen_rounded);
    if (mounted) setState(reveal);
  }

  Widget _touchSurface(Widget child) => Listener(
    onPointerDown: (event) {
      if (_touches.isEmpty) _suppressSurfaceTap = false;
      if (event.kind == ui.PointerDeviceKind.mouse) {
        _mousePointer = event.pointer;
      }
      tapIntent.pointerDown(visible: show);
      hideTimer.hold();
      // Reveal immediately on touch-down. The delayed tap resolves from the
      // captured intent, so it cannot hide the controls it just revealed.
      if (!show && mounted) setState(reveal);
      _touches[event.pointer] = event.localPosition;
      if (_touches.length == 2 &&
          mobile &&
          widget.model.preferences.gesturesEnabled &&
          widget.model.preferences.pinchToZoom &&
          !locked) {
        _pinching = true;
        _suppressSurfaceTap = true;
        _releaseSpeed(feedback: false);
        _endVertical(cancel: true);
        _finishSeek(commit: false);
        _cancelSurfaceTaps();
        final points = _touches.values.toList();
        _pinchDistance = (points[0] - points[1]).distance;
      }
    },
    onPointerMove: (event) {
      _pointerActivity(event);
      if (!_touches.containsKey(event.pointer)) return;
      _touches[event.pointer] = event.localPosition;
      if (!_pinching || _pinchDistance == null || _touches.length != 2) return;
      final points = _touches.values.toList();
      final scale = (points[0] - points[1]).distance / _pinchDistance!;
      if (scale > 1.18 || scale < .84) {
        final fit = scale > 1 ? 'cover' : 'contain';
        if (widget.model.preferences.videoFit != fit) {
          s.updateSettings({'videoFit': fit});
          _feedback(fit == 'cover' ? '填满画面' : '完整画面', Icons.fit_screen_rounded);
        }
      }
    },
    onPointerUp: (event) {
      if (_mousePointer == event.pointer) _mousePointer = null;
      _touches.remove(event.pointer);
      hideTimer.release();
      if (_touches.isEmpty) {
        if (!_pinching) _finishSeek();
        _pinching = false;
        _pinchDistance = null;
      }
    },
    onPointerCancel: (event) {
      if (_mousePointer == event.pointer) _mousePointer = null;
      _cancelSurfaceTaps();
      _touches.remove(event.pointer);
      hideTimer.release();
      if (_touches.isEmpty) {
        _finishSeek(commit: false);
        _pinching = false;
        _pinchDistance = null;
      }
    },
    child: child,
  );

  Widget _volumeCapsule(double value, double width) => _interactive(
    PlayerGlass(
      radius: PlayerTheme.of(context).panelRadius,
      child: SizedBox(
        width: width,
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 12),
            SizedBox(
              width: 29,
              child: Text(
                '${value.round()}%',
                style: PlayerTheme.of(context).volumeLabelStyle,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: PlayerTheme.of(context).volumeSliderTheme,
                child: Slider(
                  value: value.clamp(0, 100),
                  max: 100,
                  onChanged: s.player.setVolume,
                  onChangeEnd: (v) => s.updateSettings({'volume': v}),
                ),
              ),
            ),
            _PlayerButton(
              tooltip: value == 0 ? '取消静音' : '静音',
              icon: value == 0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              size: 36,
              iconSize: 18,
              onPressed: () => _action('mute'),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // The page can rebuild once while the close animation is removing it.
    if (s.closed ||
        _preparingPip ||
        (widget.windowMode.active && widget.windowMode.systemPip)) {
      return const SizedBox.expand();
    }
    final st = s.player.state;
    final duration = st.duration.inMilliseconds.toDouble();
    final loading =
        s.error.isEmpty && (!s.ready || !s.firstFrameRendered || st.buffering);
    final p = widget.model.preferences;
    final viewport = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    // Landscape cutouts and navigation bars can occupy only one side. Keep
    // every control group centered using the larger safe inset on both sides.
    final sideInset = math.max(
      (viewport.width * .055).clamp(16.0, 76.0),
      math.max(safePadding.left, safePadding.right) + 16,
    );
    final topInset = (viewport.height * .055).clamp(10.0, 48.0);
    final bottomInset = (viewport.height * .07).clamp(16.0, 60.0);
    final gestures = mobile && p.gesturesEnabled && !locked && !s.closed;
    final seekGesture = gestures && p.horizontalSeek && duration > 0;
    final verticalGestures =
        gestures &&
        (p.verticalVolume || (p.verticalBrightness && PlayerDisplay.supported));
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Focus(
        autofocus: true,
        child: MouseRegion(
          cursor: !mobile && widget.fullscreen && !show
              ? SystemMouseCursors.none
              : SystemMouseCursors.basic,
          // Closing a keyboard-opened panel can synthesize an enter event
          // under a stationary mouse. Only actual movement reveals controls.
          onHover: _pointerActivity,
          child: Stack(
            children: [
              Positioned.fill(
                key: const ValueKey('player-touch-layer'),
                child: _touchSurface(
                  RawGestureDetector(
                    behavior: HitTestBehavior.opaque,
                    gestures: {
                      SerialTapGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                            SerialTapGestureRecognizer
                          >(
                            () => SerialTapGestureRecognizer(debugOwner: this),
                            (recognizer) => recognizer
                              ..onSerialTapDown = _surfaceTapDown
                              ..onSerialTapUp = _surfaceTapUp
                              ..onSerialTapCancel = (_) => _cancelSurfaceTaps(),
                          ),
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: seekGesture
                          ? (_) {
                              final position = s.player.state.position;
                              gestureStart = position.inMilliseconds / 1000;
                              tapIntent.cancel();
                              gestureDelta = 0;
                              _beginSeek(position.inMilliseconds.toDouble());
                            }
                          : null,
                      onHorizontalDragUpdate: seekGesture
                          ? (details) {
                              if (s.closed || _pinching) return;
                              gestureDelta += details.delta.dx;
                              final target =
                                  gestureSeekTarget(
                                    startSeconds: gestureStart,
                                    deltaX: gestureDelta,
                                    width: context.size?.width ?? 1,
                                    durationSeconds: duration / 1000,
                                  ) *
                                  1000;
                              _updateSeek(target);
                            }
                          : null,
                      onHorizontalDragEnd: seekGesture
                          ? (_) => _finishSeek(commit: !_pinching)
                          : null,
                      onHorizontalDragCancel: seekGesture
                          ? () => _finishSeek(commit: false)
                          : null,
                      onVerticalDragStart: verticalGestures
                          ? (details) {
                              final left =
                                  details.localPosition.dx <
                                  (context.size?.width ?? 1) / 2;
                              brightnessGesture =
                                  left &&
                                      p.verticalBrightness &&
                                      PlayerDisplay.supported
                                  ? true
                                  : (!left && p.verticalVolume ? false : null);
                              levelStart = brightnessGesture == true
                                  ? brightness
                                  : st.volume / 100;
                              gestureDelta = 0;
                              hideTimer.cancel();
                            }
                          : null,
                      onVerticalDragUpdate: verticalGestures
                          ? (details) {
                              if (brightnessGesture == null ||
                                  s.closed ||
                                  _pinching) {
                                return;
                              }
                              gestureDelta += details.delta.dy;
                              final level = gestureLevel(
                                start: levelStart,
                                deltaY: gestureDelta,
                                height: context.size?.height ?? 1,
                              );
                              if (brightnessGesture!) {
                                brightness = level;
                                widget.display.setBrightness(level);
                              } else {
                                s.player.setVolume(level * 100);
                              }
                              _feedback(
                                '${brightnessGesture! ? '亮度' : '音量'} ${(level * 100).round()}%',
                                brightnessGesture!
                                    ? Icons.brightness_6_outlined
                                    : Icons.volume_up_rounded,
                              );
                            }
                          : null,
                      onVerticalDragEnd: verticalGestures
                          ? (_) => _endVertical()
                          : null,
                      onVerticalDragCancel: verticalGestures
                          ? () => _endVertical(cancel: true)
                          : null,
                      onLongPressStart: gestures && p.longPressSpeed
                          ? (_) {
                              if (!st.playing || s.closed || _pinching) return;
                              heldRate = st.rate;
                              unawaited(s.temporaryRate(p.longPressRate));
                              hideTimer.cancel();
                              _feedback(
                                '${p.longPressRate}×',
                                Icons.fast_forward_rounded,
                                persistent: true,
                              );
                            }
                          : null,
                      onLongPressEnd: gestures && p.longPressSpeed
                          ? (_) {
                              _releaseSpeed();
                              if (mounted) setState(reveal);
                            }
                          : null,
                      onLongPressCancel: gestures && p.longPressSpeed
                          ? _releaseSpeed
                          : null,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                key: const ValueKey('player-danmaku-layer'),
                child: RepaintBoundary(
                  child: DanmakuOverlay(
                    session: s,
                    fontSize: p.danmuFontSize,
                    opacity: p.danmuOpacity,
                    area: p.danmuArea,
                    density: p.danmuDensity,
                    speed: p.danmuSpeed,
                    scroll: p.danmuScroll,
                    top: p.danmuTop,
                    bottom: p.danmuBottom,
                    presetFilter: p.danmuPresetFilter,
                    blockedWords: p.danmuBlockedWords,
                  ),
                ),
              ),
              // The feedback layer stays in the tree and rebuilds on its own.
              // Inserting/removing it used to remount animated control groups.
              Positioned.fill(
                key: const ValueKey('player-hud-layer'),
                child: IgnorePointer(
                  child: Align(
                    alignment: const Alignment(0, -.3),
                    child: AnimatedBuilder(
                      animation: _feedbackChanges,
                      builder: (context, _) => AnimatedSwitcher(
                        duration: MotionScope.duration(context, 120),
                        child: _hud.value == null || dragging != null
                            ? const SizedBox.shrink()
                            : PlayerGlass(
                                key: const ValueKey('player-hud'),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 14,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(_hud.value!.$2, size: 28),
                                      const SizedBox(width: 12),
                                      Text(_hud.value!.$1),
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                key: const ValueKey('player-shade'),
                child: IgnorePointer(
                  child: _ChromeEntrance(
                    visible: show,
                    child: const _PlayerShade(),
                  ),
                ),
              ),
              Positioned(
                key: const ValueKey('player-lock'),
                right: sideInset,
                top: viewport.height / 2 - 22,
                child: _ChromeEntrance(
                  visible: show,
                  child: _interactive(
                    PlayerGlass(
                      radius: PlayerTheme.of(context).panelRadius,
                      child: _PlayerButton(
                        icon: locked
                            ? Icons.lock_open_rounded
                            : Icons.lock_outline_rounded,
                        tooltip: locked ? '解除锁定' : '锁定控件',
                        onPressed: _lock,
                      ),
                    ),
                  ),
                ),
              ),
              // Scrubbing updates only this layer and the timeline. Keep its
              // slot stable through start, movement, release and buffering so
              // it cannot disturb the controls' entrance/focus/render state.
              Positioned(
                key: const ValueKey('player-seek-preview'),
                left: sideInset,
                bottom: bottomInset + (viewport.height < 420 ? 98 : 130),
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: seekTimeline,
                      builder: (context, _) => dragging != null && !locked
                          ? _seekPreviewCard(viewport)
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              ...[
                Positioned(
                  key: const ValueKey('player-top-controls'),
                  top: topInset,
                  left: sideInset,
                  right: sideInset,
                  child: SafeArea(
                    left: false,
                    right: false,
                    bottom: false,
                    child: _ChromeEntrance(
                      visible: show && !locked,
                      child: Row(
                        children: [
                          _interactive(
                            PlayerGlass(
                              radius: PlayerTheme.of(context).panelRadius,
                              child: _PlayerButton(
                                tooltip: '返回',
                                size: viewport.width < 420 ? 36 : 44,
                                icon: Icons.close_rounded,
                                onPressed: _back,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _interactive(
                            PlayerGlass(
                              radius: PlayerTheme.of(context).panelRadius,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _PlayerButton(
                                    tooltip: '画面适配',
                                    size: viewport.width < 420 ? 36 : 44,
                                    icon: Icons.fit_screen_rounded,
                                    onPressed: _chooseFit,
                                  ),
                                  if (widget.windowMode.supported)
                                    _PlayerButton(
                                      size: viewport.width < 420 ? 36 : 44,
                                      tooltip: widget.windowMode.active
                                          ? '退出小窗'
                                          : '小窗播放',
                                      icon: widget.windowMode.active
                                          ? Icons.open_in_full_rounded
                                          : Icons
                                                .picture_in_picture_alt_rounded,
                                      onPressed: _pip,
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const Spacer(),
                          _interactive(
                            PlayerGlass(
                              radius: PlayerTheme.of(context).panelRadius,
                              child: _PlayerButton(
                                tooltip: '投屏',
                                size: viewport.width < 420 ? 36 : 44,
                                icon: Icons.airplay_rounded,
                                onPressed: () => _panel<void>(
                                  () => showCastSheet(context, s),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _volumeCapsule(
                            st.volume,
                            viewport.width < 420 ? 116 : 210,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  key: const ValueKey('player-transport-controls'),
                  child: IgnorePointer(
                    ignoring: false,
                    child: Center(
                      child: _interactive(
                        _ChromeEntrance(
                          visible: show && !locked,
                          child: Builder(
                            builder: (c) {
                              final items = _playlist;
                              final index = items.indexWhere(
                                (item) => item.id == s.media.id,
                              );
                              final episodes = items.length > 1;
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _PlayerButton(
                                    tooltip: episodes
                                        ? '上一集'
                                        : '后退 ${p.seekStepSeconds} 秒',
                                    icon: episodes
                                        ? Icons.skip_previous_rounded
                                        : Icons.replay_10_rounded,
                                    size: 56,
                                    iconSize: 38,
                                    onPressed: episodes
                                        ? (index > 0
                                              ? () =>
                                                    _playMedia(items[index - 1])
                                              : null)
                                        : () => _action('seekBackward'),
                                  ),
                                  const SizedBox(width: 34),
                                  _PlayerButton(
                                    tooltip: st.playing ? '暂停' : '播放',
                                    icon: loading
                                        ? null
                                        : st.playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    size: 76,
                                    iconSize: 64,
                                    onPressed: () => _action('playPause'),
                                  ),
                                  const SizedBox(width: 34),
                                  _PlayerButton(
                                    tooltip: episodes
                                        ? '下一集'
                                        : '前进 ${p.seekStepSeconds} 秒',
                                    icon: episodes
                                        ? Icons.skip_next_rounded
                                        : Icons.forward_10_rounded,
                                    size: 56,
                                    iconSize: 38,
                                    onPressed: episodes
                                        ? (index >= 0 &&
                                                  index < items.length - 1
                                              ? () =>
                                                    _playMedia(items[index + 1])
                                              : null)
                                        : () => _action('seekForward'),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Keep loading visible even when controls are hidden/locked.
                // A separate stable layer avoids remounting the video surface.
                Positioned.fill(
                  key: const ValueKey('player-buffering-layer'),
                  child: IgnorePointer(
                    child: Center(
                      child: loading
                          ? const PlayerLoading(
                              key: ValueKey('player-buffering'),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                Positioned(
                  key: const ValueKey('player-bottom-controls'),
                  left: sideInset,
                  right: sideInset,
                  bottom: bottomInset,
                  child: SafeArea(
                    left: false,
                    right: false,
                    top: false,
                    child: _ChromeEntrance(
                      visible: show && !locked,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: PlayerTheme.of(context)
                                      .mediaTitleStyle(
                                        compact:
                                            MediaQuery.sizeOf(context).width <
                                            600,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              _interactive(
                                PlayerGlass(
                                  radius: PlayerTheme.of(context).panelRadius,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _PlayerButton(
                                        key: widget.speedAnchor,
                                        tooltip: '播放速度',
                                        icon: Icons.speed_rounded,
                                        onPressed: () =>
                                            _panel<void>(widget.onSpeed),
                                      ),
                                      _PlayerButton(
                                        key: widget.settingsAnchor,
                                        tooltip: '播放器设置',
                                        icon: Icons.tune_rounded,
                                        onPressed: _settings,
                                      ),
                                      _PlayerButton(
                                        tooltip: '弹幕',
                                        icon: Icons.chat_bubble_outline_rounded,
                                        onPressed: () =>
                                            _panel<void>(widget.onDanmaku),
                                      ),
                                      _PlayerButton(
                                        key: _playlistAnchor,
                                        tooltip: '播放列表',
                                        icon:
                                            Icons.format_list_bulleted_rounded,
                                        onPressed: _showPlaylist,
                                      ),
                                      if (!mobile)
                                        _PlayerButton(
                                          tooltip: widget.fullscreen
                                              ? '退出全屏'
                                              : '全屏',
                                          icon: widget.fullscreen
                                              ? Icons.fullscreen_exit_rounded
                                              : Icons.fullscreen_rounded,
                                          onPressed: _toggleFull,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          DefaultTextStyle.merge(
                            style: PlayerTheme.of(context).timelineLabelStyle,
                            child: _interactive(
                              _timeline(duration),
                              timeline: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Keep a tap series on the video surface when the first tap reveals a button
/// underneath it. Controls elsewhere remain immediately usable.
class _TapPassthrough extends SingleChildRenderObjectWidget {
  final Offset? center;
  const _TapPassthrough({required this.center, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTapPassthrough(center);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTapPassthrough renderObject,
  ) {
    renderObject.center = center;
  }
}

class _RenderTapPassthrough extends RenderProxyBox {
  Offset? center;
  _RenderTapPassthrough(this.center);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final point = center;
    if (point != null &&
        (localToGlobal(position) - point).distance <= kDoubleTapSlop) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}

class _ChromeEntrance extends StatefulWidget {
  final Widget child;
  final bool visible;
  const _ChromeEntrance({required this.child, required this.visible});

  @override
  State<_ChromeEntrance> createState() => _ChromeEntranceState();
}

class _ChromeEntranceState extends State<_ChromeEntrance> {
  late bool _retained = widget.visible;

  @override
  void didUpdateWidget(_ChromeEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) _retained = true;
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !widget.visible,
    child: ExcludeFocus(
      excluding: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: AnimatedOpacity(
          opacity: widget.visible ? 1 : 0,
          duration: MotionScope.duration(context, 200),
          curve: Curves.easeOutCubic,
          onEnd: () {
            if (!widget.visible && mounted) setState(() => _retained = false);
          },
          child: AnimatedSlide(
            offset: widget.visible ? Offset.zero : const Offset(0, .035),
            duration: MotionScope.duration(context, 200),
            curve: Curves.easeOutCubic,
            child: _retained
                ? RepaintBoundary(child: widget.child)
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}

class _PlayerButton extends StatelessWidget {
  final String tooltip;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double iconSize, size;
  const _PlayerButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconSize = 22,
    this.size = 44,
  });
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: PlayerTheme.of(context).controlButtonStyle(size),
    icon: icon == null
        ? SizedBox.square(dimension: iconSize)
        : Icon(
            icon,
            size: iconSize,
            shadows: PlayerTheme.of(context).iconShadows,
          ),
  );
}

class _PlayerShade extends StatelessWidget {
  const _PlayerShade();
  @override
  Widget build(BuildContext context) =>
      DecoratedBox(decoration: PlayerTheme.of(context).shadeDecoration);
}

class _OptionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;
  const _OptionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
  });
  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    minTileHeight: PlayerTheme.choiceRowHeight,
    leading: Icon(icon, color: PlayerTheme.of(context).foreground, size: 21),
    title: Text(label, style: PlayerTheme.of(context).optionLabelStyle),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 95),
            child: Text(
              value!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: PlayerTheme.of(context).optionValueStyle,
            ),
          ),
        const SizedBox(width: 4),
        Icon(
          Icons.chevron_right_rounded,
          color: PlayerTheme.of(context).mutedForeground,
          size: 18,
        ),
      ],
    ),
    onTap: onTap,
  );
}
