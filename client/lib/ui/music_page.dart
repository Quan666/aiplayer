import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_model.dart';
import '../playback/fullscreen_transition.dart';
import '../playback/music_controller.dart';
import '../playback/session.dart';
import '../sources/source.dart';
import 'glass.dart';

typedef MusicPageControllerFactory = MusicPlaybackController Function({
  required AppModel model,
  required String sourceId,
  required List<SourceEntry> entries,
  required int initialIndex,
  required bool backgrounded,
  required bool mobileLifecycle,
});

class MusicPage extends StatefulWidget {
  final AppModel model;
  final String sourceId;

  /// An already ordered source snapshot; no directory scan or sort runs here.
  final List<SourceEntry> entries;
  final int initialIndex;
  @visibleForTesting
  final MusicPageControllerFactory? createController;
  @visibleForTesting
  final bool? mobileLifecycle;
  const MusicPage({
    super.key,
    required this.model,
    required this.sourceId,
    required this.entries,
    this.initialIndex = 0,
    this.createController,
    this.mobileLifecycle,
  });

  static final Set<Future<void>> _disposals = {};
  static Future<void> waitForDisposals() async {
    while (_disposals.isNotEmpty) {
      await Future.wait(_disposals.toList());
    }
  }

  static void _track(Future<void> work) {
    _disposals.add(work);
    unawaited(work.whenComplete(() => _disposals.remove(work)));
  }

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> with WidgetsBindingObserver {
  MusicPlaybackController? _controller;
  int _generation = 0, _startupPauseRevision = 0;
  bool _backgrounded = false, _startupBlocked = false;
  bool get _mobileLifecycle =>
      widget.mobileLifecycle ?? (Platform.isAndroid || Platform.isIOS);
  bool get _pausePolicy =>
      _mobileLifecycle && widget.model.preferences.pauseOnBackground;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backgrounded = playbackIsBackgrounded(
      WidgetsBinding.instance.lifecycleState,
    );
    widget.model.addListener(_updateStartupPausePolicy);
    _updateStartupPausePolicy();
    unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_generation;
    final pauseRevision = _startupPauseRevision;
    final play = !_startupBlocked;
    await MusicPage.waitForDisposals();
    if (!mounted || generation != _generation || widget.entries.isEmpty) return;
    final controller = _controller =
        (widget.createController ?? _defaultController)(
          model: widget.model,
          sourceId: widget.sourceId,
          entries: widget.entries,
          initialIndex: widget.initialIndex.clamp(0, widget.entries.length - 1),
          backgrounded: _backgrounded,
          mobileLifecycle: _mobileLifecycle,
        );
    setState(() {});
    unawaited(
      controller.start(play: play && pauseRevision == _startupPauseRevision),
    );
  }

  static MusicPlaybackController _defaultController({
    required AppModel model,
    required String sourceId,
    required List<SourceEntry> entries,
    required int initialIndex,
    required bool backgrounded,
    required bool mobileLifecycle,
  }) => MusicPlaybackController(
    model: model,
    sourceId: sourceId,
    entries: entries,
    initialIndex: initialIndex,
    backgrounded: backgrounded,
    mobileLifecycle: mobileLifecycle,
  );

  void _updateStartupPausePolicy() {
    final blocked = _backgrounded && _pausePolicy;
    if (blocked && !_startupBlocked) _startupPauseRevision++;
    _startupBlocked = blocked;
  }

