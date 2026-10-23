import 'dart:convert';
import 'dart:isolate';

/// Small replies avoid isolate startup; large catalogues, sync pages and
/// comment lists cannot monopolize the UI isolate while decoding JSON.
Future<dynamic> decodeJson(String text) async => text.length < 64 * 1024
    ? jsonDecode(text)
    : await Isolate.run(() => jsonDecode(text));
