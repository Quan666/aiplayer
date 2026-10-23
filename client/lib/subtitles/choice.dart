import 'package:path/path.dart' as p;

final _simplifiedChineseTag = RegExp(
  r'(^|[. _+&\-\[\]()])chs([. _+&\-\[\]()]|$)',
);
final _traditionalChineseTag = RegExp(
  r'(^|[. _+&\-\[\]()])cht([. _+&\-\[\]()]|$)',
);

/// Image tracks are rendered by the player but cannot be transformed as text.
/// Some containers only report the codec, without an explicit image flag.
bool isImageSubtitle({bool? image, String? codec}) =>
    image == true ||
    RegExp(r'pgs|dvd|dvb|hdmv', caseSensitive: false).hasMatch(codec ?? '');

/// Language hints from container metadata and subtitle names. Unknown Chinese
/// remains preferable to a foreign default track, without guessing its script.
String? chineseVariant(String? language, String? title) {
  final lang = (language ?? '').toLowerCase().replaceAll('_', '-');
  final name = (title ?? '').toLowerCase();
  final simplifiedTag = _simplifiedChineseTag.hasMatch(name);
  final traditionalTag = _traditionalChineseTag.hasMatch(name);
  final chinese =
      RegExp(r'^(zh|zho|chi)(-|$)').hasMatch(lang) ||
      RegExp(
        r'中文|汉语|漢語|国语|國語|华语|華語|简体|簡體|简中|簡中|繁体|繁體|繁中|chinese|mandarin',
      ).hasMatch(name) ||
      simplifiedTag ||
      traditionalTag;
  if (!chinese) return null;
  if (RegExp(r'(^|-)(hans|cn|sg)($|-)').hasMatch(lang) ||
      RegExp(r'简|簡|simplified').hasMatch(name) ||
      simplifiedTag) {
    return 'zh-Hans';
  }
  if (RegExp(r'(^|-)(hant|tw|hk|mo)($|-)').hasMatch(lang) ||
      RegExp(r'繁|traditional').hasMatch(name) ||
      traditionalTag) {
    return 'zh-Hant';
  }
  return 'zh';
}

int subtitleLanguageRank(
  String? language,
  String? title,
  String preference, {
  bool isDefault = false,
}) {
  final lang = (language ?? '').toLowerCase();
  final variant = chineseVariant(language, title);
  var score = 0;
  if (preference.startsWith('zh') && variant != null) {
    score = preference == 'zh' || preference == variant
        ? 30
        : variant == 'zh'
        ? 20
        : 10;
  } else if (['en', 'ja'].contains(preference) &&
      RegExp(
        preference == 'ja' ? r'^(ja|jpn)(-|$)' : r'^(en|eng)(-|$)',
      ).hasMatch(lang)) {
    score = 30;
  }
  return score + (isDefault ? 1 : 0);
}

/// An episode 1 subtitle must never match episode 10. Exact names outrank all
/// language hints; only a recognized language suffix may extend a video stem.
int externalSubtitleRank(
  String videoName,
  String subtitleName,
  String language,
) {
  final video = p.basenameWithoutExtension(videoName).toLowerCase();
  final subtitle = p.basenameWithoutExtension(subtitleName).toLowerCase();
  if (subtitle == video) return 1000;
  if (!subtitle.startsWith(video)) return -1;
  final suffix = subtitle.substring(video.length);
  if (!RegExp(r'^[. _+&\-]').hasMatch(suffix)) return -1;
  final parts = suffix
      .split(RegExp(r'[. _\-+&()\[\]]+'))
      .where((part) => part.isNotEmpty)
      .toList();
  const languages = {
    'zh',
    'zho',
    'chi',
    'hans',
    'hant',
    'chs',
    'cht',
    'sc',
    'tc',
    'en',
    'eng',
    'ja',
    'jpn',
    'cn',
    'tw',
    'hk',
    'mo',
    'sg',
    'jp',
    'us',
    'gb',
    '简体',
    '簡體',
    '简中',
    '簡中',
    '繁体',
    '繁體',
    '繁中',
    '中文',
    '双语',
    '雙語',
    'english',
    'chinese',
    'japanese',
  };
  const flags = {
    'forced',
    'default',
    'sdh',
    'cc',
    'signs',
    'songs',
    'full',
    'bilingual',
    'dual',
  };
  if (!parts.any(languages.contains) ||
      parts.any((part) => !languages.contains(part) && !flags.contains(part))) {
    return -1;
  }
  return 100 +
      subtitleLanguageRank(
        suffix.replaceFirst(RegExp(r'^[. _+&\-]+'), '').replaceAll('_', '-'),
        subtitleName,
        language,
      );
}

String mpvSubtitleLanguages(String preference) => switch (preference) {
  'zh-Hans' => 'zh-Hans,zh-CN,zh-SG,chi,zho,zh,zh-Hant',
  'zh-Hant' => 'zh-Hant,zh-TW,zh-HK,chi,zho,zh,zh-Hans',
  'zh' => 'zh,chi,zho,zh-Hans,zh-Hant',
  'en' => 'en,eng',
  'ja' => 'ja,jpn',
  _ => '',
};

bool shouldAutomaticallySimplifySubtitle(String? language, String? title) {
  final variant = chineseVariant(language, title);
  if (variant != null) return variant != 'zh-Hans';
  final code = (language ?? '').toLowerCase();
  if (code.isNotEmpty && code != 'auto' && code != 'und') return false;
  return !RegExp(
    r'日文|日本語|日本语|英文|japanese|english|(^|[. _\-])(ja|jpn|jp|en|eng)([. _\-]|$)',
    caseSensitive: false,
  ).hasMatch(title ?? '');
}
