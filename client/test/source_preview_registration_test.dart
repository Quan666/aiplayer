import 'dart:async';
import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/core/logger.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

class _PreviewModel extends AppModel {
  _PreviewModel(super.store, super.documents)
    : super(backgroundWork: false, enableThumbnails: true);

  final scheduled = <String>[];
  final ready = Completer<void>();
  int expected = 1;

  @override
  void ensureMediaPreview(String id) {
    scheduled.add(id);
    if (scheduled.length == expected && !ready.isCompleted) ready.complete();
  }
}

SourceEntry _entry(int index, {int size = 10}) => SourceEntry(
  name: 'Episode $index.mkv',
  path: '/Series/$index.mkv',
  size: size,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late Database lock;
  var locked = false;
  AppModel? model;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source-preview-write-');
    store = AppStore('${directory.path}/library.db');
    // A UI connection must not wait for the writer. This also makes any
    // accidental synchronous write fail immediately instead of stalling tests.
    store.db.execute('PRAGMA busy_timeout=0');
    lock = sqlite3.open(store.path);
  });

  void holdWriter() {
    lock.execute('BEGIN IMMEDIATE');
    locked = true;
  }

  void releaseWriter() {
    if (!locked) return;
    lock.execute('ROLLBACK');
    locked = false;
  }

  tearDown(() async {
    releaseWriter();
    model?.dispose();
    await model?.flushMetadataTasks();
    model = null;
    lock.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'disabled source previews do not register browse state under a lock',
    () {
      model = AppModel(store, directory, backgroundWork: false);
      holdWriter();
      final id = model!.ensureSourceMediaPreview('nas', _entry(1));
      expect(id, startsWith('browse-'));
      expect(store.local('browse:$id'), isNull);
      expect(store.local('browse:index'), isNull);
    },
  );

  test(
    'browse registration waits in the worker and keeps the latest size',
    () async {
      final preview = _PreviewModel(store, directory);
      model = preview;
      holdWriter();
      final id = preview.ensureSourceMediaPreview('nas', _entry(1));
      preview.ensureSourceMediaPreview('nas', _entry(1, size: 20));
      preview.ensureSourceMediaPreview('nas', _entry(1, size: 20));
      var releasedByTimer = false;
      final release = Timer(const Duration(milliseconds: 80), () {
        releasedByTimer = true;
        releaseWriter();
      });
      try {
        expect(preview.scheduled, isEmpty);
        await preview.ready.future.timeout(const Duration(seconds: 5));
        expect(releasedByTimer, isTrue);
        expect(preview.scheduled, [id]);
        expect(store.local('browse:$id')['size'], 20);
        expect(store.local('browse:index'), [id]);
      } finally {
        release.cancel();
      }
    },
  );

  testWidgets(
    'paused browse registration stays bounded and resumes without frames',
    (tester) async {
      await tester.runAsync(() async {
        final preview = _PreviewModel(store, directory)..expected = 64;
        model = preview;
        holdWriter();
        for (var i = 0; i < 70; i++) {
          preview.ensureSourceMediaPreview('nas', _entry(i));
          preview.ensureSourceMediaPreview('nas', _entry(i));
        }
        preview.setForeground(false);
        final hiddenId = preview.ensureSourceMediaPreview('nas', _entry(100));
        releaseWriter();
        // No pump after the lifecycle signal: a late worker reply must neither
        // schedule a preview nor refill the registration queue in the background.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(preview.scheduled, isEmpty);
        final pausedIndex = List<String>.from(
          store.local('browse:index') ?? <String>[],
        );
        expect(pausedIndex.length, lessThanOrEqualTo(1));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(store.local('browse:index') ?? <String>[], pausedIndex);

        preview.setForeground(true);
        await preview.ready.future.timeout(const Duration(seconds: 5));
        expect(preview.scheduled.toSet(), hasLength(64));
        expect(store.local('browse:index'), hasLength(64));
        expect(store.local('browse:$hiddenId'), isNull);
        expect(store.records('media'), isEmpty);
      });
    },
  );

  test(
    'a rejected browse registration can use the next capacity event',
    () async {
      final preview = _PreviewModel(store, directory)..expected = 65;
      model = preview;
      holdWriter();
      for (var i = 0; i < 64; i++) {
        expect(preview.tryEnsureSourceMediaPreview('nas', _entry(i)), isTrue);
      }
      expect(preview.tryEnsureSourceMediaPreview('nas', _entry(64)), isFalse);
      var admitted = false;
      void capacityChanged() {
        if (admitted) return;
        admitted = preview.tryEnsureSourceMediaPreview('nas', _entry(64));
        if (admitted) {
          preview.sourcePreviewCapacity.removeListener(capacityChanged);
        }
      }

      preview.sourcePreviewCapacity.addListener(capacityChanged);
      try {
        releaseWriter();
        await preview.ready.future.timeout(const Duration(seconds: 5));
        expect(admitted, isTrue);
        expect(preview.scheduled.toSet(), hasLength(65));
      } finally {
        preview.sourcePreviewCapacity.removeListener(capacityChanged);
      }
    },
  );

  test(
    'failed registrations release capacity without spinning on cancelled replies',
    () async {
      final preview = _PreviewModel(store, directory);
      model = preview;
      // The UI connection remains usable, but a new worker cannot open this file.
      await File(store.path).rename('${store.path}.unavailable');
      final failed = Completer<void>();
      void logged() {
        if (AppLog.instance.entries.last.scope == '封面' && !failed.isCompleted) {
          failed.complete();
        }
      }

      var admitted = false;
      void capacityChanged() {
        if (admitted) return;
        admitted = preview.tryEnsureSourceMediaPreview('nas', _entry(64));
        if (admitted) {
          preview.sourcePreviewCapacity.removeListener(capacityChanged);
        }
      }

      AppLog.instance.addListener(logged);
      try {
        for (var i = 0; i < 64; i++) {
          expect(preview.tryEnsureSourceMediaPreview('nas', _entry(i)), isTrue);
        }
        expect(preview.tryEnsureSourceMediaPreview('nas', _entry(64)), isFalse);
        preview.sourcePreviewCapacity.addListener(capacityChanged);
        await failed.future.timeout(const Duration(seconds: 5));
        // The first request reports the worker failure; subsequent requests see
        // Cancelled. They must finish instead of starving this event-loop turn.
        await Future<void>.delayed(Duration.zero);
        expect(admitted, isTrue);
        expect(preview.scheduled, isEmpty);
      } finally {
        AppLog.instance.removeListener(logged);
        preview.sourcePreviewCapacity.removeListener(capacityChanged);
      }
    },
  );

  test(
    'disposing pending browse registration cannot launch previews',
    () async {
      final preview = _PreviewModel(store, directory);
      model = preview;
      holdWriter();
      preview.ensureSourceMediaPreview('nas', _entry(1));
      preview.ensureSourceMediaPreview('nas', _entry(2));
      preview.dispose();
      model = null;
      releaseWriter();
      await preview.flushMetadataTasks();
      expect(preview.scheduled, isEmpty);
      expect(
        (store.local('browse:index') as List? ?? const []).length,
        lessThanOrEqualTo(1),
      );
    },
  );
}
