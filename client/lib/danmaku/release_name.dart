class ReleaseName {
  final String anime, season, episode;
  const ReleaseName(this.anime, [this.season = '', this.episode = '']);
  String get matchName {
    if (!RegExp(
      r'^(?:[CSO])?\d{1,5}$',
      caseSensitive: false,
    ).hasMatch(episode)) {
      return anime;
    }
    if (int.tryParse(episode) != null) {
      final s = RegExp(r'^[1-9]\d?$').hasMatch(season) ? season : '1';
      return '$anime S${s.padLeft(2, '0')}E${episode.padLeft(2, '0')}';
    }
    return '$anime $episode';
  }
}

ReleaseName parseReleaseName(String filename) {
  var title = filename.split(RegExp(r'[/\\]')).last;
  try {
    title = Uri.decodeComponent(title);
  } catch (_) {
    /* literal name */
  }
  title = title.replaceAll('［', '[').replaceAll('］', ']');
  title = title
      .replaceFirst(
        RegExp(
          r'\.(mkv|mp4|webm|avi|mov|m4v|ts|m2ts|flv|wmv)$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll('_', ' ');
  var season = '', episode = '';
  final ordinal = RegExp(
    r'\b(\d{1,2})(?:st|nd|rd|th)\s+Season\b',
    caseSensitive: false,
  ).firstMatch(title);
  if (ordinal != null) {
    season = '${int.parse(ordinal[1]!)}';
    title = title.replaceRange(ordinal.start, ordinal.end, ' ');
  }

  final marker = RegExp(
    r'(?:^|[\s.([_-])(?:Season[ .-]*|S)(\d{1,2})(?=$|[\s.\])_-])|第\s*([一二三四五六七八九十两\d]{1,3})\s*[季部期]',
    caseSensitive: false,
  ).firstMatch(title);
  if (marker != null) {
    final value = marker[1] ?? marker[2]!;
    const digits = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    final parts = value.split('十');
    final n =
        int.tryParse(value) ??
        (parts.length == 2
            ? (digits[parts[0]] ?? 1) * 10 + (digits[parts[1]] ?? 0)
            : digits[value]);
    if (n != null && n > 0 && n < 100) season = '$n';
    title = title.replaceRange(marker.start, marker.end, ' ');
  }
  final patterns = [
    r'第\s*(\d{1,2})\s*[季部期]\s*第\s*(\d{1,4})\s*[话話集]',
    r'(?:^|[\s.\[(-])S(\d{1,2})[ .-]*E(\d{1,4})(?:v\d+)?(?=$|[\s.\])_-])',
    r'(?:^|[\s.\[(-])(?:EP?|Episode)[ .-]*(\d{1,4})(?:v\d+)?(?=$|[\s.\])_-])',
    r'第\s*(\d{1,4})\s*[话話集]',
    r'\s-\s*(\d{1,4})(?:v\d+)?(?=$|[\s.\](_-])',
    r'[\[(](\d{1,3})(?:v\d+)?[\])]',
    r'(?:\s+|(?<!\d)\.)(\d{1,3})(?:v\d+)?(?=$|\s*\[[^\]]+\]$)',
  ];
  for (var i = 0; i < patterns.length; i++) {
    final m = RegExp(patterns[i], caseSensitive: false).firstMatch(title);
    if (m == null) continue;
    // The trailing number in H.264 / H.265 describes the codec, not an episode.
    if (i == patterns.length - 1 &&
        (m[1] == '264' || m[1] == '265') &&
        RegExp(
          r'\bH$',
          caseSensitive: false,
        ).hasMatch(title.substring(0, m.start))) {
      continue;
    }
    if (i < 2) season = '${int.parse(m[1]!)}';
    episode = '${int.parse(m[i < 2 ? 2 : 1]!)}';
    title = title.substring(0, m.start);
    break;
  }
  // Explicit special episode tokens are kept instead of guessed as ordinary episodes.
  if (episode.isEmpty) {
    final special = RegExp(
      r'(?:^|[\s.\[-])(SP|OVA|OAD|[CSO])(\d{1,5})(?=$|[\s.\]])',
      caseSensitive: false,
    ).firstMatch(title);
    if (special != null) {
      final kind = special[1]!.toUpperCase();
      episode =
          '${kind == 'SP'
              ? 'S'
              : kind == 'OVA' || kind == 'OAD'
              ? 'O'
              : kind}${int.parse(special[2]!)}';
      title = title.substring(0, special.start);
    }
  }
  final without = title.replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】'), ' ').trim();
  final bracketTitles = RegExp(r'\[([^\]]+)\]|【([^】]+)】')
      .allMatches(title)
      .map((m) => m[1] ?? m[2]!)
      .where((s) => RegExp(r'[\u3040-\u30ff\u3400-\u9fff]').hasMatch(s));
  title = without.isNotEmpty
      ? without
      : bracketTitles.isNotEmpty
      ? bracketTitles.first
      : title;
  title = title
      .replaceFirst(
        RegExp(
          r'\b(?:1080[pi]|720p|2160p|480p|4k|HEVC|AVC|H[ .]?26[45]|x26[45]|WEB[ .-]?DL|BluRay|BDRip|10bit|AAC|FLAC)\b.*$',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll('.', ' ')
      .replaceAll(RegExp(r'[\s\[\]()-]+$'), '')
      .replaceAll(RegExp(r'^[-\s]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final roman = RegExp(
    r'\s+(II|III|IV|V|VI)$',
    caseSensitive: false,
  ).firstMatch(title);
  if (season.isEmpty && roman != null && episode.isNotEmpty) {
    const numbers = {'II': '2', 'III': '3', 'IV': '4', 'V': '5', 'VI': '6'};
    season = numbers[roman[1]!.toUpperCase()]!;
    title = title.substring(0, roman.start).trim();
  }
  return ReleaseName(title, season, episode);
}
