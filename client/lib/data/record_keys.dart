import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'store.dart';

/// Shared by the UI and background progress uploader. No AppModel is captured
/// when the worker computes episode identities.
String mediaWatchedKey(SyncRecord media) => sha256
    .convert(
      utf8.encode(
        '${media.data['tmdbId'] != null ? 'tmdb:${media.data['metadataType'] ?? 'tv'}:${media.data['tmdbId']}' : media.data['bangumiId'] ?? media.data['series']}:${media.data['season']}:${media.data['episode']}',
      ),
    )
    .toString();
