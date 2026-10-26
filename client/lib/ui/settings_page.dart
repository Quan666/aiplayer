import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/network.dart';
import '../core/logger.dart';
import '../danmaku/api.dart';
import '../danmaku/filter_preset.dart';
import '../data/app_model.dart';
import '../data/preferences.dart';
import 'glass.dart';
import 'theme/settings_styles.dart';
import 'logs_page.dart';
import 'search_header.dart';
import '../subtitles/settings.dart';
import 'library_page.dart';
import 'navigation_reveal.dart';

class SettingsPage extends StatefulWidget {
  final AppModel model;
  final bool active;
  const SettingsPage({super.key, required this.model, this.active = true});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  final origin = TextEditingController(),
      token = TextEditingController(),
      interval = TextEditingController(),
      syncOrigin = TextEditingController(),
      syncToken = TextEditingController(),
      blockedWords = TextEditingController(),
      tmdbKey = TextEditingController();
  final _pages = PageController();
  final _chipKeys = <String, GlobalKey>{};
  int _searchGeneration = 0;
  int _cacheClearGeneration = 0;
  bool _confirmingCacheClear = false;
  bool _clearingCaches = false;
  bool testingMetadata = false, refreshingMetadata = false;
  bool loading = true, saving = false;
  String group = 'general', query = '';
  Object? _settingsRevision;
  AppPreferences? _sectionPreferences;
  bool _foreground = true, _visible = true;
  AppModel get model => widget.model;
  AppPreferences get prefs => _sectionPreferences ?? model.preferences;
  bool get mobile => Platform.isAndroid || Platform.isIOS;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _settingsRevision = _revision;
    model.addListener(_modelChanged);
    load();
  }

  Object get _revision => (
    model.store,
    model.store.localKeyRevision('settings'),
    model.store.localKeyRevision('appearance:theme'),
  );

  void _modelChanged() {
    if (!mounted || !widget.active || !_foreground || !_visible) return;
    final revision = _revision;
    if (_settingsRevision == revision) return;
    _settingsRevision = revision;
    // Refresh switches and options without reloading controllers: connection
    // credentials and unsaved drafts belong to this editing session.
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _modelChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _modelChanged();
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_modelChanged);
      model.addListener(_modelChanged);
      _cacheClearGeneration++;
      _confirmingCacheClear = false;
      _clearingCaches = false;
    }
    if (widget.active) _settingsRevision = _revision;
  }

  Widget _buildSection(Widget Function() builder) {
    final previous = _sectionPreferences;
    _sectionPreferences = model.preferences;
    try {
      return builder();
    } finally {
      _sectionPreferences = previous;
    }
  }

  Future<void> load() async {
    final s = model.settings;
    origin.text = s['danmuOrigin'] ?? DanmuApiClient.defaultOrigin;
    interval.text = '${prefs.refreshInterval}';
    syncOrigin.text = s['syncOrigin'] ?? '';
    blockedWords.text = prefs.danmuBlockedWords;
    try {
      final t = await model.secrets.read(key: 'danmuToken');
      final st = await model.secrets.read(key: 'syncToken');
      final mt = await model.secrets.read(key: 'tmdb.apiKey');
      if (!mounted) return;
      token.text = t ?? '';
      syncToken.text = st ?? '';
      tmdbKey.text = mt ?? '';
    } catch (_) {
      if (mounted) {
        showFailure(context, const AppFailure('无法读取系统安全存储，请检查系统密钥服务。'));
      }
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    model.removeListener(_modelChanged);
    for (final c in [
      origin,
      token,
      interval,
      syncOrigin,
      syncToken,
      blockedWords,
      tmdbKey,
    ]) {
      c.dispose();
    }
    _pages.dispose();
    super.dispose();
  }

  Future<void> update(String key, dynamic value) async {
    try {
      await model.updatePreferences({key: value});
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        showFailure(
          context,
          AppFailure(e is ArgumentError ? '${e.message}' : '设置未能保存'),
        );
      }
    }
  }

  Future<void> saveDanmaku() async {
    setState(() => saving = true);
    try {
      DanmuApiClient(
        origin.text.trim(),
        token.text.trim().isEmpty ? 'validate' : token.text.trim(),
      );
      final seconds = int.tryParse(interval.text);
      if (seconds == null ||
          !(seconds == 0 || seconds >= 30 && seconds <= 3600)) {
        throw const AppFailure('刷新间隔须为 0 或 30–3600 秒。');
      }
      await model.setSettings({
        'danmuOrigin': origin.text.trim().replaceFirst(RegExp(r'/$'), ''),
        'refreshInterval': seconds,
      }, danmuToken: token.text.trim());
      if (mounted) showGlassSuccess(context, '弹幕服务配置已保存');
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> saveSync({bool synchronize = false}) async {
    setState(() => saving = true);
    try {
      if (synchronize && syncOrigin.text.trim().isEmpty) {
        throw const AppFailure('请先填写同步服务地址。');
      }
      await model.setSettings({
        'syncOrigin': syncOrigin.text.trim(),
      }, syncToken: syncToken.text.trim());
      if (synchronize) {
        await model.synchronize();
        if (mounted) await load();
        if (model.status.startsWith('同步失败：')) {
          throw AppFailure(model.status);
        }
      }
      if (mounted) {
        showGlassSuccess(context, synchronize ? model.status : '同步配置已保存');
      }
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> resetAssociation() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        titlePadding: GlassMetrics.dialogTitlePadding,
        contentPadding: GlassMetrics.dialogContentPadding,
        actionsPadding: GlassMetrics.dialogActionsPadding,
        title: const Text('重置同步关联？'),
        content: const Text('保留本机资料，下次同步将按最新修改自动合并。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (yes == true) {
      try {
        model.sync.resetAssociation();
        model.changed();
        if (mounted) showGlassSuccess(context, '已重置同步关联');
      } catch (error) {
        if (mounted) showFailure(context, error);
      }
    }
  }

  Future<void> clearCaches() async {
    if (_confirmingCacheClear || _clearingCaches) return;
    final target = model;
    final generation = ++_cacheClearGeneration;
    bool current() =>
        mounted &&
        identical(model, target) &&
        generation == _cacheClearGeneration;
    bool visible() => widget.active && _foreground && _visible;
    setState(() => _confirmingCacheClear = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          titlePadding: GlassMetrics.dialogTitlePadding,
          contentPadding: GlassMetrics.dialogContentPadding,
          actionsPadding: GlassMetrics.dialogActionsPadding,
          title: const Text('清除缓存？'),
          content: const Text('清除识别、弹幕和文件探测缓存。\n保留封面、海报、来源、影视库、播放记录和手动匹配。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清除缓存'),
            ),
          ],
        ),
      );
      if (confirmed != true || !current() || !widget.active || !_foreground) {
        return;
      }
      setState(() {
        _confirmingCacheClear = false;
        _clearingCaches = true;
      });
      await target.clearCaches();
      if (mounted && current() && visible()) {
        showGlassSuccess(context, '缓存已清除，重新进入文件夹即可重新加载');
      }
    } catch (error) {
      if (mounted && current() && visible()) showFailure(context, error);
    } finally {
      if (current()) {
        setState(() {
          _confirmingCacheClear = false;
          _clearingCaches = false;
        });
      }
    }
  }

  Future<void> resetPreferences() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        titlePadding: GlassMetrics.dialogTitlePadding,
        contentPadding: GlassMetrics.dialogContentPadding,
        actionsPadding: GlassMetrics.dialogActionsPadding,
        title: const Text('恢复播放与操作设置？'),
        content: const Text('恢复播放、字幕、弹幕、手势和快捷键默认值，保留影视库、来源、主题和连接凭证。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await model.resetPreferences();
      if (mounted) {
        setState(() {
          blockedWords.text = '';
          interval.text = '${prefs.refreshInterval}';
        });
        showGlassSuccess(context, '已恢复默认设置');
      }
    }
  }

  Widget section(String title, List<Widget> children) => GlassSurface(
    blur: 0,
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppStyles.of(context).sectionTitle),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );
  Widget toggle(String label, String key, bool value, {String? hint}) =>
      SwitchListTile.adaptive(
        dense: true,
        title: Text(label, style: AppStyles.of(context).body),
        subtitle: hint == null
            ? null
            : Text(hint, style: AppStyles.of(context).micro),
        value: value,
        onChanged: (v) => update(key, v),
      );
  Widget slider(
    String label,
    String key,
    double value,
    double min,
    double max, {
    String suffix = '',
    int? divisions,
    int decimals = 0,
  }) => _PreferenceSlider(
    label: label,
    value: value,
    min: min,
    max: max,
    suffix: suffix,
    divisions: divisions,
    decimals: decimals,
    onChanged: (v) => update(key, v),
  );
  Widget select<T>(
    String label,
    String key,
    T value,
    List<GlassOption<T>> options,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: GlassSelect<T>(
      label: label,
      value: value,
      options: options,
      onChanged: (v) => update(key, v),
    ),
  );

  Widget appearance() => section('外观与文件', [
    SegmentedButton<ThemeMode>(
      showSelectedIcon: false,
      expandedInsets: EdgeInsets.zero,
      segments: const [
        ButtonSegment(
          value: ThemeMode.light,
          icon: Icon(Icons.light_mode_outlined, size: 18),
          label: Text('浅色'),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: Icon(Icons.dark_mode_outlined, size: 18),
          label: Text('深色'),
        ),
      ],
      selected: {model.themeMode},
      onSelectionChanged: (v) => setState(() => model.setThemeMode(v.single)),
    ),
    const SizedBox(height: 8),
    toggle('不显示隐藏文件和文件夹', 'hideHiddenFiles', prefs.hideHiddenFiles),
  ]);
  Widget playback() => section('播放', [
    toggle('打开视频后自动播放', 'autoPlay', prefs.autoPlay),
    toggle(
      '播完自动播放下一集',
      'autoNextEpisode',
      prefs.autoNextEpisode,
      hint: '当前剧集播放结束后，自动继续下一集',
    ),
    if (mobile)
      toggle(
        '进入播放器时全屏',
        'enterFullscreen',
        prefs.enterFullscreen,
        hint: '按视频方向自动选择横屏或竖屏',
      ),
    if (mobile)
      toggle('旋转设备时自动全屏', 'autoRotateFullscreen', prefs.autoRotateFullscreen),
    toggle('从上次位置继续', 'resumePlayback', prefs.resumePlayback),
    toggle('优先硬件解码', 'hardwareDecoding', prefs.hardwareDecoding),
    toggle('播放时保持屏幕常亮', 'keepScreenOn', prefs.keepScreenOn),
    if (mobile)
      toggle(
        '切到后台时暂停',
        'pauseOnBackground',
        prefs.pauseOnBackground,
        hint: '关闭后仅在系统允许应用运行时继续',
      ),
    select('默认倍速', 'playbackRate', prefs.playbackRate, [
      for (final v in ({
        for (var i = 1; i <= 12; i++) i / 4,
        prefs.playbackRate,
      }.toList()..sort()))
        GlassOption(v, '$v×'),
    ]),
    select('画面适配', 'videoFit', prefs.videoFit, const [
      GlassOption('contain', '完整显示'),
      GlassOption('cover', '铺满并裁切'),
      GlassOption('fill', '拉伸填满'),
    ]),
    slider('默认音量', 'volume', prefs.volume, 0, 100, suffix: '%', divisions: 100),
    slider(
      '音频时间偏移',
      'audioDelay',
      prefs.audioDelay,
      -10,
      10,
      suffix: ' 秒',
      divisions: 200,
      decimals: 1,
    ),
    select('快进 / 后退步长', 'seekStepSeconds', prefs.seekStepSeconds, const [
      GlassOption(5, '5 秒'),
      GlassOption(10, '10 秒'),
      GlassOption(15, '15 秒'),
      GlassOption(30, '30 秒'),
      GlassOption(60, '60 秒'),
      GlassOption(120, '120 秒'),
    ]),
    select('控制栏自动隐藏', 'controlsHideSeconds', prefs.controlsHideSeconds, const [
      GlassOption(0, '不自动隐藏'),
      GlassOption(2, '2 秒'),
      GlassOption(3, '3 秒'),
      GlassOption(5, '5 秒'),
      GlassOption(8, '8 秒'),
      GlassOption(15, '15 秒'),
    ]),
  ]);
  Widget subtitles() => section('字幕', [
    toggle('默认显示字幕', 'subtitlesEnabled', prefs.subtitlesEnabled),
    toggle('繁体字幕转简体', 'subtitleSimplify', prefs.subtitleSimplify),
    toggle(
      '自动加载同名外挂字幕',
      'autoLoadExternalSubtitles',
      prefs.autoLoadExternalSubtitles,
    ),
    select('优先语言', 'subtitleLanguage', prefs.subtitleLanguage, const [
      GlassOption('auto', '自动'),
      GlassOption('zh-Hans', '简体中文（默认）'),
      GlassOption('zh-Hant', '繁体中文'),
      GlassOption('zh', '中文'),
      GlassOption('ja', '日语'),
      GlassOption('en', '英语'),
    ]),
    slider(
      '字幕缩放',
      'subtitleScale',
      prefs.subtitleScale,
      .5,
      3,
      suffix: '×',
      divisions: 25,
      decimals: 1,
    ),
    slider(
      '字幕时间偏移',
      'subtitleDelay',
      prefs.subtitleDelay,
      -60,
      60,
      suffix: ' 秒',
      divisions: 240,
      decimals: 1,
    ),
    slider(
      '字幕垂直位置',
      'subtitlePosition',
      prefs.subtitlePosition,
      0,
      100,
      suffix: '%',
      divisions: 100,
    ),
    select('默认文字颜色', 'subtitleColor', prefs.subtitleColor, const [
      GlassOption('#FFFFFF', '白色'),
      GlassOption('#FFE066', '黄色'),
      GlassOption('#8DE0FF', '浅蓝'),
    ]),
    slider(
      '默认描边宽度',
      'subtitleBorderSize',
      prefs.subtitleBorderSize,
      0,
      6,
      divisions: 12,
      decimals: 1,
    ),
    Text(
      'ASS 内嵌样式优先保留；默认颜色、位置和描边主要用于无样式字幕。',
      style: AppStyles.of(context).micro,
    ),
  ]);
  Widget aiTranslation() => section('AI 翻译', [
    Text('字幕、剧集标题和影视简介共用 API、模型与目标语言。', style: AppStyles.of(context).micro),
    Text('AI 自动识别信息也使用这里的服务和模型。', style: AppStyles.of(context).micro),
    const SizedBox(height: 12),
    AiSubtitleSettings(model: model),
  ]);
  Widget danmaku() => section('弹幕', [
    toggle('默认开启弹幕', 'danmuVisible', prefs.danmuVisible),
    slider('字号', 'danmuFontSize', prefs.danmuFontSize, 12, 48, divisions: 36),
    slider(
      '不透明度',
      'danmuOpacity',
      prefs.danmuOpacity,
      .1,
      1,
      divisions: 18,
      decimals: 2,
    ),
    slider(
      '显示区域',
      'danmuArea',
      prefs.danmuArea,
      .2,
      1,
      divisions: 16,
      decimals: 2,
    ),
    slider(
      '密度',
      'danmuDensity',
      prefs.danmuDensity,
      .1,
      1,
      divisions: 18,
      decimals: 2,
    ),
    slider(
      '弹幕速度',
      'danmuSpeed',
      prefs.danmuSpeed,
      .5,
      2,
      divisions: 15,
      suffix: '×',
      decimals: 1,
    ),
    toggle('滚动弹幕', 'danmuScroll', prefs.danmuScroll),
    toggle('顶部弹幕', 'danmuTop', prefs.danmuTop),
    toggle('底部弹幕', 'danmuBottom', prefs.danmuBottom),
    toggle(
      '内置屏蔽规则',
      'danmuPresetFilter',
      prefs.danmuPresetFilter,
      hint:
          '内置预设：'
          '${danmakuPresetKeywords.length} 个关键词、'
          '${danmakuPresetPatterns.length} 条正则（$danmakuPresetDate）',
    ),
    const SizedBox(height: 8),
    TextField(
      controller: blockedWords,
      minLines: 2,
      maxLines: 4,
      maxLength: 4000,
      decoration: const InputDecoration(
        labelText: '自定义屏蔽词',
        hintText: '每行一个，匹配到的弹幕不显示',
      ),
      onChanged: (v) => update('danmuBlockedWords', v),
    ),
  ]);
  String get gestureSeekLabel {
    final seconds = prefs.gestureSeekSeconds;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    if (minutes == 0) return '$remainder 秒';
    if (remainder == 0) return '$minutes 分钟';
    return '$minutes 分 $remainder 秒';
  }

  List<GlassOption<String>> get tapActionOptions => [
    const GlassOption('playPause', '暂停 / 继续播放'),
    GlassOption('seek', '左侧后退 / 右侧快进 ${prefs.seekStepSeconds} 秒'),
    GlassOption('skipForward', '向前跳过 $gestureSeekLabel'),
    GlassOption('skipBackward', '向后退回 $gestureSeekLabel'),
    GlassOption('seekTo', '跳到视频 $gestureSeekLabel 处'),
    const GlassOption('fullscreen', '进入 / 退出全屏'),
    const GlassOption('none', '不执行操作'),
  ];

  Future<void> editGestureSeekTime() async {
    final seconds = await showDialog<int>(
      context: context,
      builder: (_) =>
          _GestureSeekDurationDialog(initialSeconds: prefs.gestureSeekSeconds),
    );
    if (seconds != null) await update('gestureSeekSeconds', seconds);
  }

  Widget gestures() => section('手势', [
    toggle('启用播放手势', 'gesturesEnabled', prefs.gesturesEnabled),
    select('双击屏幕', 'doubleTapAction', prefs.doubleTapAction, tapActionOptions),
    select(
      '三击左侧',
      'tripleTapLeftAction',
      prefs.tripleTapLeftAction,
      tapActionOptions,
    ),
    select('三击中间', 'tripleTapAction', prefs.tripleTapAction, tapActionOptions),
    select(
      '三击右侧',
      'tripleTapRightAction',
      prefs.tripleTapRightAction,
      tapActionOptions,
    ),
    ListTile(
      dense: true,
      title: Text('手势跳转时间', style: AppStyles.of(context).body),
      subtitle: Text(
        '${prefs.gestureSeekSeconds} 秒（$gestureSeekLabel）· 双击、三击共用的前跳 / 后退时长或指定位置',
        style: AppStyles.of(context).micro,
      ),
      trailing: const Icon(Icons.edit_outlined, size: 20),
      onTap: editGestureSeekTime,
    ),
    toggle('捏合切换画面适配', 'pinchToZoom', prefs.pinchToZoom),
    toggle(
      '双击左右边缘快进 / 后退',
      'edgeDoubleTapSeek',
      prefs.edgeDoubleTapSeek,
      hint: '双击边缘时优先按“快进 / 后退步长”跳转',
    ),
    toggle('横向滑动调整进度', 'horizontalSeek', prefs.horizontalSeek),
    toggle('右侧纵向滑动调音量', 'verticalVolume', prefs.verticalVolume),
    toggle('左侧纵向滑动调亮度', 'verticalBrightness', prefs.verticalBrightness),
    toggle('长按临时倍速', 'longPressSpeed', prefs.longPressSpeed),
    select('长按时的倍速', 'longPressRate', prefs.longPressRate, const [
      GlassOption(1.25, '1.25×'),
      GlassOption(1.5, '1.5×'),
      GlassOption(2.0, '2×'),
      GlassOption(2.5, '2.5×'),
      GlassOption(3.0, '3×'),
    ]),
    Text(
      '画面按宽度分为左、中、右三个区域，三击可分别设置。默认左侧后退 89 秒、右侧前进 89 秒；已有自定义三击动作会保留。单击显示控制栏；锁定按钮可暂时禁用触控。',
      style: AppStyles.of(context).micro,
    ),
  ]);
  Future<void> editShortcut(String action) async {
    final current = prefs.shortcuts[action]!;
    final next = await showDialog<String>(
      context: context,
      builder: (_) => _ShortcutDialog(
        title: AppPreferences.shortcutLabels[action]!,
        initial: current,
      ),
    );
    if (next != null) await update('shortcuts', {action: next});
  }

  Widget keyboard() => section('快捷键', [
    toggle('启用播放器快捷键', 'keyboardEnabled', prefs.keyboardEnabled),
    for (final item in AppPreferences.shortcutLabels.entries)
      ListTile(
        dense: true,
        title: Text(item.value, style: AppStyles.of(context).body),
        trailing: Container(
          padding: SettingsStyles.shortcutPadding,
          decoration: SettingsStyles.of(context).shortcutDecoration,
          child: Text(
            shortcutLabel(prefs.shortcuts[item.key]!),
            style: AppStyles.of(context).bodySmall,
          ),
        ),
        onTap: () => editShortcut(item.key),
      ),
    const SizedBox(height: 8),
    Text(
      '点击操作录入按键，支持 Ctrl / Alt / Shift / Command 组合；输入文字时不会触发。',
      style: AppStyles.of(context).micro,
    ),
  ]);
  Widget danmakuService() => section('弹幕服务', [
    TextField(
      controller: origin,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(labelText: '服务地址'),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: token,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(labelText: 'Token'),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: interval,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: '更新间隔 / 秒',
        helperText: '0 为关闭；30–3600 秒',
        helperMaxLines: 2,
      ),
    ),
    const SizedBox(height: 6),
    Text('Token 保存在系统安全存储，启用同步后随配置加密同步。', style: AppStyles.of(context).micro),
    const SizedBox(height: 10),
    Align(
      alignment: Alignment.centerRight,
      child: FilledButton(
        onPressed: loading || saving ? null : saveDanmaku,
        child: Text(saving ? '保存中…' : '保存弹幕服务'),
      ),
    ),
  ]);

  List<Widget Function()> synchronization() => [
    () => section('设备间同步', [
      TextField(
        controller: syncOrigin,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: '同步服务地址'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: syncToken,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: '同步 Token（至少 24 字符）'),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: loading || saving
                ? null
                : () => saveSync(synchronize: true),
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('立即同步'),
          ),
          TextButton(
            onPressed: loading || saving ? null : resetAssociation,
            child: const Text('重置同步关联'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        '同步全部视频的目录信息、设置（含 API Key）、远程来源及密码、收藏、匹配资料，以及远程视频的播放记录、海报、封面截图和已有译文。图片压缩后加密同步。视频文件、本地路径、本地视频的播放记录与抓帧封面留在本机；其他设备可查看本地视频条目并关联自己的文件。各设备填写相同的服务地址和 Token 即可加入。',
        style: AppStyles.of(context).micro,
      ),
      const SizedBox(height: 12),
      Text(
        '修改自动采用最新版本。播放进度定期保存；封面在暂停或退出时更新。外部应用打开的视频不加入影视库或观看记录。',
        style: AppStyles.of(context).micro,
      ),
    ]),
    () => Align(
      alignment: Alignment.centerRight,
      child: FilledButton.icon(
        onPressed: loading || saving ? null : saveSync,
        icon: const Icon(Icons.check_rounded, size: 18),
        label: Text(saving ? '保存中…' : '保存同步配置'),
      ),
    ),
  ];
  Widget about() => section('关于与维护', [
    const ListTile(
      leading: Icon(Icons.play_circle_outline_rounded),
      title: Text('映库 · AIPlayer'),
      subtitle: Text('0.5.23 · 个人影视库'),
    ),
    ListTile(
      leading: const Icon(Icons.code_rounded),
      title: const Text('开源许可'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showLicensePage(
        context: context,
        applicationName: '映库',
        applicationVersion: '0.5.23',
      ),
    ),
    ListTile(
      leading: const Icon(Icons.receipt_long_outlined),
      title: const Text('运行日志'),
      subtitle: const Text('查看、搜索和复制诊断信息'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: const SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: LogsView(showBackButton: true),
              ),
            ),
          ),
        ),
      ),
    ),
    ListTile(
      key: const ValueKey('clear-caches'),
      leading: const Icon(Icons.cleaning_services_outlined),
      title: Text(_clearingCaches ? '清理中…' : '一键清除缓存'),
      enabled: !_confirmingCacheClear && !_clearingCaches,
      onTap: _confirmingCacheClear || _clearingCaches ? null : clearCaches,
    ),
    ListTile(
      leading: const Icon(Icons.restore_rounded),
      title: const Text('恢复播放与操作设置'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: resetPreferences,
    ),
  ]);

  Future<void> saveMetadata({bool test = false}) async {
    if (testingMetadata) return;
    setState(() => testingMetadata = true);
    try {
      final key = tmdbKey.text.trim();
      AppLog.instance.rememberSecret(key);
      await model.secrets.write(key: 'tmdb.apiKey', value: key);
      model.store.markLocalModified('secret:tmdb.apiKey');
      model.store.setLocal(
        'metadataCredentialsRevision',
        DateTime.now().microsecondsSinceEpoch,
      );
      for (final source in model.sources) {
        final sourceId = source['id'];
        if (sourceId is String && sourceId.isNotEmpty) {
          model.catalog.invalidateDirectoryPreviews(sourceId);
        }
      }
      if (test) {
        if (key.isEmpty) throw const AppFailure('请先填写 TMDB API Key 或读取令牌。');
        final apiKey = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(key);
        await IoJsonTransport(inactivity: const Duration(seconds: 12)).send(
          Uri.https(
            'api.themoviedb.org',
            '/3/authentication',
            apiKey ? {'api_key': key} : null,
          ),
          headers: apiKey ? const {} : {'Authorization': 'Bearer $key'},
        );
      }
      model.changed();
      if (mounted) showGlassSuccess(context, test ? 'TMDB 连接成功' : '资料配置已保存');
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (mounted) setState(() => testingMetadata = false);
    }
  }

  Widget metadata() => section('作品资料', [
    select('自动识别', 'metadataStrategy', prefs.metadataStrategy, const [
      GlassOption('off', '关闭 · 仅手动匹配'),
      GlassOption('conservative', '严格 · 名称和季度唯一吻合'),
      GlassOption('balanced', '扩展 · 唯一相近名称'),
    ]),
    toggle(
      'AI 自动识别信息',
      'aiMetadataEnabled',
      prefs.aiMetadataEnabled,
      hint: '普通自动识别未匹配时，由 AI 解析文件名并核对检索结果；复用“AI 翻译”中的服务和模型。',
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: refreshingMetadata || prefs.metadataStrategy == 'off'
            ? null
            : () async {
                setState(() => refreshingMetadata = true);
                try {
                  await model.refreshMetadata();
                  if (mounted) showGlassSuccess(context, '资料识别完成');
                } catch (error) {
                  if (mounted) showFailure(context, error);
                } finally {
                  if (mounted) setState(() => refreshingMetadata = false);
                }
              },
        icon: const Icon(Icons.manage_search_rounded, size: 16),
        label: Text(refreshingMetadata ? '识别中…' : '识别未匹配的视频'),
      ),
    ),
    Text(
      '仅使用作品名、季度、集数和文件名，不上传视频、截图、完整路径或播放地址。',
      style: AppStyles.of(context).micro,
    ),
    const SizedBox(height: 12),
    TextField(
      controller: tmdbKey,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(
        labelText: 'TMDB API Key / 读取令牌',
        helperText: '填写 API Key（v3）或 API Read Access Token；安全保存，启用同步后加密同步。',
        helperMaxLines: 2,
      ),
    ),
    const SizedBox(height: 10),
    Row(
      children: [
        TextButton(
          onPressed: loading || testingMetadata
              ? null
              : () => saveMetadata(test: true),
          child: const Text('测试连接'),
        ),
        const Spacer(),
        FilledButton(
          onPressed: loading || testingMetadata ? null : saveMetadata,
          child: Text(testingMetadata ? '处理中…' : '保存'),
        ),
      ],
    ),
    const SizedBox(height: 6),
    Align(
      alignment: Alignment.centerLeft,
      child: Image.asset('assets/branding/tmdb.png', width: 56, height: 41),
    ),
    const SizedBox(height: 6),
    Text(
      'This product uses the TMDB API but is not endorsed or certified by TMDB.',
      style: AppStyles.of(context).tiny,
    ),
  ]);

  void _selectGroup(String id, int index) {
    NavigationRevealNotification.reveal(context);
    setState(() {
      group = id;
      query = '';
      _searchGeneration++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pages.hasClients) return;
      _pages.jumpToPage(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = <(String, String, IconData, String)>[
      (
        'general',
        '常规',
        Icons.tune_rounded,
        '外观 主题 浅色 深色 隐藏文件 文件夹 来源 资料 AI 自动识别 文件名 匹配 作品 信息 Bangumi TMDB API Key 海报 季度',
      ),
      (
        'playback',
        '播放',
        Icons.play_circle_outline_rounded,
        '倍速 音量 偏移 后台 自动播放 下一集 连播 硬解 续播 屏幕 控制栏 快进 全屏 横屏 竖屏 双击 三击 跳过 跳转 片头 分钟 秒 暂停 长按 亮度 滑动 快捷键 手势',
      ),
      (
        'subtitles',
        '字幕',
        Icons.subtitles_outlined,
        '语言 外挂 字号 缩放 颜色 位置 描边 偏移 繁体 简体',
      ),
      (
        'danmaku',
        '弹幕',
        Icons.chat_bubble_outline_rounded,
        '字号 不透明度 区域 密度 速度 屏蔽词 预设 过滤 正则 顶部 底部 滚动 服务 API Token 更新间隔',
      ),
      (
        'ai',
        'AI 翻译',
        Icons.translate_rounded,
        '字幕翻译 剧集标题 影视简介 语言 模型 加载 API Key',
      ),
      ('sync', '同步', Icons.sync_rounded, '设备 连接 服务 Token 冲突'),
      (
        'about',
        '关于',
        Icons.info_outline_rounded,
        '版本 许可 重置 恢复默认 日志 诊断 排查 错误 复制 缓存 清理 清除',
      ),
    ];
    List<Widget Function()> content(String id) => switch (id) {
      'general' => [appearance, metadata],
      'playback' => [playback, mobile ? gestures : keyboard],
      'subtitles' => [subtitles],
      'danmaku' => [danmaku, danmakuService],
      'ai' => [aiTranslation],
      'sync' => synchronization(),
      _ => [about],
    };
    final matches = groups
        .where(
          (g) => '${g.$2} ${g.$4}'.toLowerCase().contains(
            query.trim().toLowerCase(),
          ),
        )
        .toList();
    return LayoutBuilder(
      builder: (context, box) {
        final desktop = MediaQuery.sizeOf(context).width >= 1000;
        final inset = desktop
            ? GlassMetrics.desktopPageInset
            : (box.maxWidth < 600 ? 12.0 : 20.0);
        Widget scrolling(Key key, List<Widget Function()> sections) =>
            ListView.separated(
              key: key,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: sections.length,
              itemBuilder: (_, index) => _buildSection(sections[index]),
              separatorBuilder: (_, _) => const SizedBox(height: 12),
            );
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: desktop ? double.infinity : 880,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                inset,
                GlassMetrics.pageTopPadding(context),
                inset,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SearchHeader(
                    key: ValueKey(_searchGeneration),
                    title: '设置',
                    hint: '搜索设置',
                    onChanged: (v) => setState(() => query = v),
                  ),
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < groups.length; i++)
                          Padding(
                            key: _chipKeys.putIfAbsent(
                              groups[i].$1,
                              GlobalKey.new,
                            ),
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(groups[i].$2),
                              avatar: Icon(groups[i].$3, size: 17),
                              showCheckmark: false,
                              selected: group == groups[i].$1,
                              onSelected: (_) => _selectGroup(groups[i].$1, i),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (loading) const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: query.trim().isNotEmpty
                        ? scrolling(
                            ValueKey('settings-search:${query.trim()}'),
                            [
                              if (matches.isEmpty)
                                () => const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Text('没有匹配的设置'),
                                ),
                              for (final item in matches) ...content(item.$1),
                            ],
                          )
                        : PageView.builder(
                            key: const ValueKey('settings-pages'),
                            controller: _pages,
                            itemCount: groups.length,
                            onPageChanged: (index) {
                              NavigationRevealNotification.reveal(context);
                              setState(() => group = groups[index].$1);
                              final chip = _chipKeys[group]?.currentContext;
                              if (chip != null) {
                                Scrollable.ensureVisible(
                                  chip,
                                  duration: MotionScope.duration(context),
                                  alignment: .5,
                                );
                              }
                            },
                            itemBuilder: (_, index) => scrolling(
                              PageStorageKey('settings-${groups[index].$1}'),
                              content(groups[index].$1),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GestureSeekDurationDialog extends StatefulWidget {
  final int initialSeconds;
  const _GestureSeekDurationDialog({required this.initialSeconds});

  @override
  State<_GestureSeekDurationDialog> createState() =>
      _GestureSeekDurationDialogState();
}

class _GestureSeekDurationDialogState
    extends State<_GestureSeekDurationDialog> {
  late final minutes = TextEditingController(
    text: '${widget.initialSeconds ~/ 60}',
  );
  late final seconds = TextEditingController(
    text: '${widget.initialSeconds % 60}',
  );
  String? error;

  @override
  void dispose() {
    minutes.dispose();
    seconds.dispose();
    super.dispose();
  }

  void save() {
    final minuteValue = int.tryParse(minutes.text);
    final secondValue = int.tryParse(seconds.text);
    if (minuteValue == null ||
        secondValue == null ||
        minuteValue < 0 ||
        secondValue < 0 ||
        secondValue > 59 ||
        minuteValue * 60 + secondValue < 1 ||
        minuteValue * 60 + secondValue > 3600) {
      setState(() => error = '请输入 1 秒至 60 分钟，秒数须为 0–59。');
      return;
    }
    Navigator.pop(context, minuteValue * 60 + secondValue);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    titlePadding: GlassMetrics.dialogTitlePadding,
    contentPadding: GlassMetrics.dialogContentPadding,
    actionsPadding: GlassMetrics.dialogActionsPadding,
    title: const Text('手势跳转时间'),
    scrollable: true,
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('向前 / 向后跳过使用这段时长；跳到指定位置使用从视频开始计算的这个时间。'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: minutes,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(2),
                  ],
                  decoration: const InputDecoration(labelText: '分钟'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: seconds,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(2),
                  ],
                  decoration: const InputDecoration(labelText: '秒'),
                  onSubmitted: (_) => save(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            error ?? '范围：1 秒至 60 分钟。默认：1 分 29 秒。',
            style: error == null
                ? AppStyles.of(context).caption
                : AppStyles.of(context).errorCaption,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: save, child: const Text('保存')),
    ],
  );
}

class _PreferenceSlider extends StatefulWidget {
  final String label, suffix;
  final double value, min, max;
  final int? divisions;
  final int decimals;
  final ValueChanged<double> onChanged;
  const _PreferenceSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.suffix = '',
    this.divisions,
    this.decimals = 0,
  });
  @override
  State<_PreferenceSlider> createState() => _PreferenceSliderState();
}

class _PreferenceSliderState extends State<_PreferenceSlider> {
  double? draft;
  @override
  Widget build(BuildContext context) {
    final value = draft ?? widget.value;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.label, style: AppStyles.of(context).body),
              ),
              Text(
                '${value.toStringAsFixed(widget.decimals)}${widget.suffix}',
                style: AppStyles.of(context).caption,
              ),
            ],
          ),
          Slider(
            value: value.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: '${value.toStringAsFixed(widget.decimals)}${widget.suffix}',
            onChanged: (v) => setState(() => draft = v),
            onChangeEnd: (v) {
              setState(() => draft = null);
              widget.onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}

String shortcutLabel(String value) => value
    .replaceAll('None', '未分配')
    .replaceAll('Space', '空格')
    .replaceAll('ArrowLeft', '←')
    .replaceAll('ArrowRight', '→')
    .replaceAll('ArrowUp', '↑')
    .replaceAll('ArrowDown', '↓')
    .replaceAll('Escape', 'Esc')
    .replaceAll('Comma', ',')
    .replaceAll('Period', '.')
    .replaceAll('Meta', '⌘');

class _ShortcutDialog extends StatefulWidget {
  final String title, initial;
  const _ShortcutDialog({required this.title, required this.initial});
  @override
  State<_ShortcutDialog> createState() => _ShortcutDialogState();
}

class _ShortcutDialogState extends State<_ShortcutDialog> {
  late String value = widget.initial;
  KeyEventResult capture(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    final names = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.space: 'Space',
      LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
      LogicalKeyboardKey.arrowRight: 'ArrowRight',
      LogicalKeyboardKey.arrowUp: 'ArrowUp',
      LogicalKeyboardKey.arrowDown: 'ArrowDown',
      LogicalKeyboardKey.escape: 'Escape',
      LogicalKeyboardKey.comma: 'Comma',
      LogicalKeyboardKey.period: 'Period',
      LogicalKeyboardKey.enter: 'Enter',
      LogicalKeyboardKey.backspace: 'Backspace',
      LogicalKeyboardKey.home: 'Home',
      LogicalKeyboardKey.end: 'End',
    };
    final base = names[key] ?? key.keyLabel.toUpperCase();
    final keyboard = HardwareKeyboard.instance;
    final candidate = [
      if (keyboard.isControlPressed) 'Ctrl',
      if (keyboard.isAltPressed) 'Alt',
      if (keyboard.isShiftPressed) 'Shift',
      if (keyboard.isMetaPressed) 'Meta',
      base,
    ].join('+');
    final normalized = AppPreferences.normalizeShortcut(candidate);
    if (normalized != null) setState(() => value = normalized);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    titlePadding: GlassMetrics.dialogTitlePadding,
    contentPadding: GlassMetrics.dialogContentPadding,
    actionsPadding: GlassMetrics.dialogActionsPadding,
    title: Text(widget.title),
    content: Focus(
      autofocus: true,
      onKeyEvent: capture,
      child: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('按下要使用的按键或组合键'),
            const SizedBox(height: 8),
            GlassSurface(
              blur: 0,
              padding: const EdgeInsets.all(8),
              child: Text(
                shortcutLabel(value),
                style: SettingsStyles.of(context).shortcutPreview,
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, 'None'),
        child: const Text('取消分配'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, value),
        child: const Text('保存'),
      ),
    ],
  );
}
