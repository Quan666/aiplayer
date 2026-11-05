import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:sqlite3/sqlite3.dart';

Future<void> _until(Future<bool> Function() ready) async {
  for (var i = 0; i < 300; i++) {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('The original working set did not settle.');
}

class _Fixture {
  final Directory root;
  final List<SourceEntry> entries;
  final List<AlbumImageService> services = [];
  _Fixture(this.root, this.entries);

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('album-window-service-');
    final bytes = await Isolate.run(
      () => images.encodeJpg(images.Image(width: 800, height: 600)),
    );
    final entries = <SourceEntry>[];
    for (var i = 0; i < 20; i++) {
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
    return _Fixture(root, entries);
  }

  AlbumImageService service({bool original = true, int? bytes}) {
    final value = AlbumImageService(
      cacheDirectory: '${root.path}/cache',
      sourceId: 'local',
      source: const {'kind': 'local'},
      preferOriginal: original,
      maxCacheBytes: bytes ?? 1024 * 1024,
    );
    services.add(value);
    return value;
  }

  Future<int> originals() async {
    final directory = Directory('${root.path}/cache/album-images-v2');
    if (!await directory.exists()) return 0;
    return directory.list().where((file) => file.path.endsWith('.jpg')).length;
  }

  Future<int> pins() {
    final path = '${root.path}/cache/album-cache-v1.sqlite';
    return Isolate.run(() => _pinsAt(path));
  }

  static int _pinsAt(String path) {
    final database = sqlite3.open(path);
    try {
      return database.select('SELECT COUNT(*) AS n FROM live_pins').single['n']
          as int;
    } finally {
      database.dispose();
    }
  }

  Future<void> close() async {
    for (final service in services) {
      service.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await root.delete(recursive: true);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  tearDown(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );

  test('gesture hold permits source reads but reclamation waits for foreground without a frame', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final viewer = fixture.service();
    viewer.setMaintenanceHeld(true);
    viewer.setOriginalWindow(fixture.entries.take(5).toList());
    final results = <AlbumImageResult>[];
    for (final entry in fixture.entries.take(18)) {
      final result = await viewer.load(entry).future;
      expect(result.error, isNull);
      expect(result.encodedSource, isTrue);
      results.add(result);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(await fixture.originals(), 18);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    viewer.setOriginalWindow(fixture.entries.sublist(13, 18).reversed.toList());
    viewer.setMaintenanceHeld(false);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    // There has been no pump since the lifecycle event.
    expect(await fixture.originals(), 18);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _until(() async => await fixture.originals() == 13);
    expect(await File(results[0].path!).exists(), isFalse);
    for (final result in results.sublist(5)) {
      expect(await File(result.path!).exists(), isTrue);
    }
    final reverse = await viewer.load(fixture.entries[10]).future;
    expect(reverse.path, results[10].path);
    viewer.dispose();
    await _until(() async => await fixture.pins() == 0);
  });

  test('a far grid image falls back to its durable small file instead of evicting active full-size frames', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final budget = fixture.entries.first.size * 2 + 8192;
    final viewer = fixture.service(bytes: budget);
    viewer.setOriginalWindow([
      fixture.entries[0],
      fixture.entries[1],
      fixture.entries[3],
    ]);
    final current = await viewer.load(fixture.entries[0]).future;
    final near = await viewer.load(fixture.entries[1]).future;
    expect(current.path, isNotNull);
    expect(near.path, isNotNull);
    final wall = fixture.service(original: false, bytes: budget);
    final far = await wall.load(fixture.entries[2]).future;
    expect(far.error, isNull);
    expect(far.path, contains('album-thumbnails-v1'));
    expect(far.width, 512);
    expect(await File(current.path!).exists(), isTrue);
    expect(await File(near.path!).exists(), isTrue);
    // A speculative neighbor is deferred before opening an unavailable source.
    await File(fixture.entries[3].path).delete();
    final speculative = await viewer.load(fixture.entries[3]).future;
    expect(speculative.deferred, isTrue);
    expect(speculative.error, isNull);
    expect(await File(current.path!).exists(), isTrue);
  });

  test('a corrupt disposable index does not prevent reopening valid prepared pixels', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.close);
    final first = fixture.service();
    first.setOriginalWindow([fixture.entries.first]);
    final prepared = await first.load(fixture.entries.first).future;
    expect(prepared.path, isNotNull);
    first.dispose();
    await _until(() async => await fixture.pins() == 0);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final index = File('${fixture.root.path}/cache/album-cache-v1.sqlite');
    await index.writeAsString('damaged disposable cache index', flush: true);
    await File(fixture.entries.first.path).delete();
    final reopened = fixture.service();
    reopened.setOriginalWindow([fixture.entries.first]);
    final result = await reopened.load(fixture.entries.first).future;
    expect(result.error, isNull);
    expect(result.path, prepared.path);
    expect(await File(result.path!).exists(), isTrue);
  });
}
