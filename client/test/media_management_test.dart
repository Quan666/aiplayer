import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppModel model;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('aiplayer-media-management-');
    model = AppModel(AppStore(p.join(root.path, 'test.db')), root);
  });
  tearDown(() async {
    model.dispose();
    await model.flushMetadataTasks();
    model.store.dispose();
    await root.delete(recursive: true);
  });

  Future<SyncRecord> addFile(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    final id = model.addMedia('local', await LocalSource().stat(path));
    return model.store.get('media', id)!;
  }

  test(
    'source edits preserve order and deletion keeps media locations',
    () async {
      await model.saveSource({
        'id': 'one',
        'kind': 'smb',
        'label': 'A',
      }, 'first');
      await model.saveSource({
        'id': 'two',
        'kind': 'http',
        'label': 'B',
      }, 'second');
      final id = model.addMedia(
        'one',
        const SourceEntry(name: 'one.mkv', path: 'one.mkv'),
      );
      await model.saveSource({
        'id': 'one',
        'kind': 'smb',
        'label': 'Edited',
      }, 'new');
      expect(model.sources.map((source) => source['id']), ['one', 'two']);
      expect(model.sources.first['label'], 'Edited');
      expect(await model.secrets.read(key: 'source:one'), 'new');
      await model.removeSource('one');
      expect(model.sources.map((source) => source['id']), ['two']);
      expect(await model.secrets.read(key: 'source:one'), isNull);
      expect(model.store.get('media', id)?.deleted, false);
      expect(model.store.local('location:$id')['source'], 'one');
    },
  );

  test(
    'removing a linked local video keeps the original and saves tombstones',
    () async {
      final record = await addFile(p.join(root.path, 'external', 'video.mkv'));
      model.store.save('progress', model.progressKey(record), {
        'position': 5,
        'duration': 30,
      });
      model.store.save('match', record.id, {'episodeId': '1'});
      model.store.save('watched', model.watchedKey(record), {'watched': true});
      expect(await model.isManagedImport(record), false);
      await model.removeMedia(record);
      expect(
        await File(p.join(root.path, 'external', 'video.mkv')).exists(),
        true,
      );
      expect(model.store.get('media', record.id)?.deleted, true);
      expect(model.store.get('progress', '${record.id}:3')?.deleted, true);
      expect(model.store.get('match', record.id)?.deleted, true);
      expect(model.store.local('location:${record.id}'), isNull);
      expect(
        model.store.pending.where((item) => item.kind != 'watched'),
        isEmpty,
      );
      // Watched status is episode-wide; deleting one file version retains it.
      expect(
        model.store.get('watched', model.watchedKey(record))?.deleted,
        false,
      );
    },
  );

  test(
    'external temporary imports retain display names and own their copies',
    () async {
      final incoming = File(p.join(root.path, 'incoming', 'native-uuid.mkv'));
      await incoming.parent.create(recursive: true);
      await incoming.writeAsBytes([4, 3, 2, 1]);
      final id = await model.importExternalFile(
        incoming.path,
        '作品 S02E03.mkv',
        temporary: true,
      );
      final record = model.store.get('media', id)!;
      final copy = File(model.store.local('location:$id')['path']);
      expect(record.data['fileName'], '作品 S02E03.mkv');
      expect(record.data['season'], '2');
      expect(record.data['episode'], '3');
      expect(copy.path, isNot(incoming.path));
      expect(await incoming.exists(), isFalse);
      expect(await copy.readAsBytes(), [4, 3, 2, 1]);
      expect(await model.isManagedImport(record), isTrue);
      expect(record.data['transient'], isTrue);
      expect(model.media, isEmpty);
      expect(model.recentMedia(), isEmpty);
      expect(model.store.pending, isEmpty);
      await model.disposeExternalMedia(id);
      expect(model.store.get('media', id), isNull);
      expect(model.store.local('location:$id'), isNull);
      expect(await copy.exists(), isFalse);
    },
  );

  test(
    'opening an existing local file externally never imports or deletes it',
    () async {
      final file = File(p.join(root.path, 'external.mkv'));
      await file.writeAsBytes([1, 2, 3]);
      final imported = await model.importFile(file.path);
      final temporary = await model.importExternalFile(
        file.path,
        'External title.mkv',
      );
      expect(temporary, isNot(imported));
      expect(model.media.map((item) => item.id), [imported]);
      expect(model.store.get('media', temporary)?.data['transient'], isTrue);
      await model.disposeExternalMedia(temporary);
      expect(await file.exists(), isTrue);
      expect(model.store.get('media', temporary), isNull);
      expect(model.media.map((item) => item.id), [imported]);
    },
  );

  test(
    'failed external import removes its incomplete managed directory',
    () async {
      await expectLater(
        model.importExternalFile(
          '/missing/video.mkv',
          'video.mkv',
          temporary: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await Directory(p.join(root.path, 'media')).list().toList(),
        isEmpty,
      );
      expect(model.media, isEmpty);
    },
  );

  test(
    'managed legacy import copies are deleted without deleting siblings',
    () async {
      final folder = p.join(
        root.path,
        'media',
        'eaa3c1b2-2304-45d8-830d-d794ce35156b',
      );
      final record = await addFile(p.join(folder, 'video.mkv'));
      final sibling = File(p.join(folder, 'keep.srt'));
      await sibling.writeAsString('subtitle');
      expect(await model.isManagedImport(record), true);
      await model.removeMedia(record);
      expect(await File(p.join(folder, 'video.mkv')).exists(), false);
      expect(await sibling.exists(), true);
    },
  );

  test(
    'external playback does not own an existing imported library file',
    () async {
      final path = p.join(
        root.path,
        'media',
        'eaa3c1b2-2304-45d8-830d-d794ce35156b',
        'keep.mkv',
      );
      final libraryRecord = await addFile(path);
      final temporaryId = await model.importExternalFile(path, 'keep.mkv');
      await model.disposeExternalMedia(temporaryId);
      expect(await File(path).exists(), isTrue);
      expect(model.store.get('media', libraryRecord.id)?.deleted, isFalse);
      expect(model.store.get('media', temporaryId), isNull);
    },
  );

  test(
    'arbitrary files and symlinks inside media are never owned imports',
    () async {
      final ordinary = await addFile(
        p.join(root.path, 'media', 'personal', 'video.mkv'),
      );
      expect(await model.isManagedImport(ordinary), false);
      final external = await addFile(
        p.join(root.path, 'external', 'other.mkv'),
      );
      final ownedFolder = Directory(
        p.join(root.path, 'media', 'baa3c1b2-2304-45d8-830d-d794ce35156b'),
      );
      await ownedFolder.create(recursive: true);
      final link = Link(p.join(ownedFolder.path, 'linked.mkv'));
      await link.create(model.store.local('location:${external.id}')['path']);
      final linkedId = model.addMedia(
        'local',
        SourceEntry(name: 'linked.mkv', path: link.path),
      );
      final linked = model.store.get('media', linkedId)!;
      expect(await model.isManagedImport(linked), false);
      await model.removeMedia(linked);
      expect(
        await File(p.join(root.path, 'external', 'other.mkv')).exists(),
        true,
      );
      expect(await link.exists(), true);
    },
  );

  test(
    'metadata stays local and becomes invalid after associating a new file',
    () async {
      final record = await addFile(p.join(root.path, 'one.mkv'));
      model.recordMediaMetadata(
        record.id,
        duration: 125.5,
        width: 1920,
        height: 1080,
      );
      expect(model.mediaDuration(record), 125.5);
      expect(model.store.get('media', record.id)?.data['duration'], 0);
      expect(model.store.pending, isEmpty);
      final location = model.store.local('location:${record.id}');
      final request = MediaPreviewRequest(
        record.id,
        'local',
        location['path'],
        location['size'],
      );
      model.store.setLocal('preview:${record.id}', {
        'path': '/old-native-encoding.png',
        'fingerprint': request.fingerprint,
      });
      expect(
        model.thumbnailPath(record.id),
        isNull,
        reason:
            'Old native PNG caches must be regenerated even if their fingerprint matches.',
      );
      model.store.setLocal('preview:${record.id}', {
        'path': '/cover.jpg',
        'fingerprint': request.fingerprint,
        'formatVersion': MediaPreview.formatVersion,
      });
      expect(model.thumbnailPath(record.id), '/cover.jpg');
      model.addMedia(
        'local',
        const SourceEntry(
          name: 'replacement.mkv',
          path: '/replacement.mkv',
          size: 8,
        ),
        associateId: record.id,
      );
      expect(model.thumbnailPath(record.id), isNull);
      expect(model.mediaDuration(record), 0);
    },
  );

  test(
    'editing a server location invalidates a cover but keeps the media identity',
    () async {
      final source = {
        'id': 'remote',
        'kind': 'http',
        'url': 'https://one.test/video.mkv',
      };
      await model.saveSource(source, 'secret');
      final id = model.addMedia(
        'remote',
        const SourceEntry(name: 'video.mkv', path: '', size: 42),
      );
      model.recordMediaMetadata(id, duration: 50);
      await model.saveSource({
        ...source,
        'label': 'Renamed',
        'password': 'should-not-persist',
      }, 'rotated');
      expect(model.mediaDuration(model.store.get('media', id)!), 50);
      expect(model.sources.single.containsKey('password'), false);
      await model.saveSource({
        ...source,
        'url': 'https://two.test/video.mkv',
      }, 'rotated');
      expect(model.mediaDuration(model.store.get('media', id)!), 0);
      expect(model.media.single.id, id);
      expect(model.store.local('location:$id')['previewRevision'], isNotEmpty);
    },
  );
}
