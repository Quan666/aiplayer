import 'dart:io';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'warm disk touches coalesce behind a busy peer and stop on pause or close',
    () async {
      final root = await Directory.systemTemp.createTemp('album-touch-queue-');
      final bytes = images.encodeJpg(images.Image(width: 80, height: 40));
      final source = await File('${root.path}/photo.jpg').writeAsBytes(bytes);
      final other = await File('${root.path}/other.jpg').writeAsBytes(bytes);
      final entry = SourceEntry(
        name: 'photo.jpg',
        path: source.path,
        size: bytes.length,
        modified: 1,
      );
      final second = SourceEntry(
        name: 'other.jpg',
        path: other.path,
        size: bytes.length,
        modified: 1,
      );
      final service = AlbumImageService(
        cacheDirectory: '${root.path}/cache',
        sourceId: 'local',
        source: const {'kind': 'local'},
        observeLifecycle: false,
      );
      Database? database;
      var locked = false;
      try {
        final ready = await service.load(entry).future;
        expect(ready.path, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final db = database = sqlite3.open(
          '${root.path}/cache/album-cache-v1.sqlite',
        );
        db.execute('PRAGMA busy_timeout=1000');
        db.execute('CREATE TABLE touch_count(value INTEGER NOT NULL)');
        db.execute(
          '''CREATE TRIGGER count_touches AFTER UPDATE OF used ON entries
        BEGIN INSERT INTO touch_count VALUES(1); END''',
        );
        int count() =>
            db.select('SELECT count(*) AS n FROM touch_count').single['n']
                as int;
        Future<void> burst() async {
          for (var i = 0; i < 100; i++) {
            expect(service.peek(entry), same(ready));
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }

        void lock() {
          db.execute('BEGIN IMMEDIATE');
          locked = true;
        }

        void unlock() {
          db.execute('COMMIT');
          locked = false;
        }

        lock();
        await burst();
        final visible = service.load(second).future;
        unlock();
        expect((await visible).path, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(
          count(),
          inInclusiveRange(1, 3),
          reason: 'A blocked writer retains only the current and latest access batches.',
        );

        db.execute('DELETE FROM touch_count');
        lock();
        await burst();
        service.setActive(false);
        // This is a pure test: no Flutter frame is pumped to stop the worker.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        unlock();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(count(), 0);
        service.setActive(true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          count(),
          0,
          reason: 'Cancelled access batches must not revive on resume.',
        );
        service.peek(entry);
        for (var i = 0; i < 100 && count() == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(count(), 1);

        db.execute('DELETE FROM touch_count');
        lock();
        await burst();
        service.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        unlock();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(count(), 0);
      } finally {
        if (locked) database?.execute('ROLLBACK');
        service.dispose();
        database?.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await root.delete(recursive: true);
      }
    },
  );
}
