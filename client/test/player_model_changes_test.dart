import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/player_model_changes.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late AppModel model;
  late SyncRecord media;
  late PlayerModelChanges changes;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = AppStore(':memory:');
    model = AppModel(store, Directory.systemTemp, backgroundWork: false);
    store.save('media', 'video', {
      'series': 'Original',
      'episode': '1',
      'title': 'Original 01.mp4',
    });
    store.setLocal('location:video', {
      'source': 'local',
      'path': '/video.mp4',
      'size': 123,
    });
    media = store.get('media', 'video')!;
    changes = PlayerModelChanges();
    expect(changes.update(model, media), isTrue);
  });

  tearDown(() {
    model.dispose();
    store.dispose();
  });

  test(
    'progress saves and sync heartbeat writes do not rebuild the player',
    () {
      for (var i = 0; i < 100; i++) {
        store.setLocal('lastSync', i);
        store.save('progress', model.progressKey(media), {'position': i});
        model.changed();
        expect(changes.update(model, media), isFalse);
      }
    },
  );

  test('player settings and nested shortcut changes are retained', () {
    for (final patch in [
      {'videoFit': 'cover'},
      {'subtitleScale': 1.5},
      {'danmuFontSize': 24},
      {'keepScreenOn': false},
      {'autoNextEpisode': false},
      {
        'shortcuts': {'playPause': 'KeyP'},
      },
      {
        'shortcuts': {'playPause': 'Space'},
      },
    ]) {
      store.setLocal('settings', {...model.settings, ...patch});
      expect(changes.update(model, media), isTrue);
      expect(changes.update(model, media), isFalse);
    }
  });

  test('metadata, local episode titles and translated titles refresh', () {
    store.save('media', media.id, {...media.data, 'metadataTitle': '作品名称'});
    expect(changes.update(model, media), isTrue);
    store.setLocal('episodeTitle:${media.id}', '新的单集标题');
    expect(changes.update(model, media), isTrue);

    final current = store.get('media', media.id)!;
    model.titleTranslations.setVisible(mediaSeriesKey(current), true);
    final key = store.localEntries('media-title-display:').keys.single;
    store.setLocal(key, {
      'visible': true,
      'titles': {'作品名称': 'Translated title'},
    });
    expect(changes.update(model, media), isTrue);
    expect(changes.update(model, media), isFalse);
  });

  test('new episodes and location availability refresh playlist controls', () {
    store.save('media', 'next', {...media.data, 'episode': '2'});
    expect(changes.update(model, media), isTrue);
    store.setLocal('location:next', {'source': 'local', 'path': '/next.mp4'});
    expect(changes.update(model, media), isTrue);
    store.removeLocal('location:next');
    expect(changes.update(model, media), isTrue);
  });

  test('cached dimensions refresh without obsolete room preferences', () {
    final fingerprint = const MediaPreviewRequest(
      'video',
      'local',
      '/video.mp4',
      123,
    ).contentFingerprint;
    for (final size in [(1920, 1080), (1080, 1920)]) {
      store.setLocal('mediaMetadata:video', {
        'fingerprint': fingerprint,
        'width': size.$1,
        'height': size.$2,
      });
      expect(changes.update(model, media), isTrue);
    }
    store.setLocal('syncPlayback:enabled', true);
    expect(changes.update(model, media), isFalse);
    store.setLocal('syncPlayback:enabled', false);
    expect(changes.update(model, media), isFalse);
  });
}
