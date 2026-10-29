import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'folder removal deletes nested downloads and preserves remote media and unrelated files',
    () async {
      final fixture = await _Fixture.create();
      try {
        final unrelated = File(
          p.join(fixture.offline.path, 'copies', 'Show', 'notes.txt'),
        );
        await unrelated.writeAsString('keep');
        final plan = await fixture.model.prepareLocalDirectoryRemoval(
          _Fixture.folder,
        );
        expect(plan.count, 2);
        expect(plan.downloads, 2);
        var updates = 0;
        fixture.model.downloads.addListener(() => updates++);
        final result = await fixture.model.deleteLocalDirectory(plan);
        expect(result.removed, 2);
        expect(result.failed, 0);
        expect(result.skipped, 0);
        expect(updates, 1);
        for (final id in ['one', 'two']) {
          expect(await File(fixture.files[id]!).exists(), isFalse);
          expect(fixture.store.get('media', id)?.deleted, isFalse);
          expect(fixture.store.local('location:$id')['source'], 'dav');
          expect(fixture.model.downloads.entryFor(id), isNull);
        }
        expect(await unrelated.readAsString(), 'keep');
        expect(await File(fixture.files['other']!).exists(), isTrue);
        expect(fixture.model.downloads.entryFor('other')?.isComplete, isTrue);
        final snapshot = await fixture.model.loadLibrarySnapshot();
        expect(snapshot.localDirectories, isNot(contains(_Fixture.folder)));
        expect(snapshot.localRecords.keys, ['other']);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'root removal handles downloaded copies, managed imports and linked originals',
    () async {
      final fixture = await _Fixture.create(local: true);
      try {
        final plan = await fixture.model.prepareLocalDirectoryRemoval('');
        expect(plan.downloads, 3);
        expect(plan.managed, 1);
        expect(plan.linked, 1);
        final result = await fixture.model.deleteLocalDirectory(plan);
        expect(result.removed, 5);
        expect(await File(fixture.files['managed']!).exists(), isFalse);
        expect(await File(fixture.files['linked']!).readAsBytes(), [1, 2, 3]);
        expect(await File('${fixture.files['managed']!}.srt').exists(), isTrue);
        expect(fixture.store.get('media', 'managed')?.deleted, isTrue);
        expect(fixture.store.get('media', 'linked')?.deleted, isTrue);
        expect(fixture.store.get('media', 'one')?.deleted, isFalse);
        expect(
          (await fixture.model.loadLibrarySnapshot()).localRecords,
          isEmpty,
        );
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'a confirmed plan skips rebound media and replaced local files',
    () async {
      final fixture = await _Fixture.create();
      try {
        final plan = await fixture.model.prepareLocalDirectoryRemoval(
          _Fixture.folder,
        );
        fixture.store.setLocal('location:one', {
          'id': 'one',
          'source': 'dav',
          'path': 'replacement.mp4',
          'size': 3,
        });
        await File(fixture.files['two']!).writeAsBytes([9, 8, 7, 6]);
        final result = await fixture.model.deleteLocalDirectory(plan);
        expect(result.removed, 0);
        expect(result.skipped, 2);
        expect(await File(fixture.files['one']!).exists(), isTrue);
        expect(await File(fixture.files['two']!).readAsBytes(), [9, 8, 7, 6]);
        expect(fixture.model.downloads.entries, hasLength(3));
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'cancellation interrupts a database lock wait without a Flutter frame',
    () async {
      final fixture = await _Fixture.create();
      try {
        final plan = await fixture.model.prepareLocalDirectoryRemoval(
          _Fixture.folder,
        );
        final cancel = CancelToken();
        fixture.store.db.execute('BEGIN IMMEDIATE');
        final removing = fixture.model.deleteLocalDirectory(
          plan,
          cancel: cancel,
        );
        try {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          cancel.cancel();
          final result = await removing.timeout(const Duration(seconds: 2));
          expect(result.cancelled, isTrue);
          expect(result.removed, 0);
        } finally {
          fixture.store.db.execute('ROLLBACK');
        }
        expect(await File(fixture.files['one']!).exists(), isTrue);
        expect(await File(fixture.files['two']!).exists(), isTrue);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'unsafe replacement reports failure and keeps all original files',
    () async {
      final fixture = await _Fixture.create();
      try {
        final plan = await fixture.model.prepareLocalDirectoryRemoval(
          _Fixture.folder,
        );
        final unrelated = File(p.join(fixture.directory.path, 'unrelated.mp4'));
        await unrelated.writeAsBytes([4, 5, 6]);
        for (final id in ['one', 'two']) {
          await Link('${fixture.files[id]!}.part').create(unrelated.path);
        }
        final result = await fixture.model.deleteLocalDirectory(plan);
        expect(result.removed, 0);
        expect(result.failed, 2);
        expect(result.error, isNotEmpty);
        expect(fixture.model.downloads.entries, hasLength(3));
        expect(await unrelated.readAsBytes(), [4, 5, 6]);
        for (final id in ['one', 'two']) {
          expect(await File(fixture.files[id]!).readAsBytes(), [1, 2, 3]);
        }
      } finally {
        await fixture.close();
      }
    },
  );

  test('discarded deletion previews cannot later remove files', () async {
    final fixture = await _Fixture.create();
    try {
      final plan = await fixture.model.prepareLocalDirectoryRemoval(
        _Fixture.folder,
      );
      await fixture.model.discardLocalDirectoryRemoval(plan);
      await expectLater(
        fixture.model.deleteLocalDirectory(plan),
        throwsA(isA<AppFailure>()),
      );
      expect(await File(fixture.files['one']!).exists(), isTrue);
    } finally {
      await fixture.close();
    }
  });

  testWidgets(
    'local folder menu previews count, supports cancel and returns from a deleted directory',
    (tester) async {
      late _Fixture fixture;
      await tester.runAsync(() async => fixture = await _Fixture.create());
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme().copyWith(
              platform: TargetPlatform.macOS,
            ),
            home: Scaffold(
              body: SourcesPage(
                model: fixture.model,
                onImport: () async {},
                onPlay: (_) async {},
              ),
            ),
          ),
        );
        await _wait(tester, () => find.text('本地视频').evaluate().isNotEmpty);
        await tester.tap(find.text('本地视频'));
        final folder = find.byKey(
          const ValueKey('local-folder:${_Fixture.folder}'),
        );
        final menu = find.byKey(
          const ValueKey('local-folder-options:${_Fixture.folder}'),
        );
        await _wait(tester, () => menu.evaluate().isNotEmpty);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除文件夹'));
        await _wait(tester, () => find.text('删除文件夹？').evaluate().isNotEmpty);
        expect(find.textContaining('Show'), findsWidgets);
        expect(find.textContaining('2 个本地视频'), findsOneWidget);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        await _wait(
          tester,
          () => tester.widget<PopupMenuButton<String>>(menu).enabled,
        );
        expect(fixture.model.downloads.entries, hasLength(3));

        await tester.tap(
          find.descendant(of: folder, matching: find.text('Show')),
        );
        await _wait(
          tester,
          () => find
              .byKey(const ValueKey('local-video:one'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(find.byTooltip('本地视频选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除文件夹'));
        await _wait(tester, () => find.text('删除文件夹？').evaluate().isNotEmpty);
        await tester.tap(find.text('删除'));
        await _wait(tester, () => fixture.model.downloads.completedCount == 1);
        await _wait(tester, () => find.text('Other').evaluate().isNotEmpty);
        expect(folder, findsNothing);
        expect(find.text('本地视频'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(fixture.close);
      }
    },
  );
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 10)) {
      fail('Local folder UI did not settle.');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _Fixture {
  static const folder = 'download-selection:["dav","2026-10/Show","Show"]';
  final Directory directory, offline;
  final AppStore store;
  final Map<String, String> files;
  late final model = AppModel(store, directory, backgroundWork: false);
  _Fixture(this.directory, this.offline, this.store, this.files);

  static Future<_Fixture> create({bool local = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'local-folder-removal-',
    );
    final store = await AppStore.open(p.join(directory.path, 'app.sqlite'));
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.setLocal('sources', [
      {'id': 'dav', 'kind': 'webdav', 'label': 'DAV'},
    ]);
    final offline = await Directory(p.join(directory.path, 'offline')).create();
    final downloads = sqlite3.open(p.join(offline.path, 'downloads.sqlite'));
    downloads.execute(
      'CREATE TABLE downloads(id TEXT PRIMARY KEY,value TEXT NOT NULL)',
    );
    final files = <String, String>{};
    var order = 0;
    for (final (id, relative, selected) in [
      ('one', 'Show/one.mp4', '2026-10/Show'),
      ('two', 'Show/Sub/two.mp4', '2026-10/Show'),
      ('other', 'Other/other.mp4', '2026-10/Other'),
    ]) {
      final path = p.join(offline.path, 'copies', relative);
      await File(path).parent.create(recursive: true);
      await File(path).writeAsBytes([1, 2, 3]);
      files[id] = path;
      store.save('media', id, {
        'title': '$id.mp4',
        'fileName': '$id.mp4',
        'size': 3,
      });
      store.setLocal('location:$id', {
        'id': id,
        'source': 'dav',
        'path': '2026-10/$relative',
        'size': 3,
      });
      downloads.execute('INSERT INTO downloads(id,value) VALUES(?,?)', [
        id,
        jsonEncode({
          'mediaId': id,
          'sourceId': 'dav',
          'remotePath': '2026-10/$relative',
          'localPath': path,
          'name': '$id.mp4',
          'status': 'completed',
          'downloadRoot': selected,
          'downloadRelativePath': relative,
          'total': 3,
          'received': 3,
          'createdOrder': ++order,
        }),
      ]);
    }
    downloads.dispose();
    if (local) {
      for (final (id, path) in [
        (
          'managed',
          p.join(
            directory.path,
            'media',
            'eaa3c1b2-2304-45d8-830d-d794ce35156b',
            'clip.mp4',
          ),
        ),
        ('linked', p.join(directory.path, 'external', 'clip.mp4')),
      ]) {
        await File(path).parent.create(recursive: true);
        await File(path).writeAsBytes([1, 2, 3]);
        files[id] = path;
        store.save('media', id, {
          'title': '$id.mp4',
          'fileName': '$id.mp4',
          'size': 3,
          'localOnly': true,
        });
        store.setLocal('location:$id', {
          'id': id,
          'source': 'local',
          'path': path,
          'size': 3,
        });
      }
      await File('${files['managed']!}.srt').writeAsString('keep');
    }
    final fixture = _Fixture(directory, offline, store, files);
    await fixture.model.downloads.initialize();
    return fixture;
  }

  Future<void> close() async {
    await model.downloads.close();
    model.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  }
}
