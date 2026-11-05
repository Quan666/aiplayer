import 'dart:io';

import 'package:aiplayer/data/media_preview_persistence.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/source_preview.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final original in [false, true]) {
    test(
      'old orientation cache stays visible until recaptured ($original)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'album-orientation-cache-',
        );
        final store = AppStore(':memory:');
        try {
          const entry = SourceEntry(
            name: 'portrait.mp4',
            path: '/portrait.mp4',
            size: 32,
            modified: 1,
          );
          final id = albumVideoPreviewId(
            'local',
            entry.path,
            originalResolution: original,
          );
          final request = MediaPreviewRequest(
            id,
            'local',
            entry.path,
            entry.size,
            revision: '1',
          );
          final oldPath = '${root.path}/old.jpg';
          await File(oldPath).writeAsBytes([1]);
          store.setLocal('browse:$id', {
            'source': 'local',
            'path': entry.path,
            'size': entry.size,
            'fileRevision': '1',
            'previewRevision': '1',
          });
          store.setLocal('preview:$id', {
            'path': oldPath,
            'fingerprint': 'old-orientation-fingerprint',
            'contentFingerprint': request.contentFingerprint,
            'firstFrame': true,
            'albumVersion': 2,
            'formatVersion': MediaPreview.formatVersion,
          });
          Future<SourcePreviewBinding> read() => readSourcePreviewBinding(
            store,
            'local',
            entry,
            MediaPreview.formatVersion,
            albumCover: true,
            originalResolution: original,
          );
          final old = await read();
          expect(old.thumbnail, oldPath);
          expect(old.needsCapture, isTrue);

          final newPath = '${root.path}/upright.jpg';
          await File(newPath).writeAsBytes([2]);
          expect(
            persistCapturedMediaPreview(store, {
              'id': id,
              'source': 'local',
              'sourcePath': entry.path,
              'size': entry.size,
              'revision': '1',
              'position': null,
              'previewPath': newPath,
              'firstFrame': true,
              'originalResolution': original,
              'formatVersion': MediaPreview.formatVersion,
              'duration': 5.0,
              'width': 1080,
              'height': 1920,
            })?.previousPath,
            oldPath,
          );
          final replacement = await read();
          expect(replacement.thumbnail, newPath);
          expect(replacement.needsCapture, isFalse);
          expect(
            store.local('preview:$id')['albumVersion'],
            albumPreviewVersion,
          );
          expect(
            store.local('preview:$id')['fingerprint'],
            request.fingerprint,
          );
        } finally {
          store.dispose();
          await root.delete(recursive: true);
        }
      },
    );
  }
}
