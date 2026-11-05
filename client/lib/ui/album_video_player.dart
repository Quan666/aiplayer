import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/album_video_controller.dart';
import '../playback/input.dart';
import '../playback/session.dart';
import 'television_input.dart';

/// The surrounding album owns zoom, swipes, chrome and orientation. This
/// surface keeps its cover until the decoder confirms an actual video frame.
class AlbumVideoSurface extends StatefulWidget {
  final AlbumVideoController controller;
  final Widget cover;
  final Color backgroundColor;
  @visibleForTesting
  final Widget Function(PlaybackSession, Color)? videoBuilder;

  const AlbumVideoSurface({
    super.key,
    required this.controller,
    required this.cover,
    this.backgroundColor = Colors.black,
    this.videoBuilder,
  });

  @override
  State<AlbumVideoSurface> createState() => _AlbumVideoSurfaceState();
}

class _AlbumVideoSurfaceState extends State<AlbumVideoSurface> {
  PlaybackSession? _session;
  bool _presented = false, _presenting = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(AlbumVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _changed();
  }

  void _changed() {
    final controller = widget.controller;
    if (_session != controller.session) {
      _session = controller.session;
      _presented = _presenting = false;
      _revision++;
    }
    if (!controller.presentationActive) {
      _revision++;
      _presenting = false;
      return;
    }
    if (_presented || _presenting || !controller.firstFrameRendered) return;
    _presenting = true;
    final revision = ++_revision, session = _session;
    bool current() =>
        mounted &&
        revision == _revision &&
        widget.controller.session == session &&
        widget.controller.presentationActive;
    // A decoded frame/texture-size notification precedes composition. Keep
    // the still through the frame that attaches the texture and its next paint.
    // Exactly two presentation frames, never a polling loop or background job.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current()) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!current()) return;
        setState(() {
          _presented = true;
          _presenting = false;
        });
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _revision++;
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (_, _) {
      final controller = widget.controller;
      final session = controller.session;
      final parameters = session?.player.state.videoParams;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (session != null)
            widget.videoBuilder?.call(session, widget.backgroundColor) ??
                Video(
                  key: ValueKey(session),
                  controller: session.video,
                  aspectRatio: videoAspectRatio(
                    width: parameters?.dw ?? parameters?.w,
                    height: parameters?.dh ?? parameters?.h,
                    rotation: parameters?.rotate ?? 0,
                  ),
                  fit: BoxFit.contain,
                  fill: widget.backgroundColor,
                  controls: null,
                  wakelock: false,
                  pauseUponEnteringBackgroundMode: false,
                  resumeUponEnteringForegroundMode: false,
                  onEnterFullscreen: () async {},
                  onExitFullscreen: () async {},
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    visible: false,
                  ),
                ),
          if (!_presented) widget.cover,
          if (controller.presentationActive &&
              (controller.loading ||
                  controller.buffering ||
                  session != null &&
                      controller.playing &&
                      controller.error.isEmpty &&
                      !_presented))
            const IgnorePointer(
              child: Center(
                child: SizedBox.square(
                  dimension: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Compact bottom transport. Timeline ticks rebuild only this control, while
/// dragging submits a single seek on release instead of filling a native queue.
class AlbumVideoControls extends StatefulWidget {
  final AlbumVideoController controller;
  final VoidCallback? onInteractionStart, onInteractionEnd;
  final FocusNode? playPauseFocusNode;

  const AlbumVideoControls({
    super.key,
    required this.controller,
    this.onInteractionStart,
    this.onInteractionEnd,
    this.playPauseFocusNode,
  });

  @override
  State<AlbumVideoControls> createState() => _AlbumVideoControlsState();
}

class _AlbumVideoControlsState extends State<AlbumVideoControls> {
  double? _scrubbing;
  Object? _scrubSession;
  bool _scrubbingHeld = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(AlbumVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      if (_scrubbingHeld) oldWidget.onInteractionEnd?.call();
      _scrubbingHeld = false;
      _scrubbing = null;
      _scrubSession = null;
    }
  }

  void _controllerChanged() {
    if (!_scrubbingHeld ||
        widget.controller.presentationActive &&
            identical(_scrubSession, widget.controller.session)) {
      return;
    }
    // A backgrounded drag may never receive another pointer event or frame.
    _scrubbingHeld = false;
    _scrubSession = null;
    _scrubbing = null;
    widget.onInteractionEnd?.call();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    if (_scrubbingHeld) widget.onInteractionEnd?.call();
    super.dispose();
  }

  void _endScrub(double value) {
    if (!_scrubbingHeld) return;
    _scrubbingHeld = false;
    final controller = widget.controller;
    final sameSession = identical(_scrubSession, controller.session);
    setState(() => _scrubbing = null);
    _scrubSession = null;
    widget.onInteractionEnd?.call();
    if (sameSession) {
      unawaited(controller.seek(Duration(milliseconds: value.round())));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (_, _) {
      final controller = widget.controller;
      return IconTheme(
        data: const IconThemeData(color: Colors.white, size: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  controller.error,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ValueListenableBuilder<Duration>(
              valueListenable: controller.position,
              builder: (_, position, _) {
                final duration = controller.duration.inMilliseconds;
                final max = duration > 0 ? duration.toDouble() : 1.0;
                final sameSession = identical(
                  _scrubSession,
                  controller.session,
                );
                final value =
                    ((sameSession ? _scrubbing : null) ??
                            position.inMilliseconds.toDouble())
                        .clamp(0.0, max);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        TelevisionAction(
                          focusNode: widget.playPauseFocusNode,
                          onActivate: () => unawaited(controller.toggle()),
                          builder: (_, focus) => IconButton(
                            key: const ValueKey('album-video-toggle'),
                            focusNode: focus,
                            tooltip: controller.playing || controller.loading
                                ? '暂停'
                                : controller.error.isEmpty
                                ? '播放'
                                : '重试播放',
                            color: Colors.white,
                            iconSize: 32,
                            constraints: const BoxConstraints(
                              minWidth: 52,
                              minHeight: 52,
                            ),
                            visualDensity: VisualDensity.standard,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => unawaited(controller.toggle()),
                            icon: _AlbumTransportIcon(
                              controller.playing || controller.loading
                                  ? _AlbumTransportSymbol.pause
                                  : _AlbumTransportSymbol.play,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${_time(Duration(milliseconds: value.round()))} / '
                              '${_time(controller.duration)}',
                              key: const ValueKey('album-video-time'),
                              maxLines: 1,
                              softWrap: false,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('album-video-mute'),
                          tooltip: controller.muted ? '取消静音' : '静音',
                          color: Colors.white,
                          iconSize: 32,
                          constraints: const BoxConstraints(
                            minWidth: 52,
                            minHeight: 52,
                          ),
                          visualDensity: VisualDensity.standard,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => unawaited(controller.toggleMute()),
                          icon: _AlbumTransportIcon(
                            controller.muted
                                ? _AlbumTransportSymbol.muted
                                : _AlbumTransportSymbol.volume,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 40,
                      width: double.infinity,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 3,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white30,
                          thumbColor: Colors.white,
                          disabledActiveTrackColor: Colors.white38,
                          disabledInactiveTrackColor: Colors.white24,
                          disabledThumbColor: Colors.white54,
                        ),
                        child: Slider(
                          key: const ValueKey('album-video-seek'),
                          value: value,
                          max: max,
                          semanticFormatterCallback: (value) =>
                              _time(Duration(milliseconds: value.round())),
                          onChangeStart: (_) {
                            _scrubbingHeld = true;
                            _scrubSession = controller.session;
                            widget.onInteractionStart?.call();
                          },
                          onChanged: duration > 0 && !controller.loading
                              ? (value) => setState(() => _scrubbing = value)
                              : null,
                          onChangeEnd: _endScrub,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      );
    },
  );

  static String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 359999);
    final minutes = seconds ~/ 60;
    final tail = (seconds % 60).toString().padLeft(2, '0');
    return minutes < 60
        ? '$minutes:$tail'
        : '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:$tail';
  }
}

enum _AlbumTransportSymbol { play, pause, volume, muted }

class _AlbumTransportIcon extends StatelessWidget {
  final _AlbumTransportSymbol symbol;
  const _AlbumTransportIcon(this.symbol);

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 32,
    child: CustomPaint(
      painter: _AlbumTransportPainter(
        symbol,
        IconTheme.of(context).color ?? Colors.white,
      ),
    ),
  );
}

class _AlbumTransportPainter extends CustomPainter {
  final _AlbumTransportSymbol symbol;
  final Color color;
  const _AlbumTransportPainter(this.symbol, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final fill = Paint()..color = color;
    switch (symbol) {
      case _AlbumTransportSymbol.play:
        canvas.drawPath(
          Path()
            ..moveTo(7, 4.2)
            ..quadraticBezierTo(7, 2.6, 8.4, 3.4)
            ..lineTo(27, 14.2)
            ..quadraticBezierTo(29, 15.5, 27, 16.8)
            ..lineTo(8.4, 28.4)
            ..quadraticBezierTo(7, 29.2, 7, 27.6)
            ..close(),
          fill,
        );
      case _AlbumTransportSymbol.pause:
        for (final left in [6.0, 20.0]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(left, 4, 7, 24),
              const Radius.circular(1),
            ),
            fill,
          );
        }
      case _AlbumTransportSymbol.volume || _AlbumTransportSymbol.muted:
        final speaker = Path()
          ..moveTo(5, 12)
          ..lineTo(11, 12)
          ..lineTo(20.5, 4.2)
          ..quadraticBezierTo(22, 3, 22, 5)
          ..lineTo(22, 27)
          ..quadraticBezierTo(22, 29, 20.5, 27.8)
          ..lineTo(11, 20)
          ..lineTo(5, 20)
          ..quadraticBezierTo(4, 20, 4, 19)
          ..lineTo(4, 13)
          ..quadraticBezierTo(4, 12, 5, 12)
          ..close();
        final stroke = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round;
        if (symbol == _AlbumTransportSymbol.muted) {
          // Leave a transparent gap around the slash on either canvas color.
          canvas.save();
          canvas.clipPath(
            Path()
              ..fillType = PathFillType.evenOdd
              ..addRect(const Rect.fromLTWH(0, 0, 32, 32))
              ..moveTo(-4, -8)
              ..lineTo(40, 36)
              ..lineTo(36, 40)
              ..lineTo(-8, -4)
              ..close(),
          );
          canvas.drawPath(speaker, fill);
          canvas.restore();
          canvas.drawLine(const Offset(4, 4), const Offset(28, 28), stroke);
        } else {
          canvas.drawPath(speaker, fill);
          canvas.drawPath(
            Path()
              ..moveTo(25, 11)
              ..cubicTo(28.5, 13.5, 28.5, 18.5, 25, 21)
              ..moveTo(28, 6)
              ..cubicTo(31.5, 11, 31.5, 21, 28, 26),
            stroke,
          );
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AlbumTransportPainter oldDelegate) =>
      symbol != oldDelegate.symbol || color != oldDelegate.color;
}
