final _tmdbPosterSize = RegExp(r'^/t/p/(?:w|h)[1-9][0-9]*/(?=.+)');
final _bangumiPosterSize = RegExp(r'^/pic/cover/[lcmsg]/(?=.+)');
final _bangumiResize = RegExp(r'^/r/[0-9]+(?:x[0-9]+)?/');

/// Selects the full-size artwork only for providers with known URL formats.
/// Unknown sources keep their complete URL, including authentication options.
String originalPosterUrl(String poster) {
  final uri = Uri.tryParse(poster);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return poster;
  }

  var path = uri.path;
  if (uri.host == 'image.tmdb.org') {
    path = path.replaceFirst(_tmdbPosterSize, '/t/p/original/');
  } else if (uri.host == 'lain.bgm.tv') {
    final unscaled = path.replaceFirst(_bangumiResize, '/');
    if (!_bangumiPosterSize.hasMatch(unscaled)) return poster;
    path = unscaled.replaceFirst(_bangumiPosterSize, '/pic/cover/l/');
  }

  return path == uri.path ? poster : uri.replace(path: path).toString();
}
