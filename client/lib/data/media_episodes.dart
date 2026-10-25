import 'media_presentation.dart';
import 'store.dart';

export 'media_presentation.dart' show mediaEpisodeKey;

Map<String, List<SyncRecord>> groupMediaEpisodes(
  Iterable<SyncRecord> media, {
  String? seriesKey,
}) {
  final groups = <String, List<SyncRecord>>{};
  for (final item in media) {
    (groups[mediaEpisodeKey(item, seriesKey: seriesKey)] ??= []).add(item);
  }
  return groups;
}

List<SyncRecord> uniqueMediaEpisodes(
  Iterable<SyncRecord> media, {
  String? preferredId,
  String? seriesKey,
  bool Function(SyncRecord)? playable,
}) => [
  for (final versions in groupMediaEpisodes(media, seriesKey: seriesKey).values)
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
