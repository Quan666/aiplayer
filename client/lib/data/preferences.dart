/// Player preferences, also included in the optional synchronization profile. API credentials and source locations are
/// deliberately outside this schema and never reset with player preferences.
class AppPreferences {
  final Map<String, dynamic> _values;
  AppPreferences(Map<String, dynamic> values)
    : _values = Map.unmodifiable(values);

  static const defaults = <String, dynamic>{
    'autoPlay': true,
    'autoNextEpisode': true,
    'enterFullscreen': true,
    'autoRotateFullscreen': true,
    'pinchToZoom': true,
    'edgeDoubleTapSeek': false,
    'subtitleSimplify': false,
    'highRefreshRate': false,
    'hideNavigationOnScroll': true,
    'resumePlayback': true,
    'hardwareDecoding': true,
    'keepScreenOn': true,
    'pauseOnBackground': true,
    'playbackRate': 1.0,
    'volume': 100.0,
    'audioDelay': 0.0,
    'videoFit': 'contain',
    'seekStepSeconds': 10,
    'controlsHideSeconds': 3,
    'subtitlesEnabled': true,
    'autoLoadExternalSubtitles': true,
    'subtitleLanguage': 'zh-Hans',
    'subtitleScale': 1.0,
    'subtitleDelay': 0.0,
    'subtitlePosition': 100.0,
    'subtitleColor': '#FFFFFF',
    'subtitleBorderSize': 2.0,
    'danmuVisible': true,
    'danmuFontSize': 18.0,
    'danmuOpacity': .6,
    'danmuArea': .65,
    'danmuDensity': .7,
    'danmuSpeed': 1.0,
    'danmuScroll': true,
    'danmuTop': true,
    'danmuBottom': true,
    'danmuPresetFilter': true,
    'danmuBlockedWords': '',
    'refreshInterval': 30,
    'gesturesEnabled': true,
    'doubleTapAction': 'playPause',
    'tripleTapAction': 'skipForward',
    'tripleTapLeftAction': 'skipBackward',
    'tripleTapRightAction': 'skipForward',
    'gestureSeekSeconds': 89,
    'horizontalSeek': true,
    'verticalVolume': true,
    'verticalBrightness': true,
    'longPressSpeed': true,
    'longPressRate': 2.0,
    'keyboardEnabled': true,
    'animations': true,
    'autoDiscover': false,
    'hideHiddenFiles': true,
    'metadataProvider': 'bangumi',
    'metadataStrategy': 'conservative',
    'aiMetadataEnabled': false,
    'tmdbNameAssist': true,
  };
  static const defaultShortcuts = <String, String>{
    'playPause': 'Space',
    'seekBackward': 'ArrowLeft',
    'seekForward': 'ArrowRight',
    'volumeUp': 'ArrowUp',
    'volumeDown': 'ArrowDown',
    'mute': 'M',
    'fullscreen': 'F',
    'exitFullscreen': 'Escape',
    'subtitles': 'S',
    'danmaku': 'D',
    'settings': 'Comma',
    // Keep new defaults after existing bindings so stored custom keys win.
    'skipForward': 'J',
    'skipBackward': 'Shift+J',
    'playPauseAlternate': 'K',
  };
  static const shortcutLabels = <String, String>{
    'playPause': '播放 / 暂停',
    'playPauseAlternate': '播放 / 暂停（备用）',
    'seekBackward': '后退',
    'seekForward': '快进',
    'skipForward': '前进 89 秒',
    'skipBackward': '后退 89 秒',
    'volumeUp': '增大音量',
    'volumeDown': '减小音量',
    'mute': '静音',
    'fullscreen': '全屏',
    'exitFullscreen': '退出全屏',
    'subtitles': '字幕开关',
    'danmaku': '弹幕开关',
    'settings': '播放器设置',
  };
  static const _ranges = <String, (double, double)>{
    'playbackRate': (.25, 3),
    'volume': (0, 100),
    'audioDelay': (-10, 10),
    'seekStepSeconds': (5, 120),
    'gestureSeekSeconds': (1, 3600),
    'controlsHideSeconds': (0, 15),
    'subtitleScale': (.5, 3),
    'subtitleDelay': (-60, 60),
    'subtitlePosition': (0, 100),
    'subtitleBorderSize': (0, 6),
    'danmuFontSize': (12, 48),
    'danmuOpacity': (.1, 1),
    'danmuArea': (.2, 1),
    'danmuDensity': (.1, 1),
    'danmuSpeed': (.5, 2),
    'refreshInterval': (0, 3600),
    'longPressRate': (1.25, 3),
  };
  static const tapActions = <String>[
    'playPause',
    'seek',
    'skipForward',
    'skipBackward',
    'seekTo',
    'fullscreen',
    'none',
  ];
  static const _enums = <String, List<String>>{
    'metadataProvider': ['bangumi', 'tmdb'],
    'metadataStrategy': ['off', 'conservative', 'balanced'],
    'videoFit': ['contain', 'cover', 'fill'],
    'doubleTapAction': tapActions,
    'tripleTapAction': tapActions,
    'tripleTapLeftAction': tapActions,
    'tripleTapRightAction': tapActions,
    'subtitleLanguage': ['auto', 'zh', 'zh-Hans', 'zh-Hant', 'en', 'ja'],
    'subtitleColor': ['#FFFFFF', '#FFE066', '#8DE0FF'],
  };

