import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStore store;
  late AppModel model;
  var disposed = false;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('local-video-removal-');
    store = await AppStore.open(p.join(root.path, 'app.sqlite'));
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    model = AppModel(store, root, backgroundWork: false);
    disposed = false;
    await model.downloads.initialize();
  });

  tearDown(() async {
    await model.downloads.close();
    if (!disposed) model.dispose();
    await model.flushMetadataTasks();
    store.dispose();
    await root.delete(recursive: true);
  });

  Future<SyncRecord> seed(String id, String path, {bool create = true}) async {
    final file = File(path);
    if (create) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
    }
    store.save('media', id, {
      'title': '$id.mkv',
      'fileName': '$id.mkv',
      'size': 3,
    });
    store.setLocal('location:$id', {
      'id': id,
      'source': 'local',
      'path': path,
      'size': 3,
    });
    return store.get('media', id)!;
  }

  String managed(String name) =>
      p.join(root.path, 'media', 'eaa3c1b2-2304-45d8-830d-d794ce35156b', name);

  test(
    'local delete removes managed copy and tombstones while keeping siblings',
    () async {
      final path = managed('episode.mkv');
      final record = await seed('episode', path);
      final sibling = File(managed('keep.srt'));
      await sibling.writeAsString('subtitle');
      store.save('progress', 'episode:3', {'position': 1});
      store.save('match', 'episode', {'episodeId': '1'});
      store.save('watched', model.watchedKey(record), {'watched': true});
      await model.deleteLocalVideo(record);
      expect(await File(path).exists(), isFalse);
      expect(await sibling.exists(), isTrue);
      expect(store.get('media', 'episode')?.deleted, isTrue);
      expect(store.get('progress', 'episode:3')?.deleted, isTrue);
      expect(store.get('match', 'episode')?.deleted, isTrue);
      expect(store.get('watched', model.watchedKey(record))?.deleted, isFalse);
      expect(store.local('location:episode'), isNull);
      expect((await model.loadLibrarySnapshot()).localEntries, isEmpty);
    },
  );

  test('local delete preserves linked originals and symlinks', () async {
    final path = p.join(root.path, 'external', 'linked.mkv');
    final record = await seed('linked', path);
    final link = Link(managed('link.mkv'));
    await link.parent.create(recursive: true);
    await link.create(path);
    final linked = await seed('symlink', link.path, create: false);
    await model.deleteLocalVideo(linked);
    await model.deleteLocalVideo(record);
    expect(await File(path).readAsBytes(), [1, 2, 3]);
    expect(await link.exists(), isTrue);
    expect(store.get('media', 'linked')?.deleted, isTrue);
    expect(store.get('media', 'symlink')?.deleted, isTrue);
  });

  test('missing local copies can be removed idempotently', () async {
    final record = await seed('missing', managed('missing.mkv'), create: false);
    var notifications = 0;
    model.addListener(() => notifications++);
    await model.deleteLocalVideo(record);
    expect(store.get('media', record.id)?.deleted, isTrue);
    expect(store.local('location:${record.id}'), isNull);
    final first = notifications;
    await model.deleteLocalVideo(record);
    expect(notifications, first);
  });

  test(
    'locked deletion leaves the main isolate responsive and rejects a later rebind',
    () async {
      // Initialize the reusable worker before holding the main connection lock.
      await model.deleteLocalVideo(await seed('warmup', managed('warmup.mkv')));
      final oldPath = managed('old.mkv');
      final newPath = managed('new.mkv');
      final record = await seed('episode', oldPath);
      await File(newPath).writeAsBytes([4, 5, 6]);
      store.db.execute('BEGIN IMMEDIATE');
      final deleting = model.deleteLocalVideo(record);
      final cancelled = expectLater(deleting, throwsA(isA<Cancelled>()));
      try {
        // This timer runs while the worker retries the database lock, without
        // pumping a Flutter frame or synchronously waiting on the UI isolate.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        store.setLocal('location:episode', {
          'id': 'episode',
          'source': 'local',
          'path': newPath,
          'size': 3,
        });
      } finally {
        store.db.execute('COMMIT');
      }
      await cancelled;
      expect(await File(oldPath).exists(), isTrue);
      expect(await File(newPath).readAsBytes(), [4, 5, 6]);
      expect(store.get('media', record.id)?.deleted, isFalse);
      expect(store.local('location:episode')['path'], newPath);
    },
  );

  test(
    'disposing during a lock wait cancels local deletion without a new frame',
    () async {
      await model.deleteLocalVideo(await seed('warmup', managed('warmup.mkv')));
      final path = managed('keep.mkv');
      final record = await seed('keep', path);
      store.db.execute('BEGIN IMMEDIATE');
      final deleting = model.deleteLocalVideo(record);
      final cancelled = expectLater(deleting, throwsA(isA<Cancelled>()));
      try {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        model.dispose();
        disposed = true;
        await cancelled;
      } finally {
        store.db.execute('COMMIT');
      }
      await model.flushMetadataTasks();
      expect(await File(path).exists(), isTrue);
      expect(store.get('media', record.id)?.deleted, isFalse);
    },
  );
}
