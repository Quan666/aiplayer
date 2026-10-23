import 'dart:io';
import 'package:aiplayer/playback/seek_preview.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

/// Exercise the HTTP range bridge while keeping the media fixture local.
class _BridgedLocalSource extends SourceAdapter {
  final _local = LocalSource();
  int rangeReads = 0, bytesRead = 0;
  bool closed = false;

  @override
  Future<List<SourceEntry>> list(String path) => _local.list(path);

  @override
  Future<SourceEntry> stat(String path) => _local.stat(path);

  @override
  Stream<List<int>> read(String path, int start, int end) async* {
    rangeReads++;
    await for (final bytes in _local.read(path, start, end)) {
      bytesRead += bytes.length;
      yield bytes;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    await _local.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixture = '/tmp/aiplayer-media-fixture/Example S01E01.mkv';
  testWidgets(
    'seek preview keeps producing frames during continuous dragging',
    (tester) async {
      MediaKit.ensureInitialized();
      final foreground = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = foreground.platform as NativePlayer;
      await native.setProperty('aid', 'no');
      await native.setProperty('vid', 'auto');
      await foreground.open(Media(fixture), play: false);
      for (
        var i = 0;
        i < 80 && foreground.state.duration == Duration.zero;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await foreground.seek(const Duration(seconds: 2));
      for (
        var i = 0;
        i < 40 && foreground.state.position.inMilliseconds < 1500;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final errors = <Object>[];
      final preview = SeekPreviewController(
        openSource: () async => LocalSource(),
        path: fixture,
        onError: errors.add,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<SeekPreviewFrame?>(
            valueListenable: preview,
            builder: (_, frame, _) =>
                frame == null ? const SizedBox() : Image.memory(frame.bytes),
          ),
        ),
      );
      try {
        final framesDuringDrag = <Duration>[];
        SeekPreviewFrame? lastFrame;
        void recordFrame() {
          final frame = preview.value;
          if (frame != null && !identical(frame, lastFrame)) {
            lastFrame = frame;
            framesDuringDrag.add(frame.position);
          }
        }

        preview.addListener(recordFrame);
        // Keep moving for two seconds. Assert before draining the final target:
        // a decoder that only starts after the pointer stops must fail here.
        for (var step = 0; step < 40; step++) {
          preview.request(Duration(milliseconds: 2500 + step * 250));
          await tester.pump(const Duration(milliseconds: 50));
        }
        preview.removeListener(recordFrame);
        debugPrint('Frames during continuous drag: $framesDuringDrag');
        expect(
          framesDuringDrag.toSet().length,
          greaterThanOrEqualTo(2),
          reason: 'Frames must update before the pointer stops: $errors',
        );
        expect(find.byType(Image), findsOneWidget);
        for (
          var i = 0;
          i < 160 && preview.value?.position != const Duration(seconds: 12);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          preview.value?.position,
          const Duration(seconds: 12),
          reason: errors.join('; '),
        );
        expect(preview.value!.bytes.length, inInclusiveRange(1000, 200000));
        expect(foreground.state.position.inMilliseconds, closeTo(2000, 500));
        expect(foreground.state.playing, false);
        final artifacts = Directory('../artifacts')
          ..createSync(recursive: true);
        await File(
          '${artifacts.path}/seek_preview_12s.jpg',
        ).writeAsBytes(preview.value!.bytes);
        preview.end();
        expect(preview.value, isNull);
        await tester.pump(const Duration(milliseconds: 2200));
        preview.request(const Duration(seconds: 9));
        for (var i = 0; i < 140 && preview.value == null; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(preview.value?.position, const Duration(seconds: 9));
        preview.request(const Duration(seconds: 22));
        await preview.close();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await preview.close();
        await foreground.dispose();
      }
    },
  );

  testWidgets('seek preview decodes through the range bridge and closes it', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    final sources = <_BridgedLocalSource>[];
    final errors = <Object>[];
    final preview = SeekPreviewController(
      openSource: () async {
        final source = _BridgedLocalSource();
        sources.add(source);
        return source;
      },
      path: fixture,
      onError: errors.add,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<SeekPreviewFrame?>(
          valueListenable: preview,
          builder: (_, frame, _) =>
              frame == null ? const SizedBox() : Image.memory(frame.bytes),
        ),
      ),
    );
    try {
      preview.request(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 160));
      preview.request(const Duration(seconds: 18));
      preview.request(const Duration(seconds: 19));
      for (
        var i = 0;
        i < 160 && preview.value?.position != const Duration(seconds: 19);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        preview.value?.position,
        const Duration(seconds: 19),
        reason: errors.join('; '),
      );
      expect(preview.value!.bytes.length, inInclusiveRange(1000, 200000));
      expect(preview.status, SeekPreviewStatus.ready);
      expect(sources, hasLength(1));
      expect(sources.single.rangeReads, greaterThan(0));
      expect(sources.single.bytesRead, greaterThan(0));
      expect(sources.single.closed, false);
      debugPrint(
        'Range bridge preview: ${sources.single.rangeReads} reads, '
        '${sources.single.bytesRead} bytes, target ${preview.value!.position}',
      );

      preview.end();
      await tester.pump(const Duration(milliseconds: 2200));
      expect(sources.single.closed, true);
      preview.request(const Duration(seconds: 8));
      for (
        var i = 0;
        i < 140 && preview.value?.position != const Duration(seconds: 8);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        preview.value?.position,
        const Duration(seconds: 8),
        reason: errors.join('; '),
      );
      expect(sources, hasLength(2));
      expect(sources.last.rangeReads, greaterThan(0));
      preview.request(const Duration(seconds: 27));
      await tester.pump(const Duration(milliseconds: 120));
      await preview.close().timeout(const Duration(seconds: 3));
      expect(sources.every((source) => source.closed), true);
      expect(errors, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await preview.close();
    }
  });
}
