import 'store.dart';

String _text(Object? value) => value?.toString().trim() ?? '';

String mediaSeasonLabel(Object? value, {Object? totalSeasons}) {
  final season = _text(value);
  if (season.isEmpty) return '';
  final number = int.tryParse(season);
  if (number == 0) return '特别篇';
  if (number == 1 && (num.tryParse(_text(totalSeasons)) ?? 0) <= 1) return '';
  return '第 ${number ?? season} 季';
}

/// File names remain available in details; playback surfaces prefer a verified
/// catalogue title, followed by the locally parsed title for episodic releases.
String mediaSeriesName(SyncRecord record) {
  final identified = _text(record.data['metadataTitle']);
  if (identified.isNotEmpty) return identified;
  final series = _text(record.data['series']);
  if (series.isNotEmpty &&
      series != '未分类' &&
      (_text(record.data['episode']).isNotEmpty ||
          record.data['bangumiId'] != null ||
          record.data['tmdbId'] != null)) {
    return series;
  }
  return _text(record.data['title']);
}

String mediaEpisodeLabel(SyncRecord record, {String? episodeTitle}) {
  final season = mediaSeasonLabel(
    record.data['season'],
    totalSeasons: record.data['totalSeasons'],
  );
  final episode = _text(record.data['episode']);
  final subtitle = (episodeTitle ?? _text(record.data['episodeTitle'])).trim();
  return [
    if (season.isNotEmpty) season,
    if (episode.isNotEmpty)
      RegExp(r'^\d+(?:\.\d+)?$').hasMatch(episode) ? '第 $episode 集' : episode,
    if (subtitle.isNotEmpty) subtitle,
  ].join(' · ');
}

String mediaDisplayTitle(SyncRecord record, {String? episodeTitle}) {
  final name = mediaSeriesName(record);
  final episode = mediaEpisodeLabel(record, episodeTitle: episodeTitle);
  return episode.isEmpty ? name : '$name · $episode';
}

/// A display grouping only. Individual video/version progress is never merged.
String mediaSeriesKey(SyncRecord record) {
  final rawSeason = _text(record.data['season']);
  final number = num.tryParse(rawSeason);
  final season = rawSeason.isEmpty
      ? '1'
      : number != null && number.isFinite && number == number.roundToDouble()
      ? '${number.toInt()}'
      : rawSeason;
  if (record.data['tmdbId'] != null) {
    return 'tmdb:${record.data['metadataType'] ?? 'tv'}:${record.data['tmdbId']}:$season';
  }
  if (record.data['bangumiId'] != null) {
    return 'bangumi:${record.data['bangumiId']}:$season';
  }
  final series = _text(
    record.data['series'],
  ).toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  if (_text(record.data['episode']).isNotEmpty &&
      series.isNotEmpty &&
      series != '未分类') {
    return 'parsed:$series:${season.isEmpty ? '1' : season}';
  }
  return 'file:${record.id}';
}

String playbackTime(double seconds) {
  final value = seconds.isFinite ? seconds.clamp(0, 86400000).floor() : 0;
  String two(int n) => n.toString().padLeft(2, '0');
  return value >= 3600
      ? '${value ~/ 3600}:${two(value ~/ 60 % 60)}:${two(value % 60)}'
      : '${two(value ~/ 60)}:${two(value % 60)}';
}

String playbackProgressLabel(
  Map<String, dynamic>? progress, {
  double duration = 0,
}) {
  final position = (progress?['position'] as num?)?.toDouble() ?? 0;
  final savedDuration = (progress?['duration'] as num?)?.toDouble() ?? duration;
  if (position <= 0) return '';
  return '${playbackTime(position)} / ${playbackTime(savedDuration)}'
      '${savedDuration > 0 ? ' · ${(position / savedDuration * 100).clamp(0, 100).round()}%' : ''}';
}

/// Shared catalogue facts and availability for both library and source views.
/// Alternate encodes count as files, never as additional episodes.
class MediaCollectionDetails {
  final String title, poster, summary, season, year, provider;
  final double? rating;
  final int? totalEpisodes, totalSeasons;
  final int availableEpisodes, videoCount;
  final List<String> genres;
  const MediaCollectionDetails({
    required this.title,
    this.poster = '',
    this.summary = '',
    this.season = '',
    this.year = '',
    this.provider = '',
    this.rating,
    this.totalEpisodes,
    this.totalSeasons,
    this.availableEpisodes = 0,
    this.videoCount = 0,
    this.genres = const [],
  });

  factory MediaCollectionDetails.fromRecords(Iterable<SyncRecord> records) {
    final values = records.toList()..sort(compareMediaEpisodes);
    if (values.isEmpty) return const MediaCollectionDetails(title: '影视资料');
    final info = <String, dynamic>{};
    // A partially identified first episode must not hide another episode's facts.
    for (final item in values.reversed) {
      for (final entry in item.data.entries) {
        if (entry.value != null && _text(entry.value).isNotEmpty) {
          info[entry.key] = entry.value;
        }
      }
    }
    final date = _text(info['airDate']);
    final episodes = <String>{};
    for (final item in values) {
      final episode = _text(item.data['episode']);
      if (episode.isNotEmpty) {
        episodes.add(
          '${_text(item.data['season']).isEmpty ? '1' : item.data['season']}:$episode',
        );
      }
    }
    return MediaCollectionDetails(
      title: _text(info['metadataTitle']).isNotEmpty
          ? _text(info['metadataTitle'])
          : mediaSeriesName(values.first),
      poster: _text(info['poster']),
      summary: _text(info['summary']),
      season: _text(info['season']),
      year: date.length >= 4 ? date.substring(0, 4) : '',
      provider: _text(info['metadataProvider']),
      rating: double.tryParse(_text(info['rating'])),
      totalEpisodes: num.tryParse(_text(info['totalEpisodes']))?.toInt(),
      totalSeasons: num.tryParse(_text(info['totalSeasons']))?.toInt(),
      availableEpisodes: episodes.length,
      videoCount: values.length,
      genres: List<String>.unmodifiable(
        (info['genres'] as List?)?.whereType<String>() ?? const [],
      ),
    );
  }

  String get availability => availableEpisodes == 0
      ? '$videoCount 个视频'
      : '已收录 $availableEpisodes 集${videoCount > availableEpisodes ? ' · $videoCount 个视频' : ''}';

  String get seasonLabel =>
      mediaSeasonLabel(season, totalSeasons: totalSeasons);
}

int compareMediaEpisodes(SyncRecord a, SyncRecord b) {
  int compare(Object? a, Object? b) {
    final x = double.tryParse(_text(a)), y = double.tryParse(_text(b));
    if (x != null && y != null) return x.compareTo(y);
    return _text(a).compareTo(_text(b));
  }

  final season = compare(a.data['season'] ?? '1', b.data['season'] ?? '1');
  if (season != 0) return season;
  final episode = compare(a.data['episode'], b.data['episode']);
  return episode != 0
      ? episode
      : _text(a.data['title']).compareTo(_text(b.data['title']));
}
