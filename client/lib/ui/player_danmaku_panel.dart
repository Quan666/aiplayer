import 'package:flutter/material.dart';
import '../danmaku/session.dart';
import '../data/media_identity.dart';
import '../playback/session.dart';
import 'player_danmaku_list.dart';
import 'player_theme.dart';

class PlayerDanmakuPanel extends StatefulWidget {
  final PlaybackSession session;
  final DanmakuSession danmaku;
  const PlayerDanmakuPanel({
    super.key,
    required this.session,
    required this.danmaku,
  });

  @override
  State<PlayerDanmakuPanel> createState() => _PlayerDanmakuPanelState();
}

class _PlayerDanmakuPanelState extends State<PlayerDanmakuPanel>
    with SingleTickerProviderStateMixin {
  final _title = TextEditingController();
  final _season = TextEditingController();
  final _episode = TextEditingController();
  final _storage = PageStorageBucket();
  late final _tabs = TabController(
    length: 2,
    vsync: this,
    animationDuration: Duration.zero,
  );
  int _tab = 0;
  PlaybackSession get session => widget.session;
  DanmakuSession get d => widget.danmaku;

  @override
  void initState() {
    super.initState();
    _fillIdentity();
  }

  @override
  void didUpdateWidget(PlayerDanmakuPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, session)) _fillIdentity();
  }

  void _fillIdentity() {
    final identity = session.danmakuIdentity;
    _title.text = identity.anime;
    _season.text = identity.season;
    _episode.text = identity.episode;
  }

  @override
  void dispose() {
    _tabs.dispose();
    _title.dispose();
    _season.dispose();
    _episode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: d,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  d.episodeId == null ? '弹幕' : '弹幕 · ${d.comments.length} 条',
                  style: PlayerTheme.of(context).panelTitleStyle,
                ),
              ),
              Switch(
                value: d.visible,
                onChanged: (value) =>
                    session.updateSettings({'danmuVisible': value}),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '设置'),
            Tab(text: '列表'),
          ],
          onTap: (value) {
            if (_tab == value) return;
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() => _tab = value);
          },
        ),
        Flexible(
          child: _tab == 0
              ? PageStorage(bucket: _storage, child: _settings(context))
              : ListenableBuilder(
                  listenable: session,
                  builder: (context, _) => PlayerDanmakuList(
                    position: session.position,
                    comments: d.comments,
                    shift: d.shift + d.offset,
                    timelineRevision: session.timelineRevision,
                    sourceKey: (d, d.episodeId),
                  ),
                ),
        ),
      ],
    ),
  );

  Widget _settings(BuildContext context) => KeyedSubtree(
    key: const PageStorageKey('danmaku-settings'),
    child: PlayerMenuList(
      key: const ValueKey('player-danmaku-panel'),
      padding: const EdgeInsets.all(16),
      // The form and adjustments are two bounded groups. A short panel fits
      // its actual contents; a large result set builds only visible matches.
      itemCount: d.candidates.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _form(context);
        if (index == d.candidates.length + 1) return _adjustments(context);
        final match = d.candidates[index - 1];
        final count = d.candidateCommentCount(match);
        return ListTile(
          key: ValueKey('danmaku-candidate-${match.episodeId}'),
          title: Text(match.label),
          trailing: Text(
            count == null ? '数量未知' : '$count 条',
            style: PlayerTheme.of(context).mutedStyle,
          ),
          onTap: () => d.select(match),
        );
      },
    ),
  );

  Widget _form(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (d.label.isNotEmpty)
        Text(d.label, style: PlayerTheme.of(context).mutedStyle),
      const SizedBox(height: 16),
      TextField(
        controller: _title,
        decoration: const InputDecoration(labelText: '作品名称'),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _season,
              decoration: const InputDecoration(labelText: '季度'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _episode,
              decoration: const InputDecoration(labelText: '集数 / S1 / O1'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        children: [
          FilledButton(
            onPressed: d.busy
                ? null
                : () => d.identify(
                    ReleaseName(
                      _title.text.trim(),
                      _season.text.trim(),
                      _episode.text.trim(),
                    ),
                    restore: false,
                  ),
            child: const Text('按名称识别'),
          ),
          OutlinedButton(
            onPressed: d.busy
                ? null
                : () => d.search(_title.text.trim(), _episode.text.trim()),
            child: const Text('搜索候选'),
          ),
        ],
      ),
      if (d.busy) const LinearProgressIndicator(),
      if (d.error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(d.error),
        ),
    ],
  );

  Widget _adjustments(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        title: const Text('弹幕偏移'),
        subtitle: Text(
          '${d.offset.toStringAsFixed(1)} 秒 · 匹配偏移 ${d.shift.toStringAsFixed(1)} 秒',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: () => d.setOffset(d.offset - .5),
              icon: const Icon(Icons.remove),
            ),
            IconButton(
              onPressed: () => d.setOffset(d.offset + .5),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
      for (final option in [
        ('danmuFontSize', '字号', 14.0, 42.0, 22.0),
        ('danmuOpacity', '透明度', .1, 1.0, .8),
        ('danmuArea', '显示区域', .2, 1.0, .65),
        ('danmuDensity', '密度', .1, 1.0, .7),
      ])
        StatefulBuilder(
          builder: (context, set) {
            final value =
                (session.model.settings[option.$1] as num?)?.toDouble() ??
                option.$5;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(option.$2),
                Slider(
                  min: option.$3,
                  max: option.$4,
                  value: value.clamp(option.$3, option.$4),
                  onChanged: (value) {
                    session.updateSettings({option.$1: value});
                    set(() {});
                  },
                ),
              ],
            );
          },
        ),
    ],
  );
}
