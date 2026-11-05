import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/source_preview.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _ObservedStore extends AppStore {
  var previewWrites = 0;
  _ObservedStore(super.path);

  @override
  void setLocal(String key, dynamic value) {
    if (key.startsWith('preview:') || key.startsWith('mediaMetadata:')) {
      previewWrites++;
    }
    super.setLocal(key, value);
  }

  @override
  void removeLocal(String key) {
    if (key.startsWith('preview:')) previewWrites++;
    super.removeLocal(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _ObservedStore store;
  late Database blocker;
  late AppModel model;
  late Completer<CancelToken> captured;
  var locked = false;
  var disposed = false;

  setUp(() async {
    disposed = false;
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('preview-persistence-');
    store = _ObservedStore('${directory.path}/library.db');
    store.db.execute('PRAGMA busy_timeout=0');
    blocker = sqlite3.open(store.path);
    final file = File('${directory.path}/video.mp4');
    await file.writeAsBytes([1, 2, 3]);
    store.save('media', 'video', {'title': 'video.mp4', 'size': 3});
    store.setLocal('location:video', {
      'source': 'local',
      'path': file.path,
      'size': 3,
    });
    captured = Completer<CancelToken>();
    model = AppModel(
      store,
      directory,
      backgroundWork: false,
      enableThumbnails: true,
      previewCapture: (_, cancel) async {
        if (!captured.isCompleted) captured.complete(cancel);
        return MediaPreview(Uint8List.fromList([1, 2, 3]), 20, 640, 360);
      },
    );
  });

  void releaseWriter() {
    if (!locked) return;
    blocker.execute('ROLLBACK');
    locked = false;
  }

  tearDown(() async {
    releaseWriter();
    if (!disposed) model.dispose();
    await model.flushMetadataTasks();
    blocker.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<CancelToken> captureBehindLock() async {
    blocker.execute('BEGIN IMMEDIATE');
    locked = true;
    model.ensureMediaPreview('video');
    final cancel = await captured.future.timeout(const Duration(seconds: 3));
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (true) {
      final cache = Directory('${directory.path}/previews');
      if (await cache.exists() &&
          await cache.list().any((entry) => entry.path.endsWith('.jpg'))) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('Preview file was not prepared');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return cancel;
  }

  Map<String, dynamic> seedPreview(String path) {
    final request = MediaPreviewRequest(
      'video',
      'local',
      '${directory.path}/video.mp4',
      3,
    );
    final saved = <String, dynamic>{
      'path': path,
      'fingerprint': request.fingerprint,
      'contentFingerprint': request.contentFingerprint,
      'formatVersion': MediaPreview.formatVersion,
    };
    store.setLocal('preview:video', saved);
    store.previewWrites = 0;
    return saved;
  }

  test(
    'missing-cover cleanup pauses without frames and resumes the same intent',
    () async {
      final missing = '${directory.path}/paused-cover.jpg';
      final saved = seedPreview(missing);
      var notifications = 0, finished = false;
      model.addListener(() => notifications++);
      blocker.execute('BEGIN IMMEDIATE');
      locked = true;
      final repairing = model.retryMissingMediaPreview(
        'video',
        missing,
        FileSystemException('missing cover', missing),
      )..then((_) => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      model.setForeground(false);
      releaseWriter();
      // No widget pump or frame: the worker token must stop the blocked write.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(store.local('preview:video'), saved);
      expect(notifications, 0);
      expect(finished, false);
      expect(captured.isCompleted, false);
      model.setForeground(true);
      expect(await repairing.timeout(const Duration(seconds: 3)), true);
      expect(store.local('preview:video'), isNull);
      expect(notifications, 1);
      expect(captured.isCompleted, false);
      expect(store.previewWrites, 0);
    },
  );

  test('quick pause and resume retains one missing-cover cleanup', () async {
    final missing = '${directory.path}/quick-cover.jpg';
    seedPreview(missing);
    blocker.execute('BEGIN IMMEDIATE');
    locked = true;
    final repairing = model.retryMissingMediaPreview(
      'video',
      missing,
      FileSystemException('missing cover', missing),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    model.setForeground(false);
    model.setForeground(true);
    releaseWriter();
    expect(await repairing.timeout(const Duration(seconds: 3)), true);
    expect(store.local('preview:video'), isNull);
    expect(captured.isCompleted, false);
  });

  test('dispose directly cancels a blocked missing-cover cleanup', () async {
    final missing = '${directory.path}/disposed-cover.jpg';
    final saved = seedPreview(missing);
    var notifications = 0;
    model.addListener(() => notifications++);
    blocker.execute('BEGIN IMMEDIATE');
    locked = true;
    final repairing = model.retryMissingMediaPreview(
      'video',
      missing,
      FileSystemException('missing cover', missing),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    model.dispose();
    disposed = true;
    expect(await repairing, false);
    releaseWriter();
    await model.flushMetadataTasks();
    expect(store.local('preview:video'), saved);
    expect(notifications, 0);
    expect(captured.isCompleted, false);
  });

  test('restored same-path cover advances only its image revision', () async {
    final restored = File('${directory.path}/restored-cover.jpg');
    await restored.writeAsBytes([7, 8, 9]);
    final saved = seedPreview(restored.path);
    final before = model.mediaPreviewImageRevision('video');
    expect(
      await model.retryMissingMediaPreview(
        'video',
        restored.path,
        FileSystemException('earlier missing frame', restored.path),
      ),
      true,
    );
    expect(model.mediaPreviewImageRevision('video'), greaterThan(before));
    expect(model.mediaPreviewImageRevision('unrelated'), 0);
    expect(store.local('preview:video'), saved);
    expect(await restored.readAsBytes(), [7, 8, 9]);
    expect(captured.isCompleted, false);
    expect(store.previewWrites, 0);
  });

  test(
    'source edits revoke a blocked old-cover cleanup before mutation',
    () async {
      final missing = '${directory.path}/old-source-cover.jpg';
      final saved = seedPreview(missing);
      var notifications = 0;
      model.addListener(() => notifications++);
      blocker.execute('BEGIN IMMEDIATE');
      locked = true;
      final repairing = model.retryMissingMediaPreview(
        'video',
        missing,
        FileSystemException('old-source cover', missing),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      blocker.execute('UPDATE local SET value=? WHERE key=?', [
        jsonEncode({
          'source': 'local',
          'path': '${directory.path}/new-source.mp4',
          'size': 3,
        }),
        'location:video',
      ]);
      blocker.execute('COMMIT');
      locked = false;
      expect(await repairing.timeout(const Duration(seconds: 3)), false);
      expect(store.local('preview:video'), saved);
      expect(notifications, 0);
      expect(captured.isCompleted, false);
      expect(await File('${directory.path}/video.mp4').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test('missing prepared cover is invalidated on its worker and recaptured', () async {
    final missing = '${directory.path}/deleted-cover.jpg';
    seedPreview(missing);
    var notifications = 0;
    model.addListener(() {
      if (model.sourcePreviewNotificationId == 'video') notifications++;
    });
    final error = FileSystemException('missing cached cover', missing);
    final first = model.retryMissingMediaPreview('video', missing, error);
    final duplicate = model.retryMissingMediaPreview('video', missing, error);
    expect(duplicate, same(first));
    expect(await first, true);
    expect(store.local('preview:video'), isNull);
    expect(store.previewWrites, 0);
    expect(notifications, 1);
    final invalidatedImageRevision = model.mediaPreviewImageRevision('video');
    // Represents the existing visible/idle artwork callback after receiving
    // the invalidated null path. Cache maintenance itself does not open video.
    expect(captured.isCompleted, false);
    expect(model.ensureMediaPreview('video'), true);
    await captured.future.timeout(const Duration(seconds: 3));
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (store.local('preview:video') == null ||
        model.mediaPreviewImageRevision('video') <= invalidatedImageRevision) {
      if (DateTime.now().isAfter(deadline)) fail('Cover was not recaptured');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.previewWrites, 0);
    expect(await File('${directory.path}/video.mp4').readAsBytes(), [1, 2, 3]);
  });

  test(
    'late missing-file repair preserves a newer cover behind a database lock',
    () async {
      final missing = '${directory.path}/old-cover.jpg';
      final saved = seedPreview(missing);
      final replacement = File('${directory.path}/new-cover.jpg');
      await replacement.writeAsBytes([8, 9, 10]);
      blocker.execute('BEGIN IMMEDIATE');
      locked = true;
      final repairing = model.retryMissingMediaPreview(
        'video',
        missing,
        FileSystemException('missing old cover', missing),
      );
      var callerResponded = false;
      await Future<void>.delayed(const Duration(milliseconds: 60), () {
        callerResponded = true;
      });
      expect(callerResponded, true);
      blocker.execute('UPDATE local SET value=? WHERE key=?', [
        jsonEncode({...saved, 'path': replacement.path}),
        'preview:video',
      ]);
      blocker.execute('COMMIT');
      locked = false;
      expect(await repairing.timeout(const Duration(seconds: 3)), false);
      expect(store.local('preview:video')['path'], replacement.path);
      expect(await replacement.readAsBytes(), [8, 9, 10]);
      expect(captured.isCompleted, false);
      expect(store.previewWrites, 0);
    },
  );

  test(
    'missing-cover retries are bounded until that media actually decodes',
    () async {
      final missing = '${directory.path}/repeatedly-deleted.jpg';
      final error = FileSystemException('missing cached cover', missing);
      for (var attempt = 0; attempt < 2; attempt++) {
        seedPreview(missing);
        expect(
          await model.retryMissingMediaPreview('video', missing, error),
          true,
        );
      }
      seedPreview(missing);
      expect(
        await model.retryMissingMediaPreview('video', missing, error),
        false,
      );
      model.mediaPreviewReady('other-media', missing);
      expect(
        await model.retryMissingMediaPreview('video', missing, error),
        false,
      );
      model.mediaPreviewReady('video', missing);
      expect(
        await model.retryMissingMediaPreview('video', missing, error),
        true,
      );
      expect(captured.isCompleted, false);
      expect(await File('${directory.path}/video.mp4').exists(), true);
    },
  );

  test(
    'model publishes a preview after its worker commit without UI writes',
    () async {
      final published = Completer<void>();
      model.addListener(() {
        if (!published.isCompleted && store.local('preview:video') != null) {
          published.complete();
        }
      });
      await captureBehindLock();
      expect(store.previewWrites, 0);
      expect(published.isCompleted, false);
      expect(store.local('preview:video'), isNull);
      releaseWriter();
      await published.future.timeout(const Duration(seconds: 3));
      expect(store.previewWrites, 0);
      expect(store.local('mediaMetadata:video')['width'], 640);
      expect(store.local('mediaMetadata:video')['duration'], 20.0);
    },
  );

  test(
    'changing source origin invalidates a same-path same-size browse preview',
    () async {
      const source = {
        'id': 'nas',
        'kind': 'webdav',
        'url': 'http://old.example/share/',
        'user': 'reader',
      };
      store.setLocal('sources', [source]);
      const entry = SourceEntry(
        name: 'same.mp4',
        path: '/same.mp4',
        size: 3,
        modified: 1,
      );
      final id = browsingMediaId('nas', entry.path);
      final revision = browsePreviewRevision(store, 'nas', '1');
      store.setLocal('browse:$id', {
        'source': 'nas',
        'path': entry.path,
        'size': 3,
        'previewRevision': revision,
        'fileRevision': '1',
      });
      store.setLocal('browse:index', [id]);
      final image = File('${directory.path}/old.jpg');
      await image.writeAsBytes([1, 2, 3]);
      final fingerprint = MediaPreviewRequest(
        id,
        'nas',
        entry.path,
        3,
        revision: revision,
      ).contentFingerprint;
      store.setLocal('preview:$id', {
        'path': image.path,
        'contentFingerprint': fingerprint,
        'formatVersion': MediaPreview.formatVersion,
      });
      store.setLocal('mediaMetadata:$id', {
        'fingerprint': fingerprint,
        'width': 640,
      });
      expect(
        (await model.readSourceMediaPreview(
          'nas',
          entry,
          cancel: CancelToken(),
        )).needsCapture,
        false,
      );
      store.previewWrites = 0;
      await model.saveSource({
        ...source,
        'url': 'http://new.example/share/',
      }, '');
      final binding = await model.readSourceMediaPreview(
        'nas',
        entry,
        cancel: CancelToken(),
      );
      expect(binding.needsCapture, true);
      expect(binding.thumbnail, isNull);
      expect(store.local('preview:$id'), isNull);
      expect(store.local('mediaMetadata:$id'), isNull);
      expect(store.local('browse:index'), isEmpty);
      expect(store.previewWrites, 0);
    },
  );

  test(
    'background cancels a blocked preview commit directly without frames',
    () async {
      final cancel = await captureBehindLock();
      model.setForeground(false);
      expect(cancel.cancelled, true);
      await model.pausePreviews().timeout(const Duration(seconds: 2));
      expect(store.previewWrites, 0);
      expect(store.local('preview:video'), isNull);
      releaseWriter();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.local('preview:video'), isNull);
      expect(store.local('mediaMetadata:video'), isNull);
    },
  );

  test(
    'cache maintenance cancels pending persistence before clearing caches',
    () async {
      final cancel = await captureBehindLock();
      final clearing = model.clearCaches();
      expect(cancel.cancelled, true);
      expect(store.previewWrites, 0);
      releaseWriter();
      await clearing.timeout(const Duration(seconds: 5));
      expect(store.local('preview:video'), isNull);
      expect(store.local('mediaMetadata:video'), isNull);
      expect(store.previewWrites, 0);
    },
  );
}
