import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_preview_persistence.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/source_preview.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_video_thumbnail.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

typedef _Fixture = ({
  String root,
  String media,
  List<SourceEntry> entries,
  Uint8List frame,
});

Future<_Fixture> _fixture(bool folders) => Isolate.run(() async {
  final root = Directory.systemTemp.createTempSync('album-video-scroll-');
  final media = Directory('${root.path}/media')..createSync();
  final entries = <SourceEntry>[];
  final modified = DateTime.utc(2026, 11, 1);
  for (var index = 0; index < 120; index++) {
    final name = index.toString().padLeft(3, '0');
    final directory = folders
        ? (Directory('${media.path}/$name')..createSync()).path
        : media.path;
    final file = File('$directory/$name.mp4')
      ..writeAsBytesSync(Uint8List(32))
      ..setLastModifiedSync(modified);
    final stat = folders ? Directory(directory).statSync() : file.statSync();
    entries.add(
      SourceEntry(
        name: folders ? name : '$name.mp4',
        path: folders ? directory : file.path,
        directory: folders,
        size: folders ? 0 : stat.size,
        modified: stat.modified.millisecondsSinceEpoch,
      ),
    );
  }
  final pixels = raster.Image(width: 320, height: 180);
  raster.fill(pixels, color: raster.ColorRgb8(50, 120, 190));
  final frame = Uint8List.fromList(raster.encodeJpg(pixels));
  final store = AppStore('${root.path}/library.db');
  store.setLocal('settings', {
    'autoIdentifyOnFolderOpen': false,
    'autoDiscover': false,
  });
  store.dispose();
  return (root: root.path, media: media.path, entries: entries, frame: frame);
});

Future<void> _removePreview(String database, String id) => Isolate.run(() {
  final store = AppStore.openExisting(database);
  try {
    store.removeLocal('preview:$id');
  } finally {
    store.dispose();
  }
});

class _CaptureControl {
  final Uint8List frame;
  final tokens = <CancelToken>[];
  bool block = false;
  _CaptureControl(this.frame);
  Future<MediaPreview> capture(String uri, CancelToken token) async {
    tokens.add(token);
    if (block) {
      await token.whenCancelled;
      throw const Cancelled();
    }
    token.check();
    return MediaPreview(frame, 60, 320, 180, capturedPosition: 0);
  }
}

class _HeldBindingModel extends AppModel {
  Completer<void>? bindingGate;
  int reads = 0;
  _HeldBindingModel(super.store, super.documents, _CaptureControl capture)
    : super(
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: capture.capture,
      );

  @override
  Future<SourcePreviewBinding> readSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    required CancelToken cancel,
    bool albumCover = false,
    bool originalResolution = false,
  }) async {
    reads++;
    final gate = bindingGate;
    if (gate != null) {
      await Future.any([
        gate.future,
        cancel.whenCancelled.then<void>((_) => throw const Cancelled()),
      ]);
    }
    cancel.check();
    return super.readSourceMediaPreview(
      sourceId,
      entry,
      cancel: cancel,
      albumCover: albumCover,
      originalResolution: originalResolution,
    );
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String label,
) async {
  for (var attempt = 0; attempt < 500 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: label);
}

Finder _video(String path) => find.byWidgetPredicate(
  (widget) => widget is AlbumVideoThumbnail && widget.entry.path == path,
);

ui.Image? _pixels(WidgetTester tester, Finder video) {
  final images = find.descendant(of: video, matching: find.byType(RawImage));
  return images.evaluate().isEmpty
      ? null
      : tester.widget<RawImage>(images.first).image;
}

Map<String, ui.Image?> _visible(WidgetTester tester) {
  final wall = find.byType(AlbumWall);
  if (wall.evaluate().isEmpty) return {};
  final viewport = tester
      .getRect(wall)
      .intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  final result = <String, ui.Image?>{};
  for (final item in tester.widget<AlbumWall>(wall).snapshot.items) {
    final cell = find.byKey(ValueKey(item.id));
    if (cell.evaluate().isEmpty || !tester.getRect(cell).overlaps(viewport)) {
      continue;
    }
    final entry = item.preferred;
    // Folder fixtures contain one video whose stem matches the folder name.
    // Count cells still resolving their folder cover as missing, too.
    final path = entry.directory
        ? '${entry.path}/${entry.name}.mp4'
        : entry.path;
    final finder = _video(path);
    result[path] = finder.evaluate().isEmpty ? null : _pixels(tester, finder);
  }
  return result;
}

