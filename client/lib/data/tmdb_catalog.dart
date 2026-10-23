import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/network.dart';
import 'catalog_cache.dart';
import 'library_catalog.dart' show metadataQuery, normalizedSeries;
import 'store.dart';

/// Only cleaned names and numeric catalogue IDs leave this adapter. No video
/// bytes, filenames, source credentials or source URLs are accepted here.
class TmdbCatalog {
  final JsonTransport transport;
  final Future<String> Function() credential;
  final CatalogCache _cache;
  TmdbCatalog(this.transport, this.credential, {AppStore? store})
    : _cache = CatalogCache(store);

  void invalidateCache() => _cache.invalidate();

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String> query = const {},
    CancelToken? cancel,
  }) async {
    cancel?.check();
    final secret = (await credential()).trim();
    cancel?.check();
    if (secret.isEmpty) {
      throw const AppFailure('请先在设置 → 常规 → 作品资料中填写 TMDB API Key 或读取令牌。');
    }
    final isKey = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(secret);
    final key =
        'catalog-v1:tmdb:${sha256.convert(utf8.encode(jsonEncode([secret, path, query])))}';
    final response = await _cache.load<Map<String, dynamic>>(
      key,
      fetch: (token) => transport.send(
        Uri.https('api.themoviedb.org', '/3/$path', {
          'language': 'zh-CN',
          ...query,
          if (isKey) 'api_key': secret,
        }),
        headers: {if (!isKey) 'Authorization': 'Bearer $secret'},
        cancel: token,
      ),
      decode: (value) => Map<String, dynamic>.from(value as Map),
      keep: (value) {
        if (path.startsWith('search/')) {
          return value['results'] is List &&
              (value['results'] as List).isNotEmpty;
        }
        if (path.contains('/season/')) {
          return '${value['season_number']}' == path.split('/').last &&
              value['episodes'] is List &&
              (value['episodes'] as List).isNotEmpty;
        }
        return '${value['id']}' == path.split('/').last;
      },
      cancel: cancel,
    );
    cancel?.check();
    return response;
  }

  Map<String, dynamic> _subject(
    Map<dynamic, dynamic> value, {
    String kind = 'tv',
  }) {
    final translations = (value['translations']?['translations'] as List? ?? [])
        .whereType<Map>()
        .toList();
    // TMDB's translations are catalogue names, not machine translations of a
    // user's filename. Prefer mainland Chinese, then other Chinese locales.
    translations.sort((a, b) {
      int rank(Map v) => v['iso_639_1'] == 'zh'
          ? (v['iso_3166_1'] == 'CN' ? 0 : 1)
          : v['iso_639_1'] == 'ja'
          ? 2
          : v['iso_639_1'] == 'en'
          ? 3
          : 4;
      return rank(a).compareTo(rank(b));
    });
    final nameKey = kind == 'tv' ? 'name' : 'title';
    final original =
        '${value[kind == 'tv' ? 'original_name' : 'original_title'] ?? ''}';
    var localized = '${value[nameKey] ?? ''}';
    var overview = '${value['overview'] ?? ''}';
    for (final entry in translations.where((v) => v['iso_639_1'] == 'zh')) {
      final data = entry['data'];
      if (data is! Map) continue;
      final name = '${data[nameKey] ?? ''}'.trim();
      if (name.isNotEmpty) {
        localized = name;
        if ('${data['overview'] ?? ''}'.trim().isNotEmpty) {
          overview = '${data['overview']}';
        }
        break;
      }
    }
    final alternative = value['alternative_titles'];
    final alternatives = alternative is Map
        ? (alternative['results'] ?? alternative['titles']) as List? ?? []
        : const [];
    final aliases = <String>{
      localized,
      original,
      '${value[nameKey] ?? ''}',
      for (final entry in translations)
        if (entry['data'] is Map) '${entry['data'][nameKey] ?? ''}',
      for (final entry in alternatives.whereType<Map>())
        '${entry['title'] ?? ''}',
    }..removeWhere((v) => v.trim().isEmpty);
    final genreIds = <int>{
      ...(value['genre_ids'] as List? ?? []).whereType<int>(),
      for (final genre in (value['genres'] as List? ?? []).whereType<Map>())
        if (genre['id'] is int) genre['id'] as int,
    };
    return {
      'id': '${value['id']}',
      'provider': 'tmdb',
      'mediaType': kind,
      if (genreIds.isNotEmpty) 'isAnimation': genreIds.contains(16),
      'name': original,
      'name_cn': localized,
      'aliases': aliases.take(100).toList(),
      'lookupNames': <String>{
        localized,
        original,
        for (final entry in translations.where((v) => v['iso_639_1'] == 'en'))
          if (entry['data'] is Map) '${entry['data'][nameKey] ?? ''}',
        for (final entry in alternatives.whereType<Map>().where(
          (v) => v['iso_3166_1'] == 'US' || v['iso_3166_1'] == 'GB',
        ))
          '${entry['title'] ?? ''}',
        ...aliases,
      }.where((v) => v.trim().isNotEmpty).take(100).toList(),
      'summary': overview,
      'date': value[kind == 'tv' ? 'first_air_date' : 'release_date'] ?? '',
      'rating': {'score': value['vote_average'], 'total': value['vote_count']},
      'total_episodes': value['number_of_episodes'],
      'total_seasons': value['number_of_seasons'],
      'genres': (value['genres'] as List? ?? [])
          .whereType<Map>()
          .map((v) => '${v['name'] ?? ''}')
          .where((v) => v.isNotEmpty)
          .toList(),
      'images': {
        'large':
            value['poster_path'] is String &&
                '${value['poster_path']}'.isNotEmpty
            ? 'https://image.tmdb.org/t/p/w500${value['poster_path']}'
            : '',
      },
    };
  }

  Future<List<Map<String, dynamic>>> search(
    String title, {
    CancelToken? cancel,
    bool movies = false,
  }) async {
    cancel?.check();
    final query = metadataQuery(title, preserveSeason: false);
    if (query.isEmpty) return [];
    final kind = movies ? 'movie' : 'tv';
    final result = await _get(
      'search/$kind',
      query: {'query': query, 'include_adult': 'false'},
      cancel: cancel,
    );
    final truncated = (result['total_pages'] as num? ?? 1) > 1;
    return (result['results'] as List? ?? [])
        .whereType<Map>()
        .take(20)
        .map(
          (item) => {
            ..._subject(item, kind: kind),
            if (truncated) 'searchTruncated': true,
          },
        )
        .toList();
  }

  /// Search responses contain only the requested locale and original name.
  /// Fetch aliases before comparing, otherwise English release names for a
  /// Japanese original incorrectly fail an otherwise exact identity match.
  Future<Map<String, dynamic>> identity(
    Map<String, dynamic> subject, {
    CancelToken? cancel,
  }) async {
    final id = '${subject['id']}';
    if (!RegExp(r'^\d+$').hasMatch(id)) throw const AppFailure('TMDB 作品编号无效。');
    final kind = subject['mediaType'] == 'movie' ? 'movie' : 'tv';
    cancel?.check();
    final raw = await _get(
      '$kind/$id',
      query: {'append_to_response': 'alternative_titles,translations'},
      cancel: cancel,
    );
    if ('${raw['id']}' != id) throw const AppFailure('TMDB 返回的作品编号不一致。');
    final detail = _subject(raw, kind: kind);
    cancel?.check();
    return detail;
  }

  Future<Map<String, dynamic>> details(
    Map<String, dynamic> subject, {
    String season = '',
    CancelToken? cancel,
  }) async {
    final detail = await identity(subject, cancel: cancel);
    if (detail['mediaType'] == 'movie') return detail;
    final number = int.tryParse(season.isEmpty ? '1' : season);
    if (number == null || number < 0 || number > 10000) {
      throw const AppFailure('季度编号无效。');
    }
    final seasonData = await _get(
      'tv/${detail['id']}/season/$number',
      cancel: cancel,
    );
    if (seasonData['season_number'] != number) {
      throw const AppFailure('TMDB 返回的季度与所选季度不一致。');
    }
    final episodes = (seasonData['episodes'] as List? ?? [])
        .whereType<Map>()
        .toList();
    return {
      ...detail,
      'season': '$number',
      'season_episodes': episodes.length,
      'episodeNames': {
        for (final episode in episodes)
          if (episode['episode_number'] is num && episode['name'] is String)
            '${episode['episode_number']}': episode['name'],
      },
      if ('${seasonData['poster_path'] ?? ''}'.isNotEmpty)
        'images': {
          'large':
              'https://image.tmdb.org/t/p/w500${seasonData['poster_path']}',
        },
      if ('${seasonData['air_date'] ?? ''}'.isNotEmpty)
        'date': seasonData['air_date'],
    };
  }

  List<String> names(Map<String, dynamic> subject) =>
      {
            ...(subject['lookupNames'] as List? ?? []).whereType<String>(),
            '${subject['name_cn'] ?? ''}',
            '${subject['name'] ?? ''}',
            ...(subject['aliases'] as List? ?? []).whereType<String>(),
          }
          .map((v) => metadataQuery(v, preserveSeason: false))
          .where((v) => v.isNotEmpty)
          .toSet()
          .toList();

  bool titleMatches(
    String title,
    Map<String, dynamic> subject, {
    bool balanced = false,
  }) {
    final wanted = normalizedSeries(title);
    if (wanted.isEmpty) return false;
    return [
      subject['name'],
      subject['name_cn'],
      ...(subject['aliases'] as List? ?? []),
    ].whereType<String>().any((name) {
      final normalized = normalizedSeries(name);
      if (normalized == wanted) return true;
      return balanced &&
          wanted.length >= 5 &&
          normalized.length >= 5 &&
          (normalized.startsWith(wanted) || wanted.startsWith(normalized)) &&
          wanted.length / normalized.length > .85 &&
          wanted.length / normalized.length < 1.18;
    });
  }
}
