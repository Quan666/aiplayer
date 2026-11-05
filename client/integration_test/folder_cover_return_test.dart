import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_preview_persistence.dart';
import 'package:aiplayer/data/source_preview.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:integration_test/integration_test.dart';

// From client/:
// dbus-run-session -- xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1
// ../.local-build/sdk/flutter/bin/flutter drive -d linux --profile --no-pub
// --driver=test_driver/artwork_performance_driver.dart
// --target=integration_test/folder_cover_return_test.dart
// --dart-define=FOLDER_COVER_RETURN_ARTIFACT_DIR=/absolute/artifact/path
// Actual SourceBrowser and native image decoding, with a controlled directory
// adapter and prepared screenshot binding. Measures UI reuse and desktop frame
// work, not NAS latency, native video capture, mobile frame rate or power use.
const _folder = SourceEntry(
  name: '000 Cover',
  path: '000 Cover',
  directory: true,
);
const _video = SourceEntry(
  name: 'clip-001.mp4',
  path: '000 Cover/clip-001.mp4',
  size: 1024,
  modified: 1,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('profile warm folder screenshot across three parent returns', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('folder-cover-return-');
    final entries = await _seedInBackground(root.path);
    final store = AppStore.openExisting('${root.path}/library.db');
    final model = _Model(store, root, entries);
    final rounds = <Map<String, Object?>>[];
    var observing = false;
    void Function(List<ui.FrameTiming>)? activeCollector;
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme(),
          home: Scaffold(
            body: GlassBackground(
              child: SourceBrowser(
                model: model,
                source: const {
                  'id': 'folder-profile',
                  'kind': 'webdav',
                  'label': 'Folder profile',
                },
              ),
            ),
          ),
        ),
      );
      final browser = find.byType(SourceBrowser).evaluate().single;
      await _waitFor(
        () => _rowState(browser, _folder.path)?.pixels == true,
        'initial folder screenshot',
      );
      await _waitFor(() => model.pendingBindings == 0, 'initial binding');
      final warmReads = model.previewReads;
      final expectedFrame = '${root.path}/frame.jpg';
      expect(_rowState(browser, _folder.path)?.thumbnail, expectedFrame);

      for (var round = 0; round < 3; round++) {
        await tester.tap(find.text(_folder.name).hitTestable().first);
        await tester.pump();
        await _waitFor(
          () => _rowState(browser, _video.path)?.pixels == true,
          'child video screenshot $round',
        );
        await _waitFor(
          () => model.pendingBindings == 0,
          'child binding $round',
        );
        expect(_rowState(browser, _folder.path), isNull);
        model.delayBindings = true;

        // Flush the engine's preceding timing batch before measuring return.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final timings = <ui.FrameTiming>[];
        final watch = Stopwatch()..start();
        final beforeReads = model.previewReads;
        final beforeListings = Map<String, int>.of(model.directoryReads);
        Map<String, Object?>? firstFrame;
        observing = true;
        void sample(Duration _) {
          if (!observing) return;
          final row = _rowState(browser, _folder.path);
          if (row != null && firstFrame == null) {
            firstFrame = {
              'elapsedMs': watch.elapsedMicroseconds / 1000,
              'thumbnail': row.thumbnail,
              'decodedPixels': row.pixels,
              'pendingBindings': model.pendingBindings,
              'previewReads': model.previewReads,
            };
          }
          if (firstFrame == null) {
            // Observe only frames the app schedules; this does not request an
            // extra frame or convert an idle page into a frame loop.
            WidgetsBinding.instance.addPostFrameCallback(sample);
          }
        }

        void collect(List<ui.FrameTiming> values) => timings.addAll(values);
        activeCollector = collect;
        WidgetsBinding.instance.addTimingsCallback(collect);
        WidgetsBinding.instance.addPostFrameCallback(sample);
        await tester.tap(find.byTooltip('返回'));
        await tester.pump();
        await _waitFor(() => firstFrame != null, 'first parent frame $round');
        observing = false;
        expect(firstFrame!['thumbnail'], expectedFrame);
        expect(
          firstFrame!['decodedPixels'],
          isTrue,
          reason: 'The first parent row frame must already contain pixels.',
        );
        expect(
          firstFrame!['pendingBindings'],
          greaterThan(0),
          reason:
              'The 400 ms revalidation must still be pending at first paint.',
        );
        await _waitFor(
          () => model.pendingBindings == 0,
          'return binding $round',
        );
        watch.stop();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        WidgetsBinding.instance.removeTimingsCallback(collect);
        activeCollector = null;
        expect(timings, isNotEmpty);
        expect(_rowState(browser, _folder.path)?.pixels, isTrue);
        rounds.add({
          'round': round + 1,
          'firstParentFrame': firstFrame,
          'bindingSettledMs': watch.elapsedMicroseconds / 1000,
          'previewReadsBefore': beforeReads,
          'previewReadsAfter': model.previewReads,
          'directoryReadsBefore': beforeListings,
          'directoryReadsAfter': Map<String, int>.of(model.directoryReads),
          'frameBuildMs': _distribution(
            timings.map((frame) => frame.buildDuration.inMicroseconds / 1000),
          ),
          'frameRasterMs': _distribution(
            timings.map((frame) => frame.rasterDuration.inMicroseconds / 1000),
          ),
        });
        expect(tester.takeException(), isNull);
      }

      final report = <String, Object?>{
        'mode': kProfileMode ? 'profile' : 'debug',
        'platform': Platform.operatingSystem,
        'scope':
            'Actual SourceBrowser, disk SQLite, background listing preparation, '
            'MediaArtwork and native image decode. Controlled source adapter '
            'and prepared preview bindings delayed 400 ms on revalidation. '
            'Linux Xvfb software rendering; not NAS throughput, native video '
            'capture, mobile frame rate or battery measurements.',
        'directoryEntries': entries.length,
        'preparedScreenshotWidth': 320,
        'preparedScreenshotHeight': 180,
        'bindingDelayMs': 400,
        'previewReadsAfterInitialWarmup': warmReads,
        'captureRequests': model.captureRequests,
        'directoryReads': model.directoryReads,
        'previewReads': model.previewReads,
        'firstFrameDefinition':
            'First rendered frame whose keyed parent directory row exists, '
            'sampled from the live element tree before waiting for revalidation. '
            'Both a prepared thumbnail path and non-null RawImage are required.',
        'rounds': rounds,
      };
      expect(model.captureRequests, 0);
      final output = Directory(
        const String.fromEnvironment(
          'FOLDER_COVER_RETURN_ARTIFACT_DIR',
          defaultValue: '../artifacts/folder-cover-return',
        ),
      );
      await output.create(recursive: true);
      await File('${output.path}/folder-cover-return.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      binding.reportData = report;
      debugPrint('FOLDER COVER RETURN ${jsonEncode(report)}');
    } finally {
      observing = false;
      if (activeCollector != null) {
        WidgetsBinding.instance.removeTimingsCallback(activeCollector);
      }
      await tester.pumpWidget(const SizedBox());
      await _waitFor(
        () => model.pendingBindings == 0,
        'cancel pending bindings',
      );
      model.dispose();
      await model.sync.dispose();
      store.dispose();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<List<SourceEntry>> _seedInBackground(String path) =>
    Isolate.run(() => _seed(path));

List<SourceEntry> _seed(String root) {
  final image = images.Image(width: 320, height: 180);
  for (final pixel in image) {
    pixel.setRgb(pixel.x % 256, pixel.y % 256, (pixel.x + pixel.y) % 256);
  }
  File('$root/frame.jpg').writeAsBytesSync(images.encodeJpg(image));
  final store = AppStore('$root/library.db');
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
  } finally {
    store.dispose();
  }
  return [
    _folder,
    for (var index = 0; index < 1000; index++)
      SourceEntry(
        name: 'Empty ${index.toString().padLeft(4, '0')}',
        path: 'Empty ${index.toString().padLeft(4, '0')}',
        directory: true,
      ),
  ];
}

