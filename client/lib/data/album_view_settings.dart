import 'dart:convert';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// Small path-only preparation; reading/writing these files belongs to workers.
/// Split the reversible identity to stay below filesystem component limits.
String albumSettingsPath(String documents, String source, String directory) {
  final encoded = base64Url.encode(
    utf8.encode(jsonEncode([source, directory])),
  );
  return p.joinAll([
    documents,
    'album-settings-v1',
    for (var offset = 0; offset < encoded.length; offset += 100)
      encoded.substring(offset, math.min(offset + 100, encoded.length)),
    'view.json',
  ]);
}
