import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_sort.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup schema preparation waits away from the UI isolate', () async {
    final directory = Directory.systemTemp.createTempSync('library-schema-');
    final path = '${directory.path}/app.db';
    final other = AppStore(path);
    final deviceId = other.deviceId;
    // Exercise the production startup path against a pre-upgrade database.
    other.db.execute('PRAGMA user_version=2');
    other.db.execute('BEGIN IMMEDIATE');
    var released = false;
    final release = Timer(const Duration(milliseconds: 100), () {
      released = true;
      other.db.execute('COMMIT');
    });
    AppStore? opened;
    try {
      opened = await AppStore.open(path);
      expect(released, isTrue);
      expect(opened.deviceId, deviceId);
      expect(opened.db.select('PRAGMA user_version').single.values.single, 3);
    } finally {
      release.cancel();
      if (!released) other.db.execute('ROLLBACK');
      opened?.dispose();
      other.dispose();
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'sort persistence waits for the database away from the UI isolate',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'library-sort-write-',
      );
      final store = AppStore('${directory.path}/app.db');
      final other = AppStore.openExisting(store.path);
      final model = AppModel(store, directory, backgroundWork: false);
      var released = false;
      Timer? release;
      try {
        store.setLocal('settings', {'volume': 60});
        final mediaRevision = store.recordsRevision('media');
        final progressRevision = store.recordsRevision('progress');
        final locationRevision = store.locationRevision;
        // A simultaneous writer owns the lock and changes an unrelated setting.
        other.db.execute('BEGIN IMMEDIATE');
        other.setLocal('settings', {'volume': 25, 'autoPlay': false});
        release = Timer(const Duration(milliseconds: 100), () {
          released = true;
          other.db.execute('COMMIT');
        });
        await model.setLibrarySorting(
          const LibrarySort(field: 'name', descending: false),
        );
        expect(released, isTrue);
        expect(model.preferences.volume, 25);
        expect(model.preferences.autoPlay, isFalse);
        expect(store.recordsRevision('media'), mediaRevision);
        expect(store.recordsRevision('progress'), progressRevision);
        expect(store.locationRevision, locationRevision);
        expect(
          model.librarySorting,
          const LibrarySort(field: 'name', descending: false),
        );
        final revision = store.localKeyRevision('settings');
        var notifications = 0;
        model.addListener(() => notifications++);
        await model.setLibrarySorting(model.librarySorting);
        expect(notifications, 0);
        expect(store.localKeyRevision('settings'), revision);
      } finally {
        release?.cancel();
        if (!released) other.db.execute('ROLLBACK');
        model.dispose();
        other.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'rapid choices keep only one active write and the latest pending choice',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'library-sort-queue-',
      );
      final store = _HeldSettingsStore();
      final model = AppModel(store, directory, backgroundWork: false);
      try {
        await expectLater(
          model.setLibrarySorting(const LibrarySort(field: 'unsupported')),
          throwsArgumentError,
        );
        expect(store.writes, 0);
        final writes = [
          model.setLibrarySorting(const LibrarySort(field: 'name')),
        ];
        for (var i = 0; i < 30; i++) {
          writes.add(
            model.setLibrarySorting(
              LibrarySort(field: i.isEven ? 'size' : 'modified'),
            ),
          );
        }
        writes.add(
          model.setLibrarySorting(
            const LibrarySort(field: 'updated', descending: false),
          ),
        );
        expect(store.writes, 1);
        store.release.complete();
        await Future.wait(writes);
        expect(store.writes, 2);
        expect(
          model.librarySorting,
          const LibrarySort(field: 'updated', descending: false),
        );
      } finally {
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'disposing the model drops pending choices and late notifications',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'library-sort-dispose-',
      );
      final store = _HeldSettingsStore();
      final model = AppModel(store, directory, backgroundWork: false);
      var notifications = 0;
      model.addListener(() => notifications++);
      final first = model.setLibrarySorting(const LibrarySort(field: 'name'));
      final last = model.setLibrarySorting(const LibrarySort(field: 'size'));
      model.dispose();
      try {
        store.release.complete();
        await Future.wait([first, last]);
        expect(store.writes, 1);
        expect(notifications, 0);
      } finally {
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );
}

class _HeldSettingsStore extends AppStore {
  final release = Completer<void>();
  var writes = 0;
  _HeldSettingsStore() : super(':memory:');

  @override
  Future<bool> patchSettingsInBackground(Map<String, dynamic> patch) async {
    writes++;
    await release.future;
    return super.patchSettingsInBackground(patch);
  }
}
