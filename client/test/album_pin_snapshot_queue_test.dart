import 'dart:io';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'busy window pin writes retain only an active and latest snapshot',
    () async {
      final root = await Directory.systemTemp.createTemp('album-pin-queue-');
      final bytes = images.encodeJpg(images.Image(width: 80, height: 40));
      final entries = <SourceEntry>[];
      for (var i = 0; i < 3; i++) {
        final file = await File('${root.path}/$i.jpg').writeAsBytes(bytes);
        entries.add(
          SourceEntry(
            name: '$i.jpg',
            path: file.path,
            size: bytes.length,
            modified: 1,
          ),
        );
      }
      final service = AlbumImageService(
        cacheDirectory: '${root.path}/cache',
        sourceId: 'local',
        source: const {'kind': 'local'},
        preferOriginal: true,
        observeLifecycle: false,
      );
      Database? database;
      var locked = false;
      try {
        service.setOriginalWindow([entries[0]]);
        expect((await service.load(entries[0]).future).path, isNotNull);
        final second = await service.load(entries[1]).future;
        expect(second.path, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final db = database = sqlite3.open(
          '${root.path}/cache/album-cache-v1.sqlite',
        );
        db.execute('PRAGMA busy_timeout=1000');
        db.execute('CREATE TABLE window_writes(value INTEGER)');
        db.execute(
          '''CREATE TRIGGER count_window_writes AFTER INSERT ON live_pins
        WHEN NEW.role='window' BEGIN INSERT INTO window_writes VALUES(1); END''',
        );
        db.execute('BEGIN IMMEDIATE');
        locked = true;
        for (var i = 0; i < 200; i++) {
          service.setOriginalWindow([entries[i % 2]]);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final third = service.load(entries[2]).future;
        db.execute('COMMIT');
        locked = false;
        expect(
          (await third).path,
          isNotNull,
          reason:
              'Source publication and pin acknowledgment must not deadlock.',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final writes =
            db.select('SELECT count(*) AS n FROM window_writes').single['n']
                as int;
        expect(writes, inInclusiveRange(1, 2));
        expect(
          db
              .select("SELECT path FROM live_pins WHERE role='window'")
              .map((row) => row['path']),
          [second.path],
        );
        expect(
          db.select("SELECT path FROM live_pins WHERE role LIKE 'read:%'"),
          isEmpty,
          reason:
              'Acknowledged window protection replaces temporary read pins.',
        );

        db.execute('BEGIN IMMEDIATE');
        locked = true;
        for (var i = 0; i < 100; i++) {
          service.setOriginalWindow([entries[i % 2]]);
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        service.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        db.execute('COMMIT');
        locked = false;
        for (var i = 0; i < 100; i++) {
          if (db.select('SELECT path FROM live_pins').isEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          db.select('SELECT path FROM live_pins'),
          isEmpty,
          reason: 'Late queued snapshots cannot resurrect a closed owner.',
        );
      } finally {
        if (locked) database?.execute('ROLLBACK');
        service.dispose();
        database?.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await root.delete(recursive: true);
      }
    },
  );
}
