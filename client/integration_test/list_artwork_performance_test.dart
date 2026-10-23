import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

// Actual list widgets and image pipeline, hosted in production GlassBackground.
// Disk fixtures are generated on a separate isolate. Directory adapters and
// capture requests are controlled; this does not measure NAS IO/video capture.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('profile actual detail and folder list covers in both directions', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final reports = <Map<String, Object?>>[];
    for (final scenario in [
      'library-details',
      'source-details',
      'folders',
      'local-files',
    ]) {
      final root = await Directory.systemTemp.createTemp(
        'list-artwork-profile-',
      );
      final path = root.path;
      await _seedInBackground(path, scenario);
      final store = AppStore.openExisting('$path/library.db');
      final model = _Model(store, root, scenario);
      try {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        final child = switch (scenario) {
          'library-details' => LibraryPage(model: model),
          'local-files' => SourcesPage(
            model: model,
            onImport: () async {},
            onPlay: (_) async {},
          ),
          _ => SourceBrowser(
            model: model,
            source: const {'id': 'nas', 'kind': 'webdav', 'label': 'NAS'},
            initialPath: scenario == 'source-details' ? 'Example' : null,
          ),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: Scaffold(body: GlassBackground(child: child)),
          ),
        );
        await tester.pumpAndSettle();
        if (scenario == 'library-details') {
          await _wait(
            () => find
                .byKey(const ValueKey('details:0001'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.tap(find.byKey(const ValueKey('details:0001')));
        } else if (scenario == 'local-files') {
          await tester.tap(find.text('本地视频').first);
        }
        await tester.pumpAndSettle();
        final list = scenario == 'library-details'
            ? find.byKey(const ValueKey('series-details-list'))
            : find.byType(ListView);
        await _wait(() {
          final visible = _visible(list);
          return visible.isNotEmpty && visible.values.every((ready) => ready);
        });
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        for (final direction in ['forward', 'reverse']) {
          final initial = _visible(list).keys.toSet();
          final observations = <String, ({int first, int? ready})>{};
          final frames = <ui.FrameTiming>[];
          final watch = Stopwatch()..start();
          var observing = true;
          void sample(Duration _) {
            if (!observing) return;
            final now = watch.elapsedMicroseconds;
            for (final entry in _visible(list).entries) {
              if (initial.contains(entry.key)) continue;
              final previous = observations[entry.key];
              observations[entry.key] = (
                first: previous?.first ?? now,
                ready: previous?.ready ?? (entry.value ? now : null),
              );
            }
            WidgetsBinding.instance.addPostFrameCallback(sample);
          }

          void collect(List<ui.FrameTiming> values) => frames.addAll(values);
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          WidgetsBinding.instance.addTimingsCallback(collect);
          WidgetsBinding.instance.addPostFrameCallback(sample);
          await position.animateTo(
            direction == 'forward' ? 6000 : 0,
            duration: const Duration(seconds: 10),
            curve: Curves.linear,
          );
          await tester.pump();
          observing = false;
          watch.stop();
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          WidgetsBinding.instance.removeTimingsCallback(collect);
          expect(observations.length, greaterThan(50));
          expect(frames, isNotEmpty);
          reports.add({
            'scenario': scenario,
            'direction': direction,
            'entries': 240,
            'newVisibleCovers': observations.length,
            'readyOnFirstVisibleFrame': observations.values
                .where((v) => v.ready == v.first)
                .length,
            'unresolved': observations.values
                .where((v) => v.ready == null)
                .length,
            'visibleToPixelsMs': _distribution(
              observations.values
                  .where((v) => v.ready != null)
                  .map((v) => (v.ready! - v.first) / 1000),
            ),
            'frameBuildMs': _distribution(
              frames.map((f) => f.buildDuration.inMicroseconds / 1000),
            ),
            'frameRasterMs': _distribution(
              frames.map((f) => f.rasterDuration.inMicroseconds / 1000),
            ),
          });
          debugPrint('LIST PROFILE ${reports.last}');
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        model.dispose();
        await model.sync.dispose();
        store.dispose();
        await root.delete(recursive: true);
      }
    }
    final report = {
      'mode': kProfileMode ? 'profile' : 'debug',
      'scope':
          'Actual LibraryPage detail sheet, SourceBrowser episode/folder lists, SourcesPage local list; 240 unique 320x180 JPEG disk files; separate-isolate fixture creation; 600 pixels/second continuous scroll 10 seconds each direction. Fixture source adapters and preview capture callbacks; Linux Xvfb software rendering, not device FPS or NAS/WAN throughput.',
      'latencyDefinition':
          'First frame with any cover area visible to first RawImage pixels; initially visible covers excluded. 0ms means prepared before entry, not zero IO/decode time.',
      'viewport': {
        'width': tester.view.physicalSize.width / tester.view.devicePixelRatio,
        'height': tester.view.physicalSize.height / tester.view.devicePixelRatio,
        'devicePixelRatio': tester.view.devicePixelRatio,
      },
      'scenarios': reports,
    };
    final output = Directory(
      const String.fromEnvironment(
        'LIST_ARTWORK_ARTIFACT_DIR',
        defaultValue: '../artifacts/list-artwork',
      ),
    );
    await output.create(recursive: true);
    await File(
      '${output.path}/list-artwork-performance.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    binding.reportData = report;
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _wait(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('List covers did not become ready.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Map<String, bool> _visible(Finder list) {
  final root = list.evaluate().firstOrNull;
  if (root == null) return {};
  final viewport = root.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return {};
  final clip = (viewport.localToGlobal(Offset.zero) & viewport.size).intersect(
    Offset.zero & MediaQuery.sizeOf(root),
  );
  final result = <String, bool>{};
  bool decoded(Element element) {
    if (element.widget case RawImage(:final image)) return image != null;
    var found = false;
    element.visitChildren((child) {
      if (!found) found = decoded(child);
    });
    return found;
  }

  void visit(Element element) {
    if (element.widget case MediaArtwork(:final poster, :final thumbnail)) {
      final key = thumbnail ?? poster;
      final box = element.findRenderObject();
      if (key.isNotEmpty &&
          box is RenderBox &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).overlaps(clip)) {
        result[key] = decoded(element);
      }
      return;
    }
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
  return result;
}

String _id(int index) => index.toString().padLeft(4, '0');
Future<void> _seedInBackground(String path, String scenario) =>
    Isolate.run(() => _seed(path, scenario));
SourceEntry _episode(int index, {bool folder = false}) {
  final id = _id(index);
  final name = folder ? 'Series $id S01E01.mp4' : 'Example S01E$id.mp4';
  return SourceEntry(
    name: name,
    path: '${folder ? 'Series $id' : 'Example'}/$name',
    size: 1024,
  );
}

void _seed(String path, String scenario) {
  final folders = scenario == 'folders';
  final image = img.Image(width: 320, height: 180);
  for (final pixel in image) {
    pixel.setRgb(pixel.x % 256, pixel.y % 256, (pixel.x + pixel.y) % 256);
  }
  final bytes = img.encodeJpg(image, quality: 85);
  final cache = PosterCache(
    directory: Directory('$path/poster-cache-v1')..createSync(),
  );
  final store = AppStore('$path/library.db');
  try {
    store.setLocal('settings', {
      'metadataStrategy': 'off',
      'autoDiscover': false,
    });
    store.transaction(() {
      for (var index = 1; index <= 240; index++) {
        final id = _id(index), entry = _episode(index, folder: folders);
        final poster = 'https://example.invalid/$id.jpg';
        if (folders) {
          cache.cachedFile(poster).writeAsBytesSync(bytes);
        } else {
          File('$path/$id.jpg').writeAsBytesSync(bytes);
        }
        store.save('media', id, {
          'title': entry.name,
          'fileName': entry.name,
          'series': folders ? 'Series $id' : 'Example',
          'metadataTitle': folders ? 'Series $id' : 'Example',
          'bangumiId': folders ? '$index' : '123',
          'season': '1',
          'episode': folders ? '1' : '$index',
          if (folders) 'poster': poster,
        });
        store.setLocal('location:$id', {
          'id': id,
          'source': scenario == 'local-files' ? 'local' : 'nas',
          'path': entry.path,
          'size': 1024,
        });
      }
    });
  } finally {
    store.dispose();
    cache.close();
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents, this.scenario)
    : super(backgroundWork: false);
  final String scenario;
  @override
  String? thumbnailPath(String id) =>
      scenario == 'folders' ? null : '${documents.path}/$id.jpg';
  @override
  void ensureMediaPreview(String id) {}
  @override
  Future<bool> needsMediaPreview(String id) async => false;
  @override
  Future<SourceAdapter> adapter(String id) async =>
      _Adapter(scenario == 'folders');
  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async => (await loadLibrarySnapshot(cancel: cancel)).seriesFor(record);
  @override
  Future<DirectoryCollection?> synchronizeDirectoryEntriesInBackground(
    String sourceId,
    String path,
    List<SourceEntry> entries, {
    String? anchorId,
    CancelToken? cancel,
  }) async => identifyDirectory(path, entries);
  @override
  Future<DirectoryCollection> synchronizeCollectionInBackground(
    String sourceId,
    DirectoryCollection value, {
    bool? importMissing,
    String? anchorId,
    CancelToken? cancel,
  }) async {
    if (scenario != 'folders') return value;
    final id = value.title.split(' ').last;
    return value.withMetadata({
      'id': '${int.tryParse(id) ?? 1}',
      'name': value.title,
      'images': {'large': 'https://example.invalid/$id.jpg'},
    }, {});
  }
}

class _Adapter extends SourceAdapter {
  _Adapter(this.folders);
  final bool folders;
  @override
  Future<List<SourceEntry>> list(String path) async => folders
      ? path.isEmpty
            ? [
                for (var i = 1; i <= 240; i++)
                  SourceEntry(
                    name: 'Series ${_id(i)}',
                    path: 'Series ${_id(i)}',
                    directory: true,
                  ),
              ]
            : [_episode(int.parse(path.split(' ').last), folder: true)]
      : [for (var i = 1; i <= 240; i++) _episode(i)];
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(name: path, path: path);
  @override
  Stream<List<int>> read(String path, int start, int end) =>
      const Stream.empty();
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
