import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> _frame({bool blank = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 120, 80),
    ui.Paint()
      ..color = blank ? const ui.Color(0xff000000) : const ui.Color(0xff2875b1),
  );
  if (!blank) {
    canvas.drawRect(
      const ui.Rect.fromLTWH(30, 15, 55, 50),
      ui.Paint()..color = const ui.Color(0xfff6be44),
    );
  }
  final picture = recorder.endRecording();
  final frame = await picture.toImage(120, 80);
  try {
    final data = (await frame.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    frame.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets(
    'startup, imports and source changes wait for a visible preview request',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-lazy-art-');
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'})
        ..save('media', 'existing', {'title': 'Existing.mp4', 'size': 100})
        ..setLocal('location:existing', {
          'id': 'existing',
          'source': 'remote',
          'path': '/Existing.mp4',
          'size': 100,
        });
      final model = _LazyPreviewModel(store, root);
      try {
        await tester.pump(const Duration(seconds: 1));
        expect(model.opened, isEmpty);
        final added = model.addMedia(
          'remote',
          const SourceEntry(name: 'New.mp4', path: '/New.mp4', size: 200),
        );
        await model.saveSource({
          'id': 'remote',
          'kind': 'webdav',
          'url': 'https://video.example.com',
        }, 'password');
        await tester.pump(const Duration(seconds: 1));
        expect(model.opened, isEmpty);

        model.ensureMediaPreview('existing');
        await tester.pump(const Duration(milliseconds: 120));
        expect(model.opened, ['remote']);
        model.activePlaybackMediaId = 'existing';
        model.ensureMediaPreview(added);
        await tester.pump(const Duration(seconds: 1));
        expect(model.opened, hasLength(1));
        model.activePlaybackMediaId = null;
        model.ensureMediaPreview(added);
        await tester.pump(const Duration(milliseconds: 120));
        expect(model.opened, hasLength(2));
      } finally {
        model.dispose();
        await tester.pump();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'directory artwork refreshes to per-video progress, retaining good art across blank frames',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync(
        'aiplayer-progress-art-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = AppModel(store, root);
      const first = SourceEntry(
        name: 'Series S01E01.mkv',
        path: '/Series/01.mkv',
        size: 1024,
      );
      const second = SourceEntry(
        name: 'Series S01E02.mkv',
        path: '/Series/02.mkv',
        size: 2048,
      );
      try {
        await tester.runAsync(() async {
          // Browsing alone must not import a video or create playback history.
          final browsingId = model.ensureSourceMediaPreview('local', first);
          expect(browsingId, startsWith('browse-'));
          expect(model.media, isEmpty);
          final id = model.addMedia('local', first);
          final otherId = model.addMedia('local', second);
          expect(model.ensureSourceMediaPreview('local', first), id);
          expect(model.sourcePreviewId('local', second.path), otherId);
          final key = model.progressKey(store.get('media', id)!);
          final otherKey = model.progressKey(store.get('media', otherId)!);
          store.save('progress', key, {'position': 15, 'duration': 120});
          store.save('progress', otherKey, {'position': 65, 'duration': 120});
          final good = await _frame();
          await model.savePlaybackPreview(id, good, position: 15);
          await model.savePlaybackPreview(otherId, good, position: 65);
          final firstCover = model.thumbnailPath(id)!;
          final otherCover = model.thumbnailPath(otherId)!;
          expect(model.needsMediaPreview(id), false);
          store.save('progress', key, {'position': 49, 'duration': 120});
          // Browsing reuses the existing image while progress changes. Only
          // an explicit pause/close capture replaces a valid frame.
          expect(model.thumbnailPath(id), firstCover);
          expect(model.needsMediaPreview(id), false);
          expect(model.needsMediaPreview(otherId), false);
          await model.savePlaybackPreview(
            id,
            await _frame(blank: true),
            position: 49,
          );
          expect(model.thumbnailPath(id), firstCover);
          expect(File(firstCover).existsSync(), true);
          expect(model.needsMediaPreview(id), false);
          await model.savePlaybackPreview(id, good, position: 49);
          expect(model.thumbnailPath(id), isNot(firstCover));
          expect(model.needsMediaPreview(id), false);
          expect(model.thumbnailPath(otherId), otherCover);
          expect(store.get('progress', otherKey)!.data['position'], 65);
          // Missing cache files are recoverable even when their fingerprint is
          // current (e.g. OS cache cleanup).
          File(model.thumbnailPath(id)!).deleteSync();
          expect(model.needsMediaPreview(id), true);
        });
      } finally {
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );
}

class _LazyPreviewModel extends AppModel {
  final opened = <String>[];
  _LazyPreviewModel(super.store, super.documents)
    : super(backgroundWork: false, enableThumbnails: true);

  @override
  Future<SourceAdapter> adapter(String id) async {
    opened.add(id);
    throw const AppFailure('preview request observed');
  }
}
