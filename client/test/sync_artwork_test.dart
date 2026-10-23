import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync_artwork.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory firstDir, secondDir;
  late AppStore first, second;
  late PosterCache firstPosters, secondPosters;
  late SyncArtwork from, to;
  const url = 'https://image.tmdb.org/t/p/w500/example.jpg';
  final picture = Uint8List.fromList(
    images.encodePng(
      images.Image(width: 32, height: 32)..setPixelRgb(10, 10, 255, 80, 20),
    ),
  );
  final image = 'data:image/png;base64,${base64Encode(picture)}';

  setUp(() async {
    firstDir = await Directory.systemTemp.createTemp('sync-art-first-');
    secondDir = await Directory.systemTemp.createTemp('sync-art-second-');
    first = AppStore(':memory:');
    second = AppStore(':memory:');
    firstPosters = PosterCache(
      directory: Directory('${firstDir.path}/poster-cache-v1'),
    );
    secondPosters = PosterCache(
      directory: Directory('${secondDir.path}/poster-cache-v1'),
    );
    from = SyncArtwork(first, firstDir, firstPosters);
    to = SyncArtwork(second, secondDir, secondPosters);
    for (final store in [first, second]) {
      store.save('media', 'video', {'poster': url, 'size': 123});
      store.setLocal('location:video', {
        'id': 'video',
        'source': 'nas',
        'path': 'show/episode.mkv',
        'size': 123,
        'modified': 42,
        'previewRevision': 'remote-revision',
      });
    }
  });
  tearDown(() async {
    firstPosters.close();
    secondPosters.close();
    first.dispose();
    second.dispose();
    await firstDir.delete(recursive: true);
    await secondDir.delete(recursive: true);
  });

  test(
    'portable posters restore offline without sharing device paths',
    () async {
      await firstPosters.directory.create(recursive: true);
      await firstPosters.cachedFile(url).writeAsBytes(picture);
      final snapshot = await from.snapshot();
      expect(snapshot.keys, contains('poster:$url'));
      expect(jsonEncode(snapshot), isNot(contains(firstDir.path)));
      await to.apply('poster:$url', snapshot['poster:$url'], deleted: false);
      expect(await (await secondPosters.load(url))!.readAsBytes(), picture);
      expect((await to.snapshot())['poster:$url'], snapshot['poster:$url']);
      await secondPosters.cachedFile(url).delete();
      await to.apply('poster:$url', snapshot['poster:$url'], deleted: false);
      expect(await secondPosters.cachedFile(url).exists(), isTrue);
    },
  );

  test('targeted artwork snapshot ignores unrelated library rows', () async {
    await firstPosters.directory.create(recursive: true);
    await firstPosters.cachedFile(url).writeAsBytes(picture);
    first.save('media', 'unrelated', {
      'poster': 'https://example.com/other.jpg',
    });
    first.setLocal('location:unrelated', {
      'id': 'unrelated',
      'source': 'nas',
      'path': 'other.mkv',
      'size': 123,
    });
    await firstPosters
        .cachedFile('https://example.com/other.jpg')
        .writeAsBytes(picture);
    expect((await from.snapshot(mediaIds: {'video'})).keys, ['poster:$url']);
    expect(await from.snapshot(mediaIds: {'missing'}), isEmpty);
    expect(await from.snapshot(mediaIds: {}), isEmpty);
    expect((await from.snapshot()).length, 2);
  });

  test(
    'preview restores matching fingerprint and does not accept another file version',
    () async {
      final directory = Directory('${firstDir.path}/previews');
      await directory.create();
      final file = File('${directory.path}/original.png');
      await file.writeAsBytes(picture);
      const request = MediaPreviewRequest(
        'video',
        'nas',
        'show/episode.mkv',
        123,
        revision: 'remote-revision',
        position: 30,
      );
      first.setLocal('preview:video', {
        'path': file.path,
        'fingerprint': request.fingerprint,
        'contentFingerprint': request.contentFingerprint,
        'requestedPosition': 30,
        'capturedPosition': 30.4,
        'formatVersion': MediaPreview.formatVersion,
      });
      final snapshot = await from.snapshot();
      final value = snapshot['preview:video'];
      expect(value['requestedPosition'], 30);
      await to.apply('preview:video', value, deleted: false);
      final restored = second.local('preview:video') as Map;
      expect(restored['fingerprint'], request.fingerprint);
      expect(restored['contentFingerprint'], request.contentFingerprint);
      expect(restored['path'], startsWith(secondDir.path));
      expect(await File(restored['path']).readAsBytes(), picture);
      expect((await to.snapshot())['preview:video'], value);
      second.removeLocal('preview:video');
      second.setLocal('location:video', {
        ...second.local('location:video') as Map,
        'size': 124,
      });
      await to.apply('preview:video', value, deleted: false);
      expect(second.local('preview:video'), isNull);
    },
  );

  test(
    'local media, stale previews, and corrupt image records are excluded',
    () async {
      first.setLocal('location:video', {
        ...first.local('location:video') as Map,
        'source': 'local',
      });
      await firstPosters.directory.create(recursive: true);
      await firstPosters.cachedFile(url).writeAsBytes(picture);
      expect(await from.snapshot(), isEmpty);
      expect(SyncArtwork.valid('poster:$url', {'image': image}), isTrue);
      expect(
        SyncArtwork.valid('poster:file:///tmp/poster', {'image': image}),
        isFalse,
      );
      expect(
        SyncArtwork.valid('poster:https://user:pass@example.com/a', {
          'image': image,
        }),
        isFalse,
      );
      for (final invalid in [
        'data:image/svg+xml;base64,PHN2Zz4=',
        'data:image/png;base64,YWJj',
        'data:image/png;base64,%%%%',
        'x' * 180001,
      ]) {
        expect(SyncArtwork.valid('poster:$url', {'image': invalid}), isFalse);
      }
      expect(
        SyncArtwork.valid('preview:video', {
          'image': image,
          'mediaId': 'other',
          'size': 123,
        }),
        isFalse,
      );
      expect(
        SyncArtwork.valid('preview:video', {
          'image': image,
          'mediaId': 'video',
          'size': -1,
        }),
        isFalse,
      );
    },
  );
}
