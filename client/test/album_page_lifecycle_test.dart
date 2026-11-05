import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/album_view_settings.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  Duration? timeout,
}) async {
  final wait = Stopwatch()..start();
  for (var n = 0; !ready(); n++) {
    if (timeout == null ? n >= 180 : wait.elapsed >= timeout) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}

class _DelayedPlaybackModel extends AppModel {
  _DelayedPlaybackModel(super.store, super.documents)
    : super(backgroundWork: false);
  final started = Completer<void>(),
      release = Completer<void>(),
      finished = Completer<void>();

  @override
  Future<SyncRecord> preparePersonalMediaForPlayback(
    String sourceId,
    SourceEntry entry, {
    CancelToken? cancel,
  }) async {
    if (!started.isCompleted) started.complete();
    try {
      await release.future;
      cancel?.check();
      return await super.preparePersonalMediaForPlayback(
        sourceId,
        entry,
        cancel: cancel,
      );
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }
}

class _DelayedSourceSecrets extends FlutterSecureStorage {
  final release = Completer<String?>();
  var sourceReads = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (key != 'source:remote') return Future.value(null);
    sourceReads++;
    return release.future;
  }
}

Future<Directory> _fixture(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('album-page-life-');
      final photos = await Directory('${root.path}/photos').create();
      for (final pair in [('a', 2026), ('b', 2027)]) {
        final image = images.Image(width: 40, height: 30);
        image.exif.exifIfd['DateTimeOriginal'] = '${pair.$2}:11:04 12:00:00';
        await File('${photos.path}/${pair.$1}.jpg')
            .writeAsBytes(images.encodeJpg(image));
      }
      await Directory('${root.path}/model-a').create();
      await Directory('${root.path}/model-b').create();
      return root;
    }))!;

Widget _view(AppModel model, String folder, {bool active = true}) =>
    MaterialApp(
      home: AlbumPage(
        model: model,
        source: const {'id': 'local', 'kind': 'local'},
        initialPath: folder,
        active: active,
      ),
    );

AlbumWall _wall(WidgetTester tester) =>
    tester.widget<AlbumWall>(find.byType(AlbumWall));

