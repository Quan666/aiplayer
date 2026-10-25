import 'package:flutter/material.dart';
import '../playback/session.dart';
import '../playback/display.dart';
import 'glass.dart';
import 'player_theme.dart';

class PlayerQuickSettings extends StatefulWidget {
  final PlaybackSession session;
  final VoidCallback onDanmaku, onDiagnostics;
  const PlayerQuickSettings({
    super.key,
    required this.session,
    required this.onDanmaku,
    required this.onDiagnostics,
  });

  @override
  State<PlayerQuickSettings> createState() => _PlayerQuickSettingsState();
}

class _PlayerQuickSettingsState extends State<PlayerQuickSettings> {
  var _selectedTab = 0;
  final _drafts = <String, _SettingDraft>{};
  PlaybackSession get session => widget.session;

  @override
  void didUpdateWidget(PlayerQuickSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, session)) _clearDrafts();
  }

  void _clearDrafts() {
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _drafts.clear();
  }

  @override
  void dispose() {
    _clearDrafts();
    super.dispose();
  }

  Future<void> _saveSetting(
    String key,
    double value,
    _SettingDraft draft,
  ) async {
    final current = session;
    final revision = draft.revision;
    await current.updateSettings({key: value});
    if (mounted &&
        identical(current, session) &&
        identical(_drafts[key], draft) &&
        draft.revision == revision) {
      draft.value = null;
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: PlayerTheme.advancedSettingsMaxHeight,
      ),
      // The active page determines the panel's height. Keeping the header in
      // the same viewport also lets it fit small windows and the keyboard.
      child: SingleChildScrollView(
        key: PageStorageKey('player-settings-$_selectedTab'),
        primary: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PlayerTheme.viewportInset,
              ),
              child: Text(
                '高级设置',
                style: PlayerTheme.of(context).panelTitleStyle,
              ),
            ),
            const SizedBox(height: PlayerTheme.menuGap),
            TabBar(
              onTap: (index) {
                if (_selectedTab != index) {
                  setState(() => _selectedTab = index);
                }
              },
              tabs: const [
                Tab(text: '播放'),
                Tab(text: '字幕'),
                Tab(text: '弹幕'),
                Tab(text: '诊断'),
              ],
            ),
            AnimatedBuilder(
              animation: Listenable.merge([session, session.model]),
              builder: _buildPage,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildPage(BuildContext context, Widget? child) {
    final p = session.model.preferences;
    Widget page(List<Widget> children) => Padding(
      padding: PlayerTheme.advancedSettingsContentPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
    Widget slider(
      String label,
      String key,
      double value,
      double min,
      double max,
      String suffix, {
      int? divisions,
      ValueChanged<double>? preview,
    }) {
      final draft = _drafts.putIfAbsent(key, _SettingDraft.new);
      return ValueListenableBuilder<double?>(
        valueListenable: draft,
        builder: (_, temporaryValue, _) => _SettingSlider(
          label: label,
          value: temporaryValue ?? value,
          min: min,
          max: max,
          suffix: suffix,
          divisions: divisions,
          onChanged: (value) {
            draft.revision++;
            draft.value = value;
            preview?.call(value);
          },
          onChangeEnd: (value) => _saveSetting(key, value, draft),
        ),
      );
    }

    return switch (_selectedTab) {
      0 => page([
        slider(
          '音量',
          'volume',
          p.volume,
          0,
          100,
          '%',
          divisions: 100,
          preview: session.player.setVolume,
        ),
        PlayerSelect<String>(
          label: '画面适配',
          maxLines: 1,
          value: p.videoFit,
          options: const [
            GlassOption('contain', '完整显示'),
            GlassOption('cover', '裁剪填满'),
            GlassOption('fill', '拉伸填满'),
          ],
          onChanged: (value) => session.updateSettings({'videoFit': value}),
        ),
        if (PlayerDisplay.supported)
          SwitchListTile(
            title: const Text('打开视频时全屏'),
            value: p.enterFullscreen,
            onChanged: (v) => session.updateSettings({'enterFullscreen': v}),
          ),
        SwitchListTile(
          title: const Text('播完自动播放下一集'),
          value: p.autoNextEpisode,
          onChanged: (v) => session.updateSettings({'autoNextEpisode': v}),
        ),
      ]),
      1 => page([
        SwitchListTile(
          title: const Text('显示字幕'),
          value: p.subtitlesEnabled,
          onChanged: (v) => session.updateSettings({'subtitlesEnabled': v}),
        ),
        slider(
          '字幕大小',
          'subtitleScale',
          p.subtitleScale,
          .5,
          3,
          '×',
          divisions: 25,
        ),
        slider(
          '字幕偏移',
          'subtitleDelay',
          p.subtitleDelay,
          -60,
          60,
          ' 秒',
          divisions: 240,
        ),
      ]),
      2 => page([
        ListTile(
          leading: const Icon(Icons.chat_bubble_outline_rounded),
          title: const Text('弹幕匹配'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: widget.onDanmaku,
        ),
        SwitchListTile(
          title: const Text('显示弹幕'),
          value: p.danmuVisible,
          onChanged: (v) => session.updateSettings({'danmuVisible': v}),
        ),
        slider(
          '弹幕字号',
          'danmuFontSize',
          p.danmuFontSize,
          12,
          48,
          '',
          divisions: 36,
        ),
        slider(
          '弹幕透明度',
          'danmuOpacity',
          p.danmuOpacity,
          .1,
          1,
          '',
          divisions: 9,
        ),
      ]),
      _ => page([
        SwitchListTile(
          title: const Text('硬件解码'),
          value: p.hardwareDecoding,
          onChanged: (v) => session.setSoftware(!v),
        ),
        ListTile(
          leading: const Icon(Icons.info_outline_rounded),
          title: const Text('播放诊断'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: widget.onDiagnostics,
        ),
      ]),
    };
  }
}

// Drafts outlive their tab, but only the visible slider listens for changes.
class _SettingDraft extends ValueNotifier<double?> {
  var revision = 0;
  _SettingDraft() : super(null);
}

class _SettingSlider extends StatelessWidget {
  final String label, suffix;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged, onChangeEnd;
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
    required this.onChangeEnd,
    this.divisions,
  });
  @override
  Widget build(BuildContext context) {
    final value = this.value.clamp(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(
              '${value == value.roundToDouble() ? value.toInt() : value.toStringAsFixed(2)}$suffix',
              style: PlayerTheme.of(context).captionStyle,
            ),
          ],
        ),
        SizedBox(
          height: 30,
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ],
    );
  }
}
