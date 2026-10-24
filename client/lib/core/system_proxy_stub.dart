import 'network.dart';

typedef SystemProxyLookup =
    Future<String?> Function(Uri uri, {CancelToken? cancel});

/// Plain Dart processes retain HttpClient's environment proxy configuration.
Future<String?> resolveSystemProxy(
  Uri uri, {
  CancelToken? cancel,
  Duration timeout = const Duration(seconds: 5),
}) async {
  cancel?.check();
  return null;
}
