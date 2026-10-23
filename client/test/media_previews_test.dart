import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _Local extends LocalSource {
  int closes = 0;
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: 'video.mkv', path: path, size: 3);
  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  testWidgets(
    'foreground resume covers update immediately and reject a frame from an older progress',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = Directory.systemTemp.createTempSync('aiplayer-frame-');
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = AppModel(store, root);
      final id = model.addMedia(
        'local',
        const SourceEntry(name: 'video.mp4', path: '/video.mp4', size: 12),
      );
      final record = store.get('media', id)!;
      final key = model.progressKey(record);
      try {
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.drawRect(
            const ui.Rect.fromLTWH(0, 0, 100, 50),
            ui.Paint()..color = const ui.Color(0xff2196f3),
          );
          canvas.drawRect(
            const ui.Rect.fromLTWH(20, 10, 60, 30),
            ui.Paint()..color = const ui.Color(0xffcde5ff),
          );
          final picture = recorder.endRecording();
          final frame = await picture.toImage(100, 50);
          final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
          final data = bytes!.buffer.asUint8List();
          frame.dispose();
          picture.dispose();
          store.save('progress', key, {'position': 12, 'duration': 120});
          await model.savePlaybackPreview(id, data, position: 12);
          final first = model.thumbnailPath(id);
          expect(first, isNotNull);
          expect(File(first!).existsSync(), isTrue);
          store.save('progress', key, {'position': 48, 'duration': 120});
          await model.savePlaybackPreview(id, data, position: 48);
          final second = model.thumbnailPath(id);
          expect(second, isNot(first));
          expect(File(first).existsSync(), isFalse);
          final stale = model.savePlaybackPreview(id, data, position: 48);
          store.save('progress', key, {'position': 90, 'duration': 120});
          await stale;
          expect(model.thumbnailPath(id), second);
          await model.savePlaybackPreview(id, data, position: 48);
          expect(model.thumbnailPath(id), second);
        });
      } finally {
        model.dispose();
        store.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  test(
    'resume preview takes priority over a full pending library queue',
    () async {
      final root = await Directory.systemTemp.createTemp('aiplayer-priority-');
      final first = Completer<String>();
      final queue = MediaPreviewQueue(
        directory: root,
        openSource: (_) async => _Local(),
        isCurrent: (_) => true,
        onReady: (request, _, _) {
          if (!first.isCompleted) first.complete(request.id);
        },
        onError: (error) => fail('$error'),
        capture: (_, _) async => MediaPreview(Uint8List.fromList([1]), 1, 1, 1),
      );
      await queue.pause();
      for (var i = 0; i < 64; i++) {
        queue.schedule(MediaPreviewRequest('$i', 'local', '/$i.mp4', 12));
      }
      expect(
        queue.schedule(
          const MediaPreviewRequest(
            'latest',
            'local',
            '/latest.mp4',
            12,
            position: 30,
          ),
          priority: true,
        ),
        isTrue,
      );
      queue.resume();
      expect(await first.future, 'latest');
      await queue.close();
      await root.delete(recursive: true);
    },
  );

  testWidgets(
    'native cover encoding preserves portrait and landscape aspect without upscaling',
    (tester) async {
      await tester.runAsync(() async {
        for (final size in [
          (1200, 600, 480, 240),
          (600, 1200, 240, 480),
          (100, 50, 100, 50),
        ]) {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.drawRect(
            ui.Rect.fromLTWH(0, 0, size.$1.toDouble(), size.$2.toDouble()),
            ui.Paint()..color = const ui.Color(0xff42a5f5),
          );
          final picture = recorder.endRecording();
          final source = await picture.toImage(size.$1, size.$2);
          picture.dispose();
          final input = await source.toByteData(format: ui.ImageByteFormat.png);
          source.dispose();
          final output = await encodePreviewImage(
            input!.buffer.asUint8List(input.offsetInBytes, input.lengthInBytes),
          );
          expect(output.take(2), [255, 216]);
          final codec = await ui.instantiateImageCodec(output);
          final image = (await codec.getNextFrame()).image;
          expect(image.width, size.$3);
          expect(image.height, size.$4);
          image.dispose();
          codec.dispose();
        }
      });
    },
  );

  testWidgets('playback skips a preview start that is still debounced', (
    tester,
  ) async {
    var opened = 0;
    final queue = MediaPreviewQueue(
      directory: Directory.systemTemp,
      openSource: (_) async {
        opened++;
        throw const AppFailure('preview request observed');
      },
      isCurrent: (_) => true,
      onReady: (_, _, _) {},
      onError: (_) {},
    );
    queue.schedule(
      const MediaPreviewRequest('one', 'local', '/video.mp4', 100),
    );
    var paused = false;
    unawaited(queue.pause().then((_) => paused = true));
    await tester.pump();
    expect(
      paused,
      true,
      reason: 'opening a video must not wait 120ms for idle work',
    );
    expect(opened, 0);
    queue.resume();
    await tester.pump(const Duration(milliseconds: 119));
    expect(opened, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(opened, 1);
    await queue.close();
  });

  test(
    'queue bounds pending work, deduplicates, and closes without starting paused work',
    () async {
      final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
      var captures = 0;
      final queue = MediaPreviewQueue(
        directory: root,
        openSource: (_) async => _Local(),
        isCurrent: (_) => true,
        onReady: (_, _, _) {},
        onError: (_) {},
        capture: (_, _) async {
          captures++;
          return MediaPreview(Uint8List.fromList([1]), 1, 1, 1);
        },
      );
      await queue.pause();
      for (var i = 0; i < 64; i++) {
        expect(
          queue.schedule(MediaPreviewRequest('$i', 'local', '/$i.mkv', 3)),
          true,
        );
      }
      expect(
        queue.schedule(const MediaPreviewRequest('0', 'local', '/0.mkv', 3)),
        false,
      );
      expect(
        queue.schedule(
          const MediaPreviewRequest('0', 'local', '/replacement.mkv', 3),
        ),
        true,
        reason:
            'Replacing one pending ID must work even when all slots are occupied.',
      );
      expect(
        queue.schedule(
          const MediaPreviewRequest('extra', 'local', '/extra.mkv', 3),
        ),
        false,
      );
      await queue.close();
      expect(captures, 0);
      await root.delete(recursive: true);
    },
  );

  test(
    'playback cancellation releases resources and resumes one job only',
    () async {
      final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
      final started = Completer<void>(), finished = Completer<void>();
      final sources = <_Local>[];
      var calls = 0, active = 0, maxActive = 0;
      final queue = MediaPreviewQueue(
        directory: root,
        openSource: (_) async {
          final source = _Local();
          sources.add(source);
          return source;
        },
        isCurrent: (_) => true,
        onReady: (_, path, preview) {
          expect(File(path).readAsBytesSync(), [1, 2, 3]);
          expect(preview.duration, 20);
          finished.complete();
        },
        onError: (error) => fail('$error'),
        capture: (_, cancel) async {
          active++;
          if (active > maxActive) maxActive = active;
          try {
            if (++calls == 1) {
              started.complete();
              await cancel.whenCancelled;
              cancel.check();
            }
            return MediaPreview(Uint8List.fromList([1, 2, 3]), 20, 480, 270);
          } finally {
            active--;
          }
        },
      );
      queue.schedule(
        const MediaPreviewRequest('one', 'local', '/video.mkv', 3),
      );
      await started.future.timeout(const Duration(seconds: 2));
      await queue.pause();
      expect(active, 0);
      expect(sources.single.closes, 1);
      queue.resume();
      await finished.future.timeout(const Duration(seconds: 2));
      await queue.close();
      expect(calls, 2);
      expect(maxActive, 1);
      expect(sources.every((source) => source.closes == 1), true);
      await root.delete(recursive: true);
    },
  );

  test(
    'cancelled slow connection closes late without blocking playback',
    () async {
      final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
      final connecting = Completer<SourceAdapter>(),
          started = Completer<void>();
      final source = _Local();
      final queue = MediaPreviewQueue(
        directory: root,
        openSource: (_) {
          started.complete();
          return connecting.future;
        },
        isCurrent: (_) => true,
        onReady: (_, _, _) => fail('cancelled work saved a cover'),
        onError: (error) => fail('$error'),
        capture: (_, _) async => throw const AppFailure('must not capture'),
      );
      queue.schedule(
        const MediaPreviewRequest('one', 'local', '/video.mkv', 3),
      );
      await started.future.timeout(const Duration(seconds: 2));
      await queue.pause().timeout(const Duration(seconds: 1));
      connecting.complete(source);
      await Future<void>.delayed(Duration.zero);
      expect(source.closes, 1);
      await queue.close();
      await root.delete(recursive: true);
    },
  );

  test('failed previews do not retry on every rebuild', () async {
    final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
    final failed = Completer<void>();
    var calls = 0;
    final queue = MediaPreviewQueue(
      directory: root,
      openSource: (_) async => _Local(),
      isCurrent: (_) => true,
      onReady: (_, _, _) => fail('failed capture saved a cover'),
      onError: (_) => failed.complete(),
      capture: (_, _) async {
        calls++;
        throw const AppFailure('unreadable');
      },
    );
    const request = MediaPreviewRequest('one', 'local', '/video.mkv', 3);
    queue.schedule(request);
    await failed.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 10; i++) {
      expect(queue.schedule(request), false);
    }
    expect(calls, 1);
    await queue.close();
    await root.delete(recursive: true);
  });

  test('a late capture cannot replace a re-associated video cover', () async {
    final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
    final started = Completer<void>();
    final captured = Completer<MediaPreview>();
    var current = true;
    final queue = MediaPreviewQueue(
      directory: root,
      openSource: (_) async => _Local(),
      isCurrent: (_) => current,
      onReady: (_, _, _) => fail('stale capture replaced the current cover'),
      onError: (error) => fail('$error'),
      capture: (_, _) {
        started.complete();
        return captured.future;
      },
    );
    queue.schedule(const MediaPreviewRequest('one', 'local', '/old.mkv', 3));
    await started.future.timeout(const Duration(seconds: 2));
    current = false;
    captured.complete(
      MediaPreview(Uint8List.fromList([1, 2, 3]), 30, 480, 270),
    );
    // Pause joins the worker and verifies it did not publish the old generation.
    await queue.pause();
    expect(await root.list().toList(), isEmpty);
    await queue.close();
    await root.delete(recursive: true);
  });

  test(
    're-association replaces an old pending generation before decoding',
    () async {
      final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
      const oldRequest = MediaPreviewRequest('one', 'local', '/old.mkv', 3);
      const replacement = MediaPreviewRequest('one', 'local', '/new.mkv', 4);
      var current = oldRequest;
      final captured = <String>[];
      final finished = Completer<void>();
      final queue = MediaPreviewQueue(
        directory: root,
        openSource: (_) async => _Local(),
        isCurrent: (request) => request.fingerprint == current.fingerprint,
        onReady: (request, _, _) {
          expect(request.fingerprint, replacement.fingerprint);
          finished.complete();
        },
        onError: (error) => fail('$error'),
        capture: (uri, _) async {
          captured.add(uri);
          return MediaPreview(Uint8List.fromList([1, 2, 3]), 30, 480, 270);
        },
      );
      await queue.pause();
      expect(queue.schedule(oldRequest), true);
      current = replacement;
      expect(queue.schedule(replacement), true);
      queue.resume();
      await finished.future.timeout(const Duration(seconds: 2));
      await queue.close();
      expect(captured, ['/new.mkv']);
      await root.delete(recursive: true);
    },
  );

  test(
    'credential changes can immediately retry the same active fingerprint',
    () async {
      final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
      final started = Completer<void>(), finished = Completer<void>();
      var attempts = 0;
      final queue = MediaPreviewQueue(
        directory: root,
        openSource: (_) async => _Local(),
        isCurrent: (_) => true,
        onReady: (_, _, _) => finished.complete(),
        onError: (error) =>
            fail('A cancelled old connection reported an error: $error'),
        capture: (_, cancel) async {
          if (++attempts == 1) {
            started.complete();
            await cancel.whenCancelled;
            // Transport teardown can throw its own error rather than Cancelled.
            throw const AppFailure('old connection was closed');
          }
          return MediaPreview(Uint8List.fromList([1, 2, 3]), 30, 480, 270);
        },
      );
      const request = MediaPreviewRequest('one', 'local', '/video.mkv', 3);
      queue.schedule(request);
      await started.future.timeout(const Duration(seconds: 2));
      queue.forget(request.id);
      expect(queue.schedule(request), true);
      await finished.future.timeout(const Duration(seconds: 2));
      await queue.close();
      expect(attempts, 2);
      await root.delete(recursive: true);
    },
  );

  test(
    'quick background and foreground transitions do not lose cancelled work',
    () async {
      final root = await Directory.systemTemp.createTemp('aiplayer-preview-');
      final started = Completer<void>(), finished = Completer<void>();
      var attempts = 0;
      final queue = MediaPreviewQueue(
        directory: root,
        openSource: (_) async => _Local(),
        isCurrent: (_) => true,
        onReady: (_, _, _) => finished.complete(),
        onError: (error) => fail('$error'),
        capture: (_, cancel) async {
          if (++attempts == 1) {
            started.complete();
            await cancel.whenCancelled;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            cancel.check();
          }
          return MediaPreview(Uint8List.fromList([1, 2, 3]), 30, 480, 270);
        },
      );
      queue.schedule(
        const MediaPreviewRequest('one', 'local', '/video.mkv', 3),
      );
      await started.future.timeout(const Duration(seconds: 2));
      final paused = queue.pause();
      queue.resume();
      await finished.future.timeout(const Duration(seconds: 2));
      await paused;
      await queue.close();
      expect(attempts, 2);
      await root.delete(recursive: true);
    },
  );
}
