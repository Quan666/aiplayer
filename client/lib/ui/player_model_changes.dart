import 'dart:convert';

import '../data/app_model.dart';
import '../data/store.dart';

/// AppModel also announces progress saves and sync heartbeats. Only its visible
/// player inputs need to rebuild the video surface and controls together.
class PlayerModelChanges {
  Object? _previous;

  bool update(AppModel model, SyncRecord media) {
    final current = model.store.get('media', media.id) ?? media;
    final next = (
      // Keep all settings, including nested shortcuts and future preferences.
      jsonEncode(model.settings),
      model.store.recordsRevision('media'),
      model.store.locationRevision,
      model.displayTitle(current),
      model.mediaDimensions(current),
    );
    if (next == _previous) return false;
    _previous = next;
    return true;
  }
}