  bool _bool(String key) =>
      _values[key] is bool ? _values[key] as bool : defaults[key] as bool;
  double _number(String key) {
    final value = _values[key];
    final range = _ranges[key]!;
    return value is num && value.isFinite
        ? value.toDouble().clamp(range.$1, range.$2)
        : (defaults[key] as num).toDouble();
  }

  String _choice(String key) => _enums[key]!.contains(_values[key])
      ? _values[key] as String
      : defaults[key] as String;

  bool get autoPlay => _bool('autoPlay');
  bool get autoNextEpisode => _bool('autoNextEpisode');
  bool get autoRotateFullscreen => _bool('autoRotateFullscreen');
  bool get pinchToZoom => _bool('pinchToZoom');
  bool get edgeDoubleTapSeek => _bool('edgeDoubleTapSeek');
  bool get subtitleSimplify => _bool('subtitleSimplify');
  bool get enterFullscreen => _bool('enterFullscreen');
  bool get highRefreshRate => _bool('highRefreshRate');
  bool get hideNavigationOnScroll => true;
  bool get resumePlayback => _bool('resumePlayback');
  bool get hardwareDecoding => _bool('hardwareDecoding');
  bool get keepScreenOn => _bool('keepScreenOn');
  bool get pauseOnBackground => _bool('pauseOnBackground');
  double get playbackRate => _number('playbackRate');
  double get volume => _number('volume');
  double get audioDelay => _number('audioDelay');
  String get videoFit => _choice('videoFit');
  int get seekStepSeconds => _number('seekStepSeconds').round();
  int get controlsHideSeconds => _number('controlsHideSeconds').round();
  bool get subtitlesEnabled => _bool('subtitlesEnabled');
  bool get autoLoadExternalSubtitles => _bool('autoLoadExternalSubtitles');
  String get subtitleLanguage => _choice('subtitleLanguage');
  double get subtitleScale => _number('subtitleScale');
  double get subtitleDelay => _number('subtitleDelay');
  double get subtitlePosition => _number('subtitlePosition');
  String get subtitleColor => _choice('subtitleColor');
  double get subtitleBorderSize => _number('subtitleBorderSize');
  bool get danmuVisible => _bool('danmuVisible');
  double get danmuFontSize => _number('danmuFontSize');
  double get danmuOpacity => _number('danmuOpacity');
  double get danmuArea => _number('danmuArea');
  double get danmuDensity => _number('danmuDensity');
  double get danmuSpeed => _number('danmuSpeed');
  bool get danmuScroll => _bool('danmuScroll');
  bool get danmuTop => _bool('danmuTop');
  bool get danmuBottom => _bool('danmuBottom');
  bool get danmuPresetFilter => _bool('danmuPresetFilter');
  String get danmuBlockedWords => _values['danmuBlockedWords'] is String
      ? (_values['danmuBlockedWords'] as String).substring(
          0,
          (_values['danmuBlockedWords'] as String).length.clamp(0, 4000),
        )
      : '';
  int get refreshInterval {
    final value = _number('refreshInterval').round();
    return value == 0 ? 0 : value.clamp(30, 3600);
  }

  bool get gesturesEnabled => _bool('gesturesEnabled');
  String get doubleTapAction => _choice('doubleTapAction');

  /// The original preference now controls the center third of the player.
  String get tripleTapAction => _choice('tripleTapAction');
  String get tripleTapLeftAction =>
      _regionalTripleTapAction('tripleTapLeftAction');
  String get tripleTapRightAction =>
      _regionalTripleTapAction('tripleTapRightAction');
  bool get hasTripleTapAction =>
      tripleTapLeftAction != 'none' ||
      tripleTapAction != 'none' ||
      tripleTapRightAction != 'none';

  String _regionalTripleTapAction(String key) {
    final stored = _values[key];
    if (tapActions.contains(stored)) return stored as String;
    // Preserve a custom full-screen action until regional settings are saved.
    // The old default adopts the new left/backward and right/forward behavior.
    final legacy = _values['tripleTapAction'];
    if (!_values.containsKey('tripleTapLeftAction') &&
        !_values.containsKey('tripleTapRightAction') &&
        tapActions.contains(legacy) &&
        legacy != defaults['tripleTapAction']) {
      return legacy as String;
    }
    return defaults[key] as String;
  }