  @override
  void didUpdateWidget(MusicPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_updateStartupPausePolicy);
      widget.model.addListener(_updateStartupPausePolicy);
    }
    _updateStartupPausePolicy();
    if (oldWidget.model != widget.model ||
        oldWidget.sourceId != widget.sourceId ||
        !identical(oldWidget.entries, widget.entries)) {
      final previous = _controller;
      _controller = null;
      if (previous != null) {
        MusicPage._track(previous.close());
        previous.dispose();
      }
      unawaited(_start());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      _updateStartupPausePolicy();
      _controller?.setBackgrounded(false);
    } else if (playbackIsBackgrounded(state)) {
      _backgrounded = true;
      _updateStartupPausePolicy();
      _controller?.setBackgrounded(true);
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.model.removeListener(_updateStartupPausePolicy);
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    if (controller != null) {
      MusicPage._track(controller.close());
      controller.dispose();
    }
    super.dispose();
  }

  void _queue(MusicPlaybackController controller) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => GlassSheetBody(
      child: SafeArea(
        child: _MusicQueueView(controller: controller, shrinkWrap: true),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('音乐'),
          actions: [
            if (controller != null)
              IconButton(
                tooltip: '播放列表',
                onPressed: () => _queue(controller),
                icon: const Icon(Icons.queue_music_rounded),
              ),
          ],
        ),
        body: controller == null
            ? const Center(child: Text('没有可播放的音乐'))
            : SafeArea(
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => LayoutBuilder(
                    builder: (context, constraints) {
                      final player = _MusicControls(controller: controller);
                      if (constraints.maxWidth >= 900) {
                        return Row(
                          children: [
                            Expanded(child: player),
                            const VerticalDivider(width: 1),
                            SizedBox(
                              width: 320,
                              child: _MusicQueueView(controller: controller),
                            ),
                          ],
                        );
                      }
                      return player;
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

class _MusicControls extends StatelessWidget {
  final MusicPlaybackController controller;
  const _MusicControls({required this.controller});
  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    final colors = Theme.of(context).colorScheme;
    final styles = Theme.of(context).textTheme;
    final mode = controller.queue.mode;
    final (modeLabel, modeIcon) = switch (mode) {
      MusicPlayMode.sequence => ('顺序播放', Icons.arrow_forward_rounded),
      MusicPlayMode.repeatAll => ('列表循环', Icons.repeat_rounded),
      MusicPlayMode.repeatOne => ('单曲循环', Icons.repeat_one_rounded),
      MusicPlayMode.shuffle => ('随机播放', Icons.shuffle_rounded),
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.album_rounded, size: 140, color: colors.primary),
              const SizedBox(height: 20),
              Text(
                controller.title,
                style: styles.titleLarge,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (session?.audioArtist.isNotEmpty == true) ...[
                const SizedBox(height: 6),
                Text(
                  session!.audioArtist,
                  style: styles.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ],
              if (session?.audioAlbum.isNotEmpty == true) ...[
                const SizedBox(height: 4),
                Text(
                  session!.audioAlbum,
                  style: styles.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              if (controller.error.isNotEmpty)
                Column(
                  children: [
                    Text(controller.error, textAlign: TextAlign.center),
                    TextButton.icon(
                      onPressed: () =>
                          controller.select(controller.queue.index),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              if (session != null)
                _MusicProgress(session: session, seek: controller.seek),
              if (controller.loading || session?.player.state.buffering == true)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: modeLabel,
                    onPressed: () => controller.setMode(
                      MusicPlayMode.values[(mode.index + 1) %
                          MusicPlayMode.values.length],
                    ),
                    icon: Icon(modeIcon),
                  ),
                  IconButton(
                    tooltip: '上一曲',
                    onPressed: controller.previous,
                    iconSize: 32,
                    icon: const Icon(Icons.skip_previous_rounded),
                  ),
                  IconButton.filled(
                    tooltip: session?.player.state.playing == true
                        ? '暂停'
                        : '播放',
                    onPressed: controller.loading
                        ? null
                        : controller.togglePlayback,
                    iconSize: 42,
                    icon: Icon(
                      session?.player.state.playing == true
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  IconButton(
                    tooltip: '下一曲',
                    onPressed: () => controller.next(),
                    iconSize: 32,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MusicProgress extends StatefulWidget {
  final PlaybackSession session;
  final Future<void> Function(Duration) seek;
  const _MusicProgress({required this.session, required this.seek});
  @override
  State<_MusicProgress> createState() => _MusicProgressState();
}

class _MusicProgressState extends State<_MusicProgress> {
  double? _drag;
  @override
  void didUpdateWidget(_MusicProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) _drag = null;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Duration>(
    valueListenable: widget.session.position,
    builder: (context, position, _) {
      final duration = widget.session.player.state.duration;
      final maximum = duration.inMilliseconds.toDouble();
      final value = (_drag ?? position.inMilliseconds.toDouble()).clamp(
        0.0,
        maximum > 0 ? maximum : 1.0,
      );
      return Column(
        children: [
          Slider(
            value: value,
            max: maximum > 0 ? maximum : 1,
            onChanged: maximum <= 0
                ? null
                : (value) => setState(() => _drag = value),
            onChangeEnd: (value) {
              setState(() => _drag = null);
              unawaited(widget.seek(Duration(milliseconds: value.round())));
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_time(Duration(milliseconds: value.round()))),
              Text(_time(duration)),
            ],
          ),
        ],
      );
    },
  );
  static String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 86400000);
    final minutes = seconds ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _MusicQueueView extends StatelessWidget {
  final MusicPlaybackController controller;
  final bool shrinkWrap;
  const _MusicQueueView({required this.controller, this.shrinkWrap = false});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => ListView.builder(
      shrinkWrap: shrinkWrap,
      itemCount: controller.entries.length,
      itemBuilder: (context, index) => ListTile(
        selected: index == controller.queue.index,
        leading: Icon(
          index == controller.queue.index
              ? Icons.equalizer_rounded
              : Icons.music_note_rounded,
        ),
        title: Text(
          controller.entries[index].name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => controller.select(index),
      ),
    ),
  );
}
