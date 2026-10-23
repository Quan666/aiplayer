import 'media_presentation.dart';
import 'store.dart';

String _number(Object? value, {String fallback = ''}) {
  final text = '${value ?? ''}'.trim();
  if (text.isEmpty) return fallback;
  final number = num.tryParse(text);
  if (number == null || !number.isFinite) return text.toLowerCase();
  return number == number.roundToDouble() ? '${number.toInt()}' : '$number';
}

/// A season/episode is one navigation destination. Alternate files remain in
/// the group, with their own IDs, technical information and watch progress.
String mediaEpisodeKey(SyncRecord media) {
  final episode = _number(media.data['episode']);
  if (episode.isEmpty) return 'file:${media.id}';
  return '${mediaSeriesKey(media)}:${_number(media.data['season'], fallback: '1')}:$episode';
}

Map<String, List<SyncRecord>> groupMediaEpisodes(Iterable<SyncRecord> media) {
  final groups = <String, List<SyncRecord>>{};
  for (final item in media) {
    (groups[mediaEpisodeKey(item)] ??= []).add(item);
  }
  return groups;
}

List<SyncRecord> uniqueMediaEpisodes(
  Iterable<SyncRecord> media, {
  String? preferredId,
  bool Function(SyncRecord)? playable,
}) => [
  for (final versions in groupMediaEpisodes(media).values)
    (List<SyncRecord>.of(versions)..sort((a, b) {
          if (a.id == preferredId) return -1;
          if (b.id == preferredId) return 1;
          final available =
              (playable?.call(b) == true ? 1 : 0) -
              (playable?.call(a) == true ? 1 : 0);
          if (available != 0) return available;
          int detail(SyncRecord item) => [
            'episodeTitle',
            'metadataTitle',
            'poster',
            'bangumiId',
            'tmdbId',
          ].where((key) => '${item.data[key] ?? ''}'.isNotEmpty).length;
          final quality = detail(b).compareTo(detail(a));
          if (quality != 0) return quality;
          final recent = b.modifiedAt.compareTo(a.modifiedAt);
          return recent != 0 ? recent : a.id.compareTo(b.id);
        }))
        .first,
];