class _Model extends AppModel {
  final List<SourceEntry> entries;
  final directoryReads = <String, int>{};
  int previewReads = 0, pendingBindings = 0, captureRequests = 0;
  bool delayBindings = false;
  _Model(super.store, super.documents, this.entries)
    : super(backgroundWork: false);

  @override
  Future<SourceAdapter> adapter(String id) async => _Adapter(this);

  @override
  Future<SourcePreviewBinding> readSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    CancelToken? cancel,
    bool albumCover = false,
    bool originalResolution = false,
  }) async {
    previewReads++;
    pendingBindings++;
    try {
      if (delayBindings) {
        await Future.any([
          Future<void>.delayed(const Duration(milliseconds: 400)),
          if (cancel != null)
            cancel.whenCancelled.then<void>((_) => throw const Cancelled()),
        ]);
      }
      cancel?.check();
      return SourcePreviewBinding(
        sourcePreviewId(sourceId, entry.path),
        browsingMediaId(sourceId, entry.path),
        '${documents.path}/frame.jpg',
        false,
      );
    } finally {
      pendingBindings--;
    }
  }

  @override
  bool tryEnsureSourceMediaPreview(
    String sourceId,
    SourceEntry entry, {
    SourcePreviewBinding? binding,
  }) {
    captureRequests++;
    return false;
  }
}

class _Adapter extends SourceAdapter {
  final _Model model;
  _Adapter(this.model);

  @override
  Future<List<SourceEntry>> list(String path) async {
    model.directoryReads.update(path, (count) => count + 1, ifAbsent: () => 1);
    return path.isEmpty
        ? model.entries
        : path == _folder.path
        ? const [_video]
        : const [];
  }

  @override
  Future<SourceEntry> stat(String path) async =>
      path == _video.path ? _video : _folder;

  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
}

({String? thumbnail, bool pixels})? _rowState(Element root, String path) {
  Element? row;
  void findRow(Element element) {
    if (element.widget.key == ValueKey(path)) {
      row = element;
      return;
    }
    element.visitChildren((child) {
      if (row == null) findRow(child);
    });
  }

  findRow(root);
  if (row == null) return null;
  String? thumbnail;
  var pixels = false;
  void inspect(Element element) {
    if (element.widget case MediaArtwork(thumbnail: final path)) {
      thumbnail = path;
    }
    if (element.widget case RawImage(:final image)) pixels |= image != null;
    element.visitChildren(inspect);
  }

  row!.visitChildren(inspect);
  return (thumbnail: thumbnail, pixels: pixels);
}

Future<void> _waitFor(bool Function() ready, String label) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out: $label');
    await Future<void>.delayed(const Duration(milliseconds: 8));
  }
}

Map<String, Object> _distribution(Iterable<double> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return {'count': 0};
  return {
    'count': sorted.length,
    'p50': sorted[(sorted.length * .5).ceil() - 1],
    'p95': sorted[(sorted.length * .95).ceil() - 1],
    'max': sorted.last,
  };
}