void main() {
  for (final folders in [false, true]) {
    testWidgets(
      '${folders ? 'single-video folders' : 'album videos'} reuse the first recycled frame before binding reads finish',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.binding.setSurfaceSize(const Size(480, 640));
        final fixture = (await tester.runAsync(() => _fixture(folders)))!;
        final store = AppStore.openExisting('${fixture.root}/library.db');
        final capture = _CaptureControl(fixture.frame);
        final model = _HeldBindingModel(
          store,
          Directory(fixture.root),
          capture,
        );
        final originals = <String, ui.Image>{};
        Completer<void>? gate;
        Future<void> ready(String label) => _until(tester, () {
          final current = _visible(tester);
          return current.isNotEmpty &&
              current.values.every((image) => image != null) &&
              ArtworkDecodeQueue.instance.activeCount == 0 &&
              ArtworkDecodeQueue.instance.pendingCount == 0;
        }, label);
        try {
          // Start the worker on the real event loop so disposal can join it even
          // after the widget binding stops producing frames.
          final preflight = folders
              ? SourceEntry(
                  name: '000.mp4',
                  path: '${fixture.media}/000/000.mp4',
                  size: 32,
                )
              : fixture.entries.first;
          await tester.runAsync(
            () => model.readSourceMediaPreview(
              'local',
              preflight,
              cancel: CancelToken(),
              albumCover: true,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: AlbumPage(
                model: model,
                source: const {'id': 'local', 'kind': 'local'},
                initialPath: fixture.media,
                initialEntries: fixture.entries,
                initialSettings: const {
                  'sortSelected': true,
                  'options': {'sortField': 'name', 'descending': false},
                },
              ),
            ),
          );
          await ready('first viewport images ready');
          final first = _visible(tester);
          for (final entry in first.entries) {
            originals[entry.key] = entry.value!.clone();
          }
          final path = originals.keys.first;
          final firstElement = tester.element(_video(path));
          final wall = tester.widget<AlbumWall>(find.byType(AlbumWall));
          final controller = wall.controller;
          final away = controller.position.viewportDimension * 2.2;
          controller.jumpTo(away);
          await tester.pump();
          await ready('second viewport images ready');
          expect(
            _video(path),
            findsNothing,
            reason: 'The original sliver cell must actually be disposed.',
          );
          final beforeReturn = capture.tokens.length;
          model.bindingGate = gate = Completer<void>();
          final beforeReads = model.reads;
          controller.jumpTo(0);
          await tester.pump();
          final returned = _visible(tester);
          expect(returned.keys, unorderedEquals(originals.keys));
          expect(tester.element(_video(path)), isNot(same(firstElement)));
          for (final image in returned.entries) {
            expect(
              image.value,
              isNotNull,
              reason:
                  'The first returning frame for ${image.key} must not wait for the binding worker.',
            );
            expect(image.value!.isCloneOf(originals[image.key]!), isTrue);
          }
          // The first-frame assertion above happens during the shared scroll
          // busy period. Let it settle while validation stays blocked.
          await tester.pump(const Duration(milliseconds: 150));
          expect(model.reads, greaterThan(beforeReads));
          expect(gate.isCompleted, isFalse);
          expect(capture.tokens.length, beforeReturn);

          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          final pausedReads = model.reads;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)),
          );
          // No pump after paused: binding cancellation and queue admission do not
          // depend on a new Android frame. A late gate release cannot restart it.
          expect(model.reads, pausedReads);
          expect(capture.tokens.length, beforeReturn);
          gate.complete();
          model.bindingGate = null;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          expect(model.reads, pausedReads);
          expect(capture.tokens.length, beforeReturn);
          expect(ArtworkDecodeQueue.instance.pendingCount, 0);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await ready('resumed warm viewport');
          await _until(
            tester,
            () => model.reads > pausedReads,
            'binding validation resumes',
          );
          expect(capture.tokens.length, beforeReturn);

          // A worker-confirmed missing binding must revoke the optimistic path,
          // including the page cache, while a replacement capture is held.
          capture.block = true;
          await tester.runAsync(
            () =>
                _removePreview(store.path, albumVideoPreviewId('local', path)),
          );
          model.changed();
          await _until(tester, () {
            final artwork = find.descendant(
              of: _video(path),
              matching: find.byType(MediaArtwork),
            );
            return artwork.evaluate().isNotEmpty &&
                tester.widget<MediaArtwork>(artwork).thumbnail == null;
          }, 'missing binding revokes the displayed seed');
          controller.jumpTo(away);
          await tester.pump();
          model.bindingGate = gate = Completer<void>();
          controller.jumpTo(0);
          await tester.pump();
          expect(
            tester.widget<AlbumVideoThumbnail>(_video(path)).initialThumbnail,
            isNull,
          );
          expect(_pixels(tester, _video(path)), isNull);
          expect(tester.takeException(), isNull);
        } finally {
          if (gate != null && !gate.isCompleted) gate.complete();
          model.bindingGate = null;
          await tester.pumpWidget(const SizedBox());
          await _until(
            tester,
            () =>
                AlbumPage.pendingDisposals == 0 &&
                ArtworkDecodeQueue.instance.activeCount == 0 &&
                ArtworkDecodeQueue.instance.pendingCount == 0,
            'album workers and native decodes released',
          );
          for (final image in originals.values) {
            image.dispose();
          }
          await tester.runAsync(() async {
            model.dispose();
            await model.flushMetadataTasks();
            store.dispose();
            await Directory(fixture.root).delete(recursive: true);
          });
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.binding.setSurfaceSize(null);
          await tester.pump();
        }
      },
    );
  }
}