Future<void> _close(
  WidgetTester tester,
  Directory root,
  List<(AppModel, AppStore)> models,
) async {
  await tester.pumpWidget(const SizedBox());
  final decodes = ArtworkDecodeQueue.instance;
  // A cancelled native decode still owns its bounded slot until it finishes.
  // Drain its real I/O and fake-zone continuations before deleting its files
  // or allowing a subsequent widget test to replace that fake async zone.
  await _until(
    tester,
    () =>
        decodes.activeCount == 0 &&
        decodes.pendingCount == 0 &&
        AlbumPage.pendingDisposals == 0,
  );
  await tester.runAsync(() async {
    for (final pair in models) {
      pair.$1.dispose();
      pair.$2.dispose();
    }
    await root.delete(recursive: true);
  });
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  // Drain resume callbacks before the next test installs another widget tree.
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'seeded album geometry appears before delayed source credentials complete',
    (tester) async {
      final root = await _fixture(tester);
      final store = AppStore(':memory:');
      final secrets = _DelayedSourceSecrets();
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        secrets: secrets,
        backgroundWork: false,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumPage(
              model: model,
              source: const {
                'id': 'remote',
                'kind': 'webdav',
                'url': 'http://127.0.0.1:1/',
              },
              initialPath: '/trip',
              initialSettings: const {},
              initialEntries: const [
                SourceEntry(name: 'movie.mp4', path: '/trip/movie.mp4'),
              ],
            ),
          ),
        );
        await _until(
          tester,
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              _wall(tester).snapshot.items.length == 1,
        );
        expect(secrets.sourceReads, 1);
        expect(secrets.release.isCompleted, isFalse);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          find.byKey(ValueKey(_wall(tester).snapshot.items.single.id)),
          findsOneWidget,
        );
      } finally {
        secrets.release.complete('test-password');
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  testWidgets(
    'replacing album owner clears cover state while source credentials are pending',
    (tester) async {
      final root = await _fixture(tester);
      final firstStore = AppStore(':memory:');
      final first = AppModel(
        firstStore,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      final secondStore = AppStore(':memory:');
      final secrets = _DelayedSourceSecrets();
      final second = AppModel(
        secondStore,
        Directory('${root.path}/model-b'),
        secrets: secrets,
        backgroundWork: false,
      );
      try {
        await tester.pumpWidget(_view(first, '${root.path}/photos'));
        await _until(tester, () => _wall(tester).snapshot.items.length == 2);
        final service = tester
            .widget<AlbumThumbnail>(find.byType(AlbumThumbnail).first)
            .service;
        final revision = service.revision;
        await tester.tap(find.byTooltip('相册选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('不显示相册封面'));
        await _until(tester, () => service.revision > revision);
        await tester.tap(find.byTooltip('相册选项'));
        await tester.pumpAndSettle();
        expect(find.text('恢复自动封面'), findsOneWidget);
        await tester.tap(find.text('选择相册封面'));
        await tester.pumpAndSettle();
        expect(find.text('选择相册封面'), findsOneWidget);

        // Reuse the existing page state, but provide neither a listing nor
        // settings for the new owner. Credentials deliberately remain pending.
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumPage(
              model: second,
              source: const {
                'id': 'remote',
                'kind': 'webdav',
                'url': 'http://127.0.0.1:1/',
              },
              initialPath: '/trip',
            ),
          ),
        );
        await _until(tester, () => secrets.sourceReads == 1);
        expect(secrets.release.isCompleted, isFalse);
        expect(_wall(tester).snapshot.items, isEmpty);
        expect(find.text('选择相册封面'), findsNothing);
        expect(find.text('trip'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.byTooltip('排序'),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byTooltip('相册选项'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('恢复自动封面'), findsNothing);
        for (final label in ['选择相册封面', '不显示相册封面']) {
          final item = tester.widget<PopupMenuItem<String>>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(PopupMenuItem<String>),
            ),
          );
          expect(item.enabled, isFalse, reason: label);
        }
      } finally {
        await _close(tester, root, [
          (first, firstStore),
          (second, secondStore),
        ]);
      }
    },
  );

  testWidgets(
    'provided listing and settings render without relisting a missing source directory',
    (tester) async {
      final root = await _fixture(tester);
      final folder = '${root.path}/missing';
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumPage(
              model: model,
              source: const {'id': 'local', 'kind': 'local'},
              initialPath: folder,
              initialEntries: [
                SourceEntry(name: 'photo.jpg', path: '$folder/photo.jpg'),
                SourceEntry(name: '001.mp4', path: '$folder/001.mp4'),
                SourceEntry(name: '002.mp4', path: '$folder/002.mp4'),
              ],
              initialSettings: {
                'options': AlbumOptions(
                  types: ['.mp4'],
                  sortField: 'name',
                  descending: true,
                ).toJson(),
              },
            ),
          ),
        );
        await _until(
          tester,
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              _wall(tester).snapshot.items.length == 2,
        );
        expect(
          _wall(tester).snapshot.items.map((item) => item.preferred.name),
          ['002.mp4', '001.mp4'],
        );
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          await tester.runAsync(() => Directory(folder).exists()),
          isFalse,
        );
        // A directory read would have failed; the complete filtered snapshot is
        // produced from the source browser's already available listing instead.
        expect(find.textContaining('读取相册失败'), findsNothing);
      } finally {
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  testWidgets(
    'album wall fills beneath safe toolbar and floating outer navigation',
    (tester) async {
      tester.view.physicalSize = const Size(400, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = await _fixture(tester);
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => MediaQuery(
              data: const MediaQueryData(
                size: Size(400, 720),
                padding: EdgeInsets.only(top: 24, bottom: 28),
                viewPadding: EdgeInsets.only(top: 24, bottom: 28),
              ),
              child: child!,
            ),
            home: Scaffold(
              extendBody: true,
              bottomNavigationBar: const SizedBox(
                key: ValueKey('outer-floating-nav'),
                height: 76,
              ),
              body: AlbumPage(
                model: model,
                source: const {'id': 'local', 'kind': 'local'},
                initialPath: '${root.path}/missing',
                initialEntries: [
                  for (var index = 0; index < 100; index++)
                    SourceEntry(name: '$index.mp4', path: '/$index.mp4'),
                ],
                initialSettings: const {},
              ),
            ),
          ),
        );
        await _until(tester, () => _wall(tester).snapshot.items.length == 100);
        final grid = find.byKey(const ValueKey('album-wall'));
        expect(tester.getRect(grid), const Rect.fromLTWH(0, 0, 400, 720));
        final nav = tester.getRect(
          find.byKey(const ValueKey('outer-floating-nav')),
        );
        expect(nav.top, 644);
        expect(tester.getRect(grid).bottom, greaterThan(nav.top));
        final first = find.byKey(
          ValueKey(_wall(tester).snapshot.items.first.id),
        );
        expect(tester.getTopLeft(first), const Offset(0, 72));
        final position = _wall(tester).controller;
        position.jumpTo(100);
        await tester.pump();
        expect(tester.getTopLeft(first).dy, lessThan(24));
        position.jumpTo(0);
        await tester.pump();
        expect(tester.getTopLeft(first).dy, 72);
        expect(
          tester.getTopLeft(find.byType(BackButton)).dy,
          inInclusiveRange(24, 40),
        );
        expect(find.byType(AppBar), findsOneWidget);
        expect(find.byTooltip('显示工具栏'), findsNothing);
      } finally {
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  testWidgets(
    'capture metadata loads automatically and refresh retries a repaired file',
    (tester) async {
      final root = await _fixture(tester);
      final folder = '${root.path}/photos';
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      await tester.runAsync(() async {
        await File('$folder/broken.arw').writeAsBytes([0, 1, 2]);
        final prefs = File(
          albumSettingsPath(model.documents.path, 'local', folder),
        );
        await prefs.parent.create(recursive: true);
        await prefs.writeAsString(
          jsonEncode({
            'options': AlbumOptions(
              includeExtensions: ['.arw'],
              dateField: 'captured',
              dateFrom: 1,
            ).toJson(),
          }),
        );
      });
      try {
        await tester.pumpWidget(_view(model, folder));
        await _until(
          tester,
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              _wall(tester).snapshot.pendingMetadataCount == 1,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        expect(find.text('读取拍摄信息'), findsNothing);
        await tester.runAsync(() async {
          final image = images.Image(width: 40, height: 30);
          image.exif.exifIfd['DateTimeOriginal'] = '2026:11:04 12:00:00';
          await File('$folder/broken.arw')
              .writeAsBytes(images.encodeJpg(image));
        });
        await tester.tap(find.byTooltip('相册选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('刷新'));
        await _until(tester, () => _wall(tester).snapshot.items.length == 1);
        expect(
          _wall(tester).snapshot.items.single.preferred.name,
          'broken.arw',
        );
        expect(_wall(tester).snapshot.pendingMetadataCount, 0);
        expect(find.text('1 项读取失败，重试'), findsNothing);
      } finally {
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  testWidgets(
    'chosen folder cover replaces its cached parent preview on return',
    (tester) async {
      final root = await _fixture(tester);
      final folder = '${root.path}/photos', child = '$folder/trip';
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      await tester.runAsync(() async {
        await Directory(child).create();
        for (final name in ['a.jpg', 'b.jpg']) {
          await File('$folder/$name').rename('$child/$name');
        }
      });
      try {
        await tester.pumpWidget(_view(model, folder));
        await _until(
          tester,
          () => find.byType(AlbumThumbnail).evaluate().isNotEmpty,
        );
        final cover = tester.widget<AlbumThumbnail>(
          find.byType(AlbumThumbnail).first,
        );
        AlbumImageResult? initial;
        unawaited(
          cover.service
              .load(cover.entry, targetEdge: cover.edge, folder: true)
              .future
              .then((result) => initial = result),
        );
        await _until(tester, () => initial != null);
        expect(initial!.sourcePath, '$child/a.jpg');
        await tester.tap(
          find.byKey(ValueKey(_wall(tester).snapshot.items.single.id)),
        );
        await _until(tester, () => _wall(tester).snapshot.items.length == 2);
        final item = _wall(tester).snapshot.items
            .firstWhere((item) => item.preferred.path == '$child/b.jpg');
        final revision = cover.service.revision;
        await tester.longPress(find.byKey(ValueKey(item.id)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('设为相册封面'));
        await _until(tester, () => cover.service.revision > revision);
        await tester.tap(find.byType(BackButton));
        await _until(
          tester,
          () =>
              _wall(tester).snapshot.items.length == 1 &&
              _wall(tester).snapshot.items.single.isDirectory,
        );
        AlbumImageResult? updated;
        unawaited(
          cover.service
              .load(cover.entry, targetEdge: cover.edge, folder: true)
              .future
              .then((result) => updated = result),
        );
        await _until(tester, () => updated != null);
        expect(updated!.sourcePath, '$child/b.jpg');
      } finally {
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  for (final restore in ['automatic', 'chosen']) {
    testWidgets(
      'hidden album cover persists after reopening and restores $restore artwork',
      (tester) async {
        final root = await _fixture(tester);
        final folder = '${root.path}/photos', child = '$folder/trip';
        final store = AppStore(':memory:');
        final model = AppModel(
          store,
          Directory('${root.path}/model-a'),
          backgroundWork: false,
        );
        await tester.runAsync(() async {
          await Directory(child).create();
          for (final name in ['a.jpg', 'b.jpg']) {
            await File('$folder/$name').rename('$child/$name');
          }
        });

        Future<AlbumThumbnail> parentCover() async {
          await _until(
            tester,
            () =>
                _wall(tester).snapshot.items.singleOrNull?.isDirectory ==
                    true &&
                find.byType(AlbumThumbnail).evaluate().isNotEmpty,
          );
          return tester.widget<AlbumThumbnail>(
            find.byType(AlbumThumbnail).first,
          );
        }

        Future<AlbumImageResult> readCover(AlbumThumbnail cover) async {
          AlbumImageResult? result;
          unawaited(
            cover.service
                .load(cover.entry, targetEdge: cover.edge, folder: true)
                .future
                .then((value) => result = value),
          );
          await _until(tester, () => result != null);
          return result!;
        }

        Future<void> enterChild() async {
          await tester.tap(
            find.byKey(ValueKey(_wall(tester).snapshot.items.single.id)),
          );
          await _until(tester, () => _wall(tester).snapshot.items.length == 2);
        }

        Future<void> openOptions() async {
          await tester.tap(find.byTooltip('相册选项'));
          await tester.pumpAndSettle();
        }

        Future<Map<String, dynamic>> savedSettings() async =>
            (await tester.runAsync(() async {
              final file = File(
                albumSettingsPath(model.documents.path, 'local', child),
              );
              return jsonDecode(await file.readAsString())
                  as Map<String, dynamic>;
            }))!;

        try {
          await tester.pumpWidget(_view(model, folder));
          var cover = await parentCover();
          expect((await readCover(cover)).sourcePath, '$child/a.jpg');
          await enterChild();
          final photo = _wall(tester).snapshot.items
              .firstWhere((item) => item.preferred.path == '$child/b.jpg');
          var revision = cover.service.revision;
          await tester.longPress(find.byKey(ValueKey(photo.id)));
          await tester.pumpAndSettle();
          await tester.tap(find.text('设为相册封面'));
          await _until(tester, () => cover.service.revision > revision);
          await tester.tap(find.byType(BackButton));
          cover = await parentCover();
          expect((await readCover(cover)).sourcePath, '$child/b.jpg');

          await enterChild();
          revision = cover.service.revision;
          await openOptions();
          final hide = find.text('不显示相册封面');
          // Reach the action using the same directional/confirm keys as a TV
          // remote, without relying on a particular initial menu focus.
          for (
            var i = 0;
            i < 8 && !Focus.of(tester.element(hide)).hasFocus;
            i++
          ) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
          }
          expect(Focus.of(tester.element(hide)).hasFocus, isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await _until(tester, () => cover.service.revision > revision);
          final hiddenSettings = await savedSettings();
          expect(hiddenSettings['hideCover'], isTrue);
          expect(hiddenSettings.containsKey('cover'), isFalse);
          await tester.tap(find.byType(BackButton));
          cover = await parentCover();
          final hidden = await readCover(cover);
          expect(hidden.path, isNull);
          expect(hidden.sourcePath, isNull);
          expect(hidden.singleVideo, isNull);
          expect(hidden.error, isNull);
          expect(find.byIcon(Icons.folder_outlined), findsOneWidget);

          await tester.pumpWidget(const SizedBox());
          await _until(
            tester,
            () =>
                AlbumPage.pendingDisposals == 0 &&
                ArtworkDecodeQueue.instance.activeCount == 0 &&
                ArtworkDecodeQueue.instance.pendingCount == 0,
          );
          await tester.pumpWidget(_view(model, folder));
          cover = await parentCover();
          expect((await readCover(cover)).path, isNull);
          await enterChild();
          revision = cover.service.revision;
          await openOptions();
          expect(find.text('不显示相册封面'), findsNothing);
          expect(find.text('恢复自动封面'), findsOneWidget);
          if (restore == 'automatic') {
            await tester.tap(find.text('恢复自动封面'));
          } else {
            await tester.tap(find.text('选择相册封面'));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(ValueKey(photo.id)));
          }
          await _until(tester, () => cover.service.revision > revision);
          await tester.tap(find.byType(BackButton));
          cover = await parentCover();
          expect(
            (await readCover(cover)).sourcePath,
            '$child/${restore == 'automatic' ? 'a' : 'b'}.jpg',
          );
          final restoredSettings = await savedSettings();
          expect(restoredSettings['hideCover'], isNot(true));
          expect(restoredSettings.containsKey('cover'), restore == 'chosen');
          await tester.runAsync(() async {
            expect(await File('$child/a.jpg').exists(), isTrue);
            expect(await File('$child/b.jpg').exists(), isTrue);
          });
        } finally {
          await _close(tester, root, [(model, store)]);
        }
      },
    );
  }

  testWidgets(
    'loaded album pauses immediately without a further frame and resumes its images',
    (tester) async {
      final root = await _fixture(tester);
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      final folder = '${root.path}/photos';
      try {
        await tester.pumpWidget(_view(model, folder));
        await _until(
          tester,
          () => find.byType(AlbumThumbnail).evaluate().length == 2,
        );
        final service = tester
            .widget<AlbumThumbnail>(find.byType(AlbumThumbnail).first)
            .service;
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(service.active, isFalse);
        // Cancellation closes admission immediately, but the worker still has
        // to finish its current I/O and acknowledge it. Wait for that state
        // without pumping a frame or assuming a runner's completion speed.
        await tester.runAsync(() async {
          final wait = Stopwatch()..start();
          while (service.activeCount > 0 &&
              wait.elapsed < const Duration(seconds: 10)) {
            await Future<void>.delayed(const Duration(milliseconds: 15));
          }
        });
        expect(service.activeCount, 0);
        final pausedCount = service.pendingCount;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        expect(service.pendingCount, pausedCount);
        expect(_wall(tester).snapshot.items.length, 2);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _until(tester, () => service.active && service.pendingCount == 0);
        expect(_wall(tester).snapshot.items.length, 2);
      } finally {
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  testWidgets(
    'model replacement closes the old queue and rejects its late metadata callback',
    (tester) async {
      final root = await _fixture(tester);
      final folder = '${root.path}/photos';
      final storeA = AppStore(':memory:'), storeB = AppStore(':memory:');
      final modelA = AppModel(
        storeA,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      final modelB = AppModel(
        storeB,
        Directory('${root.path}/model-b'),
        backgroundWork: false,
      );
      await tester.runAsync(() async {
        final prefs = File(
          albumSettingsPath(modelB.documents.path, 'local', folder),
        );
        await prefs.parent.create(recursive: true);
        await prefs.writeAsString(
          jsonEncode({
            'sortSelected': true,
            'options': AlbumOptions(
              sortField: 'captured',
              descending: true,
            ).toJson(),
          }),
        );
      });
      try {
        await tester.pumpWidget(_view(modelA, folder));
        await _until(
          tester,
          () => find.byType(AlbumThumbnail).evaluate().length == 2,
        );
        final old = tester.widget<AlbumThumbnail>(
          find.byType(AlbumThumbnail).first,
        );
        await tester.pumpWidget(_view(modelB, folder));
        await _until(
          tester,
          () =>
              find.byType(AlbumThumbnail).evaluate().length == 2 &&
              tester
                      .widget<AlbumThumbnail>(find.byType(AlbumThumbnail).first)
                      .service !=
                  old.service,
        );
        expect(old.service.active, isFalse);
        final service = tester
            .widget<AlbumThumbnail>(find.byType(AlbumThumbnail).first)
            .service;
        await _until(tester, () => service.pendingCount == 0);
        // Replay the delayed callback boundary from the replaced model using the
        // same physical filename, so a missing generation guard changes sorting.
        old.onLoaded!(
          AlbumImageResult(
            sourcePath: old.entry.path,
            metadata: AlbumFileMetadata(
              capturedAt: DateTime(2099).millisecondsSinceEpoch,
              width: 40,
              height: 30,
            ),
          ),
        );
        await tester.tap(find.byTooltip('排序'));
        await tester.pumpAndSettle();
        final previousSnapshot = _wall(tester).snapshot;
        await tester.tap(find.text('应用'));
        await tester.pumpAndSettle();
        await _until(
          tester,
          () => !identical(_wall(tester).snapshot, previousSnapshot),
        );
        expect(_wall(tester).snapshot.items.first.preferred.name, 'b.jpg');
        expect((await old.service.load(old.entry).future).cancelled, isTrue);
      } finally {
        await _close(tester, root, [(modelA, storeA), (modelB, storeB)]);
      }
    },
  );

  testWidgets(
    'default name order stays quiet and leaves offscreen EXIF unread',
    (tester) async {
      final root = await _fixture(tester);
      final folder = '${root.path}/photos';
      final entries = <SourceEntry>[];
      await tester.runAsync(() async {
        final bytes = await File('$folder/a.jpg').readAsBytes();
        for (var i = 0; i < 160; i++) {
          final name = 'shot${i.toString().padLeft(3, '0')}.jpg';
          final path = '$folder/$name';
          await File(path).writeAsBytes(bytes);
          entries.add(
            SourceEntry(
              name: name,
              path: path,
              size: bytes.length,
              modified: 1,
            ),
          );
        }
      });
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: AlbumPage(
              model: model,
              source: const {'id': 'local', 'kind': 'local'},
              initialPath: folder,
              initialEntries: entries,
              initialSettings: const {},
            ),
          ),
        );
        await _until(
          tester,
          () => find.byType(AlbumThumbnail).evaluate().isNotEmpty,
        );
        final thumbnail = tester.widget<AlbumThumbnail>(
          find.byType(AlbumThumbnail).first,
        );
        final service = thumbnail.service;
        final snapshot = _wall(tester).snapshot;
        await _until(
          tester,
          () =>
              service.pendingCount == 0 &&
              service.activeCount == 0 &&
              ArtworkDecodeQueue.instance.activeCount == 0 &&
              ArtworkDecodeQueue.instance.pendingCount == 0 &&
              !tester.binding.hasScheduledFrame &&
              service.peek(thumbnail.entry)?.path != null,
          timeout: const Duration(seconds: 10),
        );
        var updates = 0;
        void changed() => updates++;
        service.addListener(changed);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        expect(updates, 0);
        expect(service.pendingCount, 0);
        expect(service.activeCount, 0);
        expect(identical(_wall(tester).snapshot, snapshot), isTrue);
        expect(
          _wall(tester).snapshot.items.map((item) => item.preferred.name),
          entries.map((entry) => entry.name),
        );
        service.removeListener(changed);
        var completedSynchronously = false;
        final offscreen = service.loadMetadata(entries.last);
        unawaited(offscreen.future.then((_) => completedSynchronously = true));
        expect(
          completedSynchronously,
          isFalse,
          reason:
              'An offscreen file must not already be in the EXIF pass cache',
        );
        offscreen.cancel();
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  testWidgets(
    'viewer swipe and pop preserve the exact wall offset and original focused identity',
    (tester) async {
      final root = await _fixture(tester);
      final store = AppStore(':memory:');
      final model = AppModel(
        store,
        Directory('${root.path}/model-a'),
        backgroundWork: false,
      );
      await tester.runAsync(() async {
        final bytes = await File('${root.path}/photos/a.jpg').readAsBytes();
        for (var index = 0; index < 48; index++) {
          await File(
            '${root.path}/photos/${index.toString().padLeft(3, '0')}.jpg',
          ).writeAsBytes(bytes);
        }
      });
      await tester.runAsync(() async {
        final preferences = File(
          albumSettingsPath(
            model.documents.path,
            'local',
            '${root.path}/photos',
          ),
        );
        await preferences.parent.create(recursive: true);
        await preferences.writeAsString(
          jsonEncode({
            'sortSelected': true,
            'options': AlbumOptions(
              sortField: 'captured',
              descending: true,
            ).toJson(),
          }),
        );
      });
      try {
        await tester.pumpWidget(_view(model, '${root.path}/photos'));
        await _until(
          tester,
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              _wall(tester).snapshot.items.length == 50,
        );
        await _until(
          tester,
          () =>
              _wall(tester).snapshot.items
                  .every((item) => item.capturedAt != null),
        );
        await tester.pumpAndSettle();
        final snapshot = _wall(tester).snapshot;
        final scroll = _wall(tester).controller;
        const offset = 347.25;
        scroll.jumpTo(offset);
        await tester.pumpAndSettle();
        final beforeMetadata = _wall(tester).snapshot;
        final thumbnail = tester.widget<AlbumThumbnail>(
          find.byType(AlbumThumbnail).first,
        );
        final currentItem = beforeMetadata
            .items[beforeMetadata.indexByPath[thumbnail.entry.path]!];
        thumbnail.onLoaded!(
          AlbumImageResult(
            sourcePath: thumbnail.entry.path,
            metadata: AlbumFileMetadata(
              capturedAt: currentItem.capturedAt,
              width: 41,
              height: 30,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await _until(
          tester,
          () => !identical(_wall(tester).snapshot, beforeMetadata),
        );
        expect(scroll.offset, closeTo(offset, .01));
        final original = snapshot.items[9];
        final cell = find.byKey(ValueKey(original.id));
        tester
            .widget<InkWell>(
              find.descendant(of: cell, matching: find.byType(InkWell)),
            )
            .focusNode!
            .requestFocus();
        await tester.pump();
        expect(scroll.offset, offset);
        final wallElement = tester.element(find.byType(AlbumWall));
        final returningSnapshot = _wall(tester).snapshot;
        final wallImage = find.descendant(
          of: cell,
          matching: find.byType(RawImage),
        );
        await _until(
          tester,
          () => tester
              .widgetList<RawImage>(wallImage)
              .any((raw) => raw.image != null),
        );
        final heldFrame = tester.widget<RawImage>(wallImage).image!.clone();
        addTearDown(heldFrame.dispose);
        final heldElement = tester.element(
          find.descendant(of: cell, matching: find.byType(Image)),
        );
        await tester.tap(cell);
        await _until(
          tester,
          () => find.byType(AlbumViewer).evaluate().isNotEmpty,
        );
        await _until(
          tester,
          () => tester
              .widgetList<RawImage>(
                find.descendant(
                  of: find.byWidgetPredicate(
                    (widget) =>
                        widget is AlbumThumbnail &&
                        widget.entry.path == original.preferred.path,
                  ),
                  matching: find.byType(RawImage),
                ),
              )
              .any((image) => image.image != null),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('album-photo-canvas')),
          const Offset(-240, 0),
        );
        await tester.pump();
        await _until(
          tester,
          () => tester
              .widgetList<RawImage>(
                find.descendant(
                  of: find.byWidgetPredicate(
                    (widget) =>
                        widget is AlbumThumbnail &&
                        widget.entry.path == snapshot.items[10].preferred.path,
                  ),
                  matching: find.byType(RawImage),
                ),
              )
              .any((image) => image.image != null),
        );
        await tester.pumpAndSettle();
        expect(find.text(snapshot.items[10].preferred.name), findsOneWidget);
        final viewerImages = tester
            .widget<AlbumThumbnail>(
              find
                  .descendant(
                    of: find.byType(AlbumViewer),
                    matching: find.byType(AlbumThumbnail),
                  )
                  .first,
            )
            .service;
        final wallRevision = thumbnail.service.revision;
        final viewerRevision = viewerImages.revision;
        await tester.runAsync(
          () => model.updatePreferences({
            'albumThumbnailCacheMiB': 768,
            'albumOriginalCacheMiB': 2048,
            'albumMetadataCacheMiB': 32,
          }),
        );
        await tester.pump();
        for (final service in [thumbnail.service, viewerImages]) {
          expect(service.maxThumbnailBytes, 768 * 1024 * 1024);
          expect(service.maxCacheBytes, 2048 * 1024 * 1024);
          expect(service.maxMetadataBytes, 32 * 1024 * 1024);
        }
        expect(thumbnail.service.revision, wallRevision);
        expect(viewerImages.revision, viewerRevision);
        final viewerRoute = ModalRoute.of(
          tester.element(find.byType(AlbumViewer)),
        )!;
        await tester.tap(find.byType(BackButton));
        await _until(
          tester,
          () => viewerRoute.animation!.status == AnimationStatus.reverse,
        );
        expect(thumbnail.service.active, isFalse);
        expect(TickerMode.valuesOf(wallElement).enabled, isFalse);
        await tester.pump(const Duration(milliseconds: 100));
        expect(thumbnail.service.active, isFalse);
        expect(TickerMode.valuesOf(wallElement).enabled, isFalse);
        await _until(tester, () => find.byType(AlbumViewer).evaluate().isEmpty);
        await tester.pumpAndSettle();
        await tester.pump();
        final button = tester.widget<InkWell>(
          find.descendant(of: cell, matching: find.byType(InkWell)),
        );
        expect(scroll.offset, closeTo(offset, .01));
        expect(thumbnail.service.active, isTrue);
        expect(tester.element(find.byType(AlbumWall)), same(wallElement));
        expect(_wall(tester).snapshot, same(returningSnapshot));
        expect(
          tester.element(
            find.descendant(of: cell, matching: find.byType(Image)),
          ),
          same(heldElement),
        );
        expect(
          tester.widget<RawImage>(wallImage).image!.isCloneOf(heldFrame),
          isTrue,
        );
        expect((scroll as AlbumScrollController).restoring, isFalse);
        expect(button.focusNode!.hasFocus, isTrue);
        final grid = tester.widget<GridView>(
          find.byKey(const ValueKey('album-wall')),
        );
        expect(
          grid.childrenDelegate.estimatedChildCount,
          _wall(tester).snapshot.wallSections.childCount,
        );
      } finally {
        await _close(tester, root, [(model, store)]);
      }
    },
  );

  testWidgets(
    'quick background and resume during preparation never opens a late player',
    (tester) async {
      final root = await _fixture(tester);
      await tester.runAsync(
        () => File('${root.path}/photos/movie.mp4').writeAsBytes([0, 1, 2]),
      );
      final store = AppStore(':memory:');
      final model = _DelayedPlaybackModel(
        store,
        Directory('${root.path}/model-a'),
      );
      try {
        await tester.pumpWidget(_view(model, '${root.path}/photos'));
        await _until(
          tester,
          () =>
              find.byType(AlbumWall).evaluate().isNotEmpty &&
              _wall(tester).snapshot.items.length == 3,
        );
        final item = _wall(tester).snapshot.items
            .singleWhere((item) => item.isVideo);
        await tester.tap(find.byKey(ValueKey(item.id)));
        await _until(
          tester,
          () => find.byType(AlbumViewer).evaluate().isNotEmpty,
        );
        // Video playback now has an inline transport. This scenario exercises
        // the separate full-player route and its cancelled preparation.
        final play = find.byKey(const ValueKey('album-open-full-player'));
        await _until(tester, () => play.hitTestable().evaluate().isNotEmpty);
        expect(model.started.isCompleted, isFalse);
        await tester.tap(play);
        await _until(tester, () => model.started.isCompleted);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        model.release.complete();
        await _until(tester, () => model.finished.isCompleted);
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.byType(PlayerPage), findsNothing);
        expect(find.byType(AlbumViewer), findsOneWidget);
        expect(find.byType(AlbumWall, skipOffstage: false), findsOneWidget);
      } finally {
        if (!model.release.isCompleted) model.release.complete();
        await _close(tester, root, [(model, store)]);
      }
    },
  );
}
