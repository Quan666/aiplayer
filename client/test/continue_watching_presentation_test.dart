import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/continue_watching_presentation.dart';
import 'package:aiplayer/data/media_presentation.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _CountingStore extends AppStore {
  _CountingStore(super.path);
  int recordReads = 0, localReads = 0;
  @override
  SyncRecord? get(String kind, String id) {
    recordReads++;
    return super.get(kind, id);
  }

  @override
  dynamic local(String key) {
    localReads++;
    return super.local(key);
  }
}

void main() {
  late Directory directory;
  late _CountingStore store;
  late AppModel model;
  late SyncRecord media;

  void preview(String path, {int size = 500}) {
    final request = MediaPreviewRequest(
      'one',
      'nas',
      '/Series/one.mp4',
      size,
      position: 45,
    );
    store.setLocal('preview:one', {
      'path': path,
      'formatVersion': MediaPreview.formatVersion,
      'fingerprint': request.fingerprint,
      'contentFingerprint': request.contentFingerprint,
    });
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('continue-presentation-');
    store = _CountingStore('${directory.path}/library.db');
    model = AppModel(store, directory, backgroundWork: false);
    store.save('media', 'one', {
      'title': 'one.mp4',
      'series': 'Example',
      'season': '1',
      'episode': '2',
      'episodeTitle': 'Original episode',
      'size': 100,
      'duration': 600,
    });
    store.setLocal('location:one', {
      'source': 'nas',
      'path': '/Series/one.mp4',
      'size': 500,
    });
    store.save(
      'progress',
      'one:500',
      {'position': 45, 'duration': 900, 'devicePlatform': 'linux'},
      deviceId: 'remote',
      deviceName: '客厅电脑',
    );
    media = store.get('media', 'one')!;
    preview('/previews/one.png');
  });

  tearDown(() async {
    model.dispose();
    await model.sync.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'disk preparation avoids UI card SQL and preserves display data',
    () async {
      store.setLocal('episodeTitle:one', 'Localized original');
      final title = model.seriesTitle(media),
          episode = model.episodeLabel(media);
      final thumbnail = model.thumbnailPath(media.id);
      store.recordReads = store.localReads = 0;
      final cards = await model.loadContinueWatchingPresentations([media]);
      final card = cards['one']!;
      expect(store.recordReads, 0);
      expect(store.localReads, 0);
      expect(card.preparationIsolate, isNot(Isolate.current.hashCode));
      expect(card.title, title);
      expect(card.episode, episode);
      expect(card.thumbnail, thumbnail);
      expect(card.position, 45);
      expect(card.duration, 900);
      expect(card.remoteDeviceName, '客厅电脑');
      expect(card.originDeviceId, 'remote');
      expect(card.originDevicePlatform, 'linux');
      expect(
        await model.loadContinueWatchingPresentations([media]),
        same(cards),
      );
      expect(() => cards.clear(), throwsUnsupportedError);
    },
  );

  test(
    'preview and content invalidation do not rescan structural library data',
    () async {
      final library = await model.loadLibrarySnapshot();
      final first = await model.loadContinueWatchingPresentations([media]);
      preview('/previews/replaced.png');
      final replaced = await model.loadContinueWatchingPresentations([media]);
      expect(replaced['one']!.thumbnail, '/previews/replaced.png');
      expect(replaced, isNot(same(first)));
      expect(
        replaced['one']!.preparationIsolate,
        first['one']!.preparationIsolate,
      );
      expect(await model.loadLibrarySnapshot(), same(library));
      store.setLocal('location:one', {
        'source': 'nas',
        'path': '/Series/one.mp4',
        'size': 501,
      });
      final changed = await model.loadContinueWatchingPresentations([media]);
      expect(changed['one']!.thumbnail, isNull);
      expect(changed['one']!.position, 0);
      expect(changed['one']!.duration, 600);
      preview('/previews/new-file.png', size: 501);
      store.save('progress', 'one:501', {'position': 80, 'duration': 1000});
      final current = await model.loadContinueWatchingPresentations([media]);
      expect(current['one']!.thumbnail, '/previews/new-file.png');
      expect(current['one']!.position, 80);
      expect(current['one']!.remoteDeviceName, isEmpty);
    },
  );

  test(
    'translation, episode and device revisions preserve label semantics',
    () async {
      String hash(Object value) =>
          sha256.convert(utf8.encode(jsonEncode(value))).toString();
      final profile = hash(['https://api.openai.com/v1', '', '简体中文']);
      final key =
          'media-title-display:${hash([mediaSeriesKey(media), profile])}';
      store.setLocal('episodeTitle:one', 'Local episode');
      store.setLocal(key, {
        'visible': true,
        'titles': {'Example': '示例', 'Local episode': '第二集标题'},
      });
      var card = (await model.loadContinueWatchingPresentations([
        media,
      ]))['one']!;
      expect(card.title, model.seriesTitle(media));
      expect(card.episode, model.episodeLabel(media));
      expect(card.title, '示例');
      expect(card.episode, contains('第二集标题'));
      store.setLocal('syncDevice:id', 'remote');
      card = (await model.loadContinueWatchingPresentations([media]))['one']!;
      expect(card.remoteDeviceName, isEmpty);
      store.setLocal('settings', {'aiSubtitleTarget': 'English'});
      card = (await model.loadContinueWatchingPresentations([media]))['one']!;
      expect(card.title, 'Example');
      expect(card.episode, contains('Local episode'));
    },
  );

  test(
    'external commits, direct SQL and rollback cannot leave stale cards',
    () async {
      await model.loadContinueWatchingPresentations([media]);
      final other = sqlite3.open(store.path);
      try {
        other.execute('UPDATE records SET data=? WHERE kind=? AND id=?', [
          jsonEncode({'position': 71, 'duration': 800}),
          'progress',
          'one:500',
        ]);
      } finally {
        other.dispose();
      }
      expect(
        (await model.loadContinueWatchingPresentations([
          media,
        ]))['one']!.position,
        71,
      );
      store.db.execute('UPDATE records SET data=? WHERE kind=? AND id=?', [
        jsonEncode({'position': 72, 'duration': 800}),
        'progress',
        'one:500',
      ]);
      expect(
        (await model.loadContinueWatchingPresentations([
          media,
        ]))['one']!.position,
        72,
      );
      store.db.execute('BEGIN');
      store.db.execute('UPDATE records SET data=? WHERE kind=? AND id=?', [
        jsonEncode({'position': 99}),
        'progress',
        'one:500',
      ]);
      store.db.execute('ROLLBACK');
      expect(
        (await model.loadContinueWatchingPresentations([
          media,
        ]))['one']!.position,
        72,
      );
    },
  );

  test('duration metadata and an in-flight rollback stay consistent', () async {
    store.save('progress', 'one:500', {'position': 45});
    final request = MediaPreviewRequest('one', 'nas', '/Series/one.mp4', 500);
    store.setLocal('mediaMetadata:one', {
      'fingerprint': request.contentFingerprint,
      'duration': 700,
    });
    expect(
      (await model.loadContinueWatchingPresentations([media]))['one']!.duration,
      model.mediaDuration(media),
    );
    late Future<Map<String, ContinueWatchingPresentation>> duringRollback;
    expect(
      () => store.transaction(() {
        store.save('progress', 'one:500', {'position': 99, 'duration': 1000});
        duringRollback = model.loadContinueWatchingPresentations([media]);
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    final card = (await duringRollback)['one']!;
    expect(card.position, 45);
    expect(card.duration, 700);
    store.save('media', 'one', {}, deleted: true);
    expect(await model.loadContinueWatchingPresentations([media]), isEmpty);
  });

  test(
    'canceled and superseded requests do not publish stale results',
    () async {
      final reader = ContinueWatchingPresentationReader(store);
      try {
        final cancel = CancelToken();
        final first = reader.read(['one'], cancel: cancel);
        final firstResult = expectLater(first, throwsA(isA<Cancelled>()));
        cancel.cancel();
        final obsolete = reader.read(['missing']);
        final obsoleteResult = expectLater(obsolete, throwsA(isA<Cancelled>()));
        final latest = reader.read(['one']);
        await firstResult;
        await obsoleteResult;
        expect((await latest).keys, ['one']);
        final stopped = CancelToken()..cancel();
        await expectLater(
          reader.read(['one'], cancel: stopped),
          throwsA(isA<Cancelled>()),
        );
      } finally {
        reader.dispose();
      }
    },
  );
}
