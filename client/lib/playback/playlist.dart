import 'dart:isolate';

import 'package:path/path.dart' as paths;
import '../data/app_model.dart';
import '../data/media_presentation.dart';
import '../data/media_episodes.dart';
import '../data/store.dart';

final _playlists = Expando<_PlaylistIndex>();

/// Shared by manual selection and automatic continuation. Tapping to reveal
/// controls must not decode every media/location row or sort the series again.
List<SyncRecord> playbackPlaylist(AppModel model, SyncRecord media) =>
    (_playlists[model.store] ??= _PlaylistIndex()).playlist(model.store, media);

/// Prepare only the two remote-control destinations off the rendering isolate.
/// The private connection sees one consistent library/location snapshot.
Future<(SyncRecord?, SyncRecord?)> playbackNeighbors(
  String databasePath,
  SyncRecord media,
) => Isolate.run(() {
  final store = AppStore.openExisting(databasePath);
  try {
    store.db.execute('BEGIN');
    final items = _PlaylistIndex().playlist(store, media);
    final index = items.indexWhere((item) => item.id == media.id);
    return (
      index > 0 ? items[index - 1] : null,
      index >= 0 && index + 1 < items.length ? items[index + 1] : null,
    );
  } finally {
    store.db.execute('ROLLBACK');
    store.dispose();
  }
});

class _PlaylistIndex {
  int? _mediaRevision, _locationRevision;
  Map<String, SyncRecord> _media = {};
  Map<String, dynamic> _locations = {};
  final _groups = <(String, String), List<SyncRecord>>{};
  final _sorted = <(String, String), List<SyncRecord>>{};
  final _selectedVersions = <(String, String, String), List<SyncRecord>>{};

  List<SyncRecord> playlist(AppStore store, SyncRecord media) {
    final mediaRevision = store.recordsRevision('media');
    final locationRevision = store.locationRevision;
    if (_mediaRevision != mediaRevision ||
        _locationRevision != locationRevision) {
      _mediaRevision = mediaRevision;
      _locationRevision = locationRevision;
      _media = {for (final item in store.all('media')) item.id: item};
      // One query replaces a separate location lookup for every library entry.
      _locations = store.localEntries('location:');
      _groups.clear();
      _sorted.clear();
      _selectedVersions.clear();
      for (final item in _media.values) {
        final location = _locations['location:${item.id}'];
        if (location is! Map) continue;
        final series = mediaSeriesKey(item);
        (_groups[('series', series)] ??= []).add(item);
        (_groups[_directoryKey(location)] ??= []).add(item);
      }
    }
    final current = _media[media.id] ?? media;
    final series = mediaSeriesKey(current);
    final location = _locations['location:${media.id}'];
    final key = series.startsWith('file:')
        ? _directoryKey(location is Map ? location : const {})
        : ('series', series);
    final items = _groups[key];
    if (items == null || items.isEmpty) return List.unmodifiable([media]);
    final sorted = _sorted.putIfAbsent(key, () {
      final unique = uniqueMediaEpisodes(items)..sort(_compareEpisodes);
      return List.unmodifiable(unique);
    });
    if (sorted.any((item) => item.id == current.id)) return sorted;
    return _selectedVersions.putIfAbsent((key.$1, key.$2, current.id), () {
      final episode = mediaEpisodeKey(current);
      return List.unmodifiable([
        for (final item in sorted)
          if (mediaEpisodeKey(item) == episode) current else item,
      ]);
    });
  }

  (String, String) _directoryKey(Map location) => (
    'directory',
    '${location['source']}\u0000${paths.dirname('${location['path']}')}',
  );

  int _compareEpisodes(SyncRecord a, SyncRecord b) {
    final seasonA = int.tryParse('${a.data['season'] ?? 0}') ?? 0;
    final seasonB = int.tryParse('${b.data['season'] ?? 0}') ?? 0;
    if (seasonA != seasonB) return seasonA.compareTo(seasonB);
    final episodeA = double.tryParse('${a.data['episode'] ?? 0}') ?? 0;
    final episodeB = double.tryParse('${b.data['episode'] ?? 0}') ?? 0;
    return episodeA != episodeB
        ? episodeA.compareTo(episodeB)
        : '${a.data['title']}'.compareTo('${b.data['title']}');
  }
}
