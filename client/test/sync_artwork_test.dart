import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
    'source posters survive synchronized fallbacks and seed snapshots',
    () async {
      await firstPosters.directory.create(recursive: true);
      final source = images.encodePng(
        images.Image(width: 640, height: 960)
          ..setPixelRgb(10, 10, 30, 100, 240),
      );
      final sourceFile = firstPosters.sourceFile(url);
      await sourceFile.writeAsBytes(source);
      await from.apply('poster:$url', {'image': image}, deleted: false);
      expect(await sourceFile.readAsBytes(), source);
      final snapshot = await from.snapshot();
      final portable = snapshot['poster:$url']['image'] as String;
      expect(base64Decode(portable.split(',').last), source);
      await to.apply('poster:$url', snapshot['poster:$url'], deleted: false);
      expect((await to.snapshot())['poster:$url'], snapshot['poster:$url']);
    },
  );

  test(
    'downsampling averages fine poster patterns without repeated loss',
    () async {
      final source = images.Image(width: 2560, height: 1280);
      for (final pixel in source) {
        final value = (pixel.x + pixel.y).isEven ? 0 : 255;
        pixel.setRgb(value, value, value);
      }
      // An uncompressed PNG forces the portable transcode path even though the
      // deliberately fine pattern itself is easy for a PNG encoder to compress.
      final original = images.encodePng(source, level: 0);
      expect(original.length, greaterThan(134970));
      await firstPosters.directory.create(recursive: true);
      await firstPosters.cachedFile(url).writeAsBytes(original);
      final snapshot = await from.snapshot();
      final portable = snapshot['poster:$url']['image'] as String;
      expect(portable.length, lessThanOrEqualTo(180000));
      final bytes = base64Decode(portable.split(',').last);
      expect(bytes.length, lessThanOrEqualTo(134970));
      final restored = images.decodeImage(bytes)!;
      expect((restored.width, restored.height), (1280, 640));
      for (final point in [(100, 100), (401, 311), (900, 500)]) {
        expect(restored.getPixel(point.$1, point.$2).r, closeTo(127, 3));
      }
      await to.apply('poster:$url', snapshot['poster:$url'], deleted: false);
      expect((await to.snapshot())['poster:$url'], snapshot['poster:$url']);
      expect(await firstPosters.cachedFile(url).readAsBytes(), original);
    },
  );

  test(
    'portable compression preserves mobile resolution and EXIF orientation',
    () async {
      final source = images.Image(width: 640, height: 1280);
      final random = Random(42);
      for (final pixel in source) {
        final value = 90 + pixel.x ~/ 8 + random.nextInt(25);
        pixel.setRgb(value, value, value);
      }
      source.exif.imageIfd.orientation = 6;
      final original = images.encodeJpg(source, quality: 100);
      expect(original.length, greaterThan(134970));
      await firstPosters.directory.create(recursive: true);
      await firstPosters.cachedFile(url).writeAsBytes(original);
      final snapshot = await from.snapshot();
      final portable = snapshot['poster:$url']['image'] as String;
      expect(SyncArtwork.valid('poster:$url', {'image': portable}), isTrue);
      final bytes = base64Decode(portable.split(',').last);
      final restored = images.decodeImage(bytes)!;
      expect((restored.width, restored.height), (1280, 640));
      expect(
        restored.getPixel(100, 50).r,
        lessThan(restored.getPixel(100, 550).r),
      );
      expect(bytes.length, lessThanOrEqualTo(134970));
      await to.apply('poster:$url', snapshot['poster:$url'], deleted: false);
      expect((await to.snapshot())['poster:$url'], snapshot['poster:$url']);
    },
  );

  test(
    'high-entropy posters remain shareable within the wire budget',
    () async {
      final source = images.Image(width: 1280, height: 1280);
      final random = Random(17);
      for (final pixel in source) {
        pixel.setRgb(
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
      await firstPosters.directory.create(recursive: true);
      await firstPosters.cachedFile(url).writeAsBytes(images.encodePng(source));
      final snapshot = await from.snapshot();
      final portable = snapshot['poster:$url']['image'] as String;
      expect(SyncArtwork.valid('poster:$url', {'image': portable}), isTrue);
      final bytes = base64Decode(portable.split(',').last);
      expect(bytes.length, lessThanOrEqualTo(134970));
      final restored = images.decodeImage(bytes)!;
      expect(restored.width, inInclusiveRange(384, 1279));
      expect(restored.width, restored.height);
    },
  );

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
