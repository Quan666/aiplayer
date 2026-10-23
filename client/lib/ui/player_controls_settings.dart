import 'package:flutter/material.dart';
import '../playback/session.dart';
import '../playback/display.dart';
import 'glass.dart';
import 'player_theme.dart';

class PlayerQuickSettings extends StatelessWidget {
  final PlaybackSession session;
  final VoidCallback onDanmaku, onDiagnostics;
  const PlayerQuickSettings({
    super.key,
    required this.session,
    required this.onDanmaku,
    required this.onDiagnostics,
  });

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 4,
    child: LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: constraints.hasBoundedHeight
            ? constraints.maxHeight.clamp(
                0.0,
                PlayerTheme.advancedSettingsMaxHeight,
              )
            : PlayerTheme.advancedSettingsMaxHeight,
        child: Column(
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
            const TabBar(
              tabs: [
                Tab(text: '播放'),
                Tab(text: '字幕'),
                Tab(text: '弹幕'),
                Tab(text: '诊断'),
              ],
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([session, session.model]),
                builder: _buildTabs,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildTabs(BuildContext context, Widget? child) {
    final p = session.model.preferences;
    Widget page(String name, List<Widget> children) => ListView(
      key: PageStorageKey('player-settings-$name'),
      padding: PlayerTheme.advancedSettingsContentPadding,
      children: children,
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
    }) => _SettingSlider(
      label: label,
      value: value,
      min: min,
      max: max,
      suffix: suffix,
      divisions: divisions,
      preview: preview,
      onChanged: (value) => session.updateSettings({key: value}),
    );
    return TabBarView(
      children: [
        page('playback', [
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
              contentPadding: EdgeInsets.zero,
              title: const Text('打开视频时全屏'),
              value: p.enterFullscreen,
              onChanged: (v) => session.updateSettings({'enterFullscreen': v}),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('播完自动播放下一集'),
            value: p.autoNextEpisode,
            onChanged: (v) => session.updateSettings({'autoNextEpisode': v}),
          ),
        ]),
        page('subtitle', [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
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
        page('danmaku', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.chat_bubble_outline_rounded),
            title: const Text('弹幕匹配'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: onDanmaku,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
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
        page('diagnostics', [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('硬件解码'),
            value: p.hardwareDecoding,
            onChanged: (v) => session.setSoftware(!v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('播放诊断'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: onDiagnostics,
          ),
        ]),
      ],
    );
  }
}

class _SettingSlider extends StatefulWidget {
  final String label, suffix;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double>? preview;
  final Future<void> Function(double) onChanged;
  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
    this.divisions,
    this.preview,
  });
  @override
  State<_SettingSlider> createState() => _SettingSliderState();
}

class _SettingSliderState extends State<_SettingSlider> {
  double? draft;
  @override
  Widget build(BuildContext context) {
    final value = (draft ?? widget.value).clamp(widget.min, widget.max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label)),
            Text(
              '${value == value.roundToDouble() ? value.toInt() : value.toStringAsFixed(2)}${widget.suffix}',
              style: PlayerTheme.of(context).captionStyle,
            ),
          ],
        ),
        SizedBox(
          height: 30,
          child: Slider(
            value: value,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            onChanged: (v) {
              setState(() => draft = v);
              widget.preview?.call(v);
            },
            onChangeEnd: (v) async {
              await widget.onChanged(v);
              if (mounted) setState(() => draft = null);
            },
          ),
        ),
      ],
    );
  }
}