  int get gestureSeekSeconds => _number('gestureSeekSeconds').round();
  bool get horizontalSeek => _bool('horizontalSeek');
  bool get verticalVolume => _bool('verticalVolume');
  bool get verticalBrightness => _bool('verticalBrightness');
  bool get longPressSpeed => _bool('longPressSpeed');
  double get longPressRate => _number('longPressRate');
  bool get keyboardEnabled => _bool('keyboardEnabled');
  bool get animations => true;
  bool get autoDiscover => false;
  bool get hideHiddenFiles => _bool('hideHiddenFiles');
  bool get tmdbNameAssist => _bool('tmdbNameAssist');
  String get metadataProvider => _choice('metadataProvider');
  String get metadataStrategy => _choice('metadataStrategy');
  bool get aiMetadataEnabled => _bool('aiMetadataEnabled');

  Map<String, String> get shortcuts {
    final stored = _values['shortcuts'];
    if (stored is! Map) return Map.of(defaultShortcuts);
    final result = Map.of(defaultShortcuts);
    for (final action in result.keys.toList()) {
      final key = normalizeShortcut(stored[action]);
      if (key != null) result[action] = key;
    }
    // Corrupt/old storage must not make one key invoke two actions.
    final used = <String>{};
    for (final action in result.keys.toList()) {
      final key = result[action]!;
      if (key != 'None' && !used.add(key)) result[action] = 'None';
    }
    return result;
  }

  static String? normalizeShortcut(Object? input) {
    if (input is! String) return null;
    if (input == 'None') return input;
    final parts = input.split('+');
    final key = parts.last;
    final validKey =
        const [
          'Space',
          'ArrowLeft',
          'ArrowRight',
          'ArrowUp',
          'ArrowDown',
          'Escape',
          'Comma',
          'Period',
          'Enter',
          'Backspace',
          'Home',
          'End',
        ].contains(key) ||
        RegExp(r'^[A-Z0-9]$').hasMatch(key) ||
        RegExp(r'^F([1-9]|1[0-2])$').hasMatch(key);
    if (!validKey) return null;
    final modifiers = parts.take(parts.length - 1).toSet();
    if (modifiers.length != parts.length - 1 ||
        modifiers.any(
          (m) => !const ['Ctrl', 'Alt', 'Shift', 'Meta'].contains(m),
        )) {
      return null;
    }
    return [
      ...['Ctrl', 'Alt', 'Shift', 'Meta'].where(modifiers.contains),
      key,
    ].join('+');
  }

  /// Reject invalid writes instead of storing controls that cannot be applied.
  Map<String, dynamic> checkedPatch(Map<String, dynamic> patch) {
    final result = <String, dynamic>{};
    for (final entry in patch.entries) {
      final key = entry.key, value = entry.value;
      if (key == 'shortcuts') {
        if (value is! Map) throw ArgumentError('快捷键格式无效');
        final next = shortcuts;
        for (final item in value.entries) {
          final normalized = normalizeShortcut(item.value);
          if (!next.containsKey(item.key) || normalized == null) {
            throw ArgumentError('快捷键格式无效');
          }
          next[item.key as String] = normalized;
        }
        final used = <String>{};
        for (final item in next.entries) {
          if (item.value != 'None' && !used.add(item.value)) {
            throw ArgumentError('快捷键已被其他操作使用');
          }
        }
        result[key] = next;
      } else if (!defaults.containsKey(key)) {
        throw ArgumentError('不支持的设置项');
      } else if (defaults[key] is bool) {
        if (value is! bool) throw ArgumentError('设置值必须为开关');
        result[key] = value;
      } else if (_ranges.containsKey(key)) {
        final range = _ranges[key]!;
        if (value is! num ||
            !value.isFinite ||
            value < range.$1 ||
            value > range.$2 ||
            (key == 'gestureSeekSeconds' && value != value.round()) ||
            (key == 'refreshInterval' && value != 0 && value < 30)) {
          throw ArgumentError('设置值超出范围');
        }
        result[key] = defaults[key] is int ? value.round() : value.toDouble();
      } else if (_enums.containsKey(key)) {
        if (!_enums[key]!.contains(value)) throw ArgumentError('无效的选项');
        result[key] = value;
      } else if (key == 'danmuBlockedWords') {
        if (value is! String || value.length > 4000) {
          throw ArgumentError('屏蔽词最多4000字');
        }
        result[key] = value;
      }
    }
    if (patch.keys.any(
      (key) =>
          key == 'tripleTapAction' ||
          key == 'tripleTapLeftAction' ||
          key == 'tripleTapRightAction',
    )) {
      // Materialize all regions together so editing the center cannot change
      // the inherited left/right actions of an existing installation.
      return {
        'tripleTapLeftAction': tripleTapLeftAction,
        'tripleTapAction': tripleTapAction,
        'tripleTapRightAction': tripleTapRightAction,
        ...result,
      };
    }
    return result;
  }
}
