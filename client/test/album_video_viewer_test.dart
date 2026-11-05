import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/media_previews.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_page.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_video_player.dart';
import 'package:aiplayer/ui/album_video_thumbnail.dart';
import 'package:aiplayer/ui/album_viewer.dart';
import 'package:aiplayer/ui/album_wall.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/media_file_details.dart';
import 'package:aiplayer/ui/media_artwork.dart';
import 'package:aiplayer/ui/player_page.dart';
import 'package:aiplayer/ui/sources_page.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:aiplayer/ui/remote_control.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

class _ViewerModel extends AppModel {
  int playbackPreparations = 0, infoRequests = 0;
  bool failInfoRequest = false;
  bool failPlaybackPreparation = false;

  _ViewerModel(super.store, super.documents, {required PreviewCapture capture})
    : super(
        backgroundWork: false,
        enableThumbnails: true,
        previewCapture: capture,
      );

  @override
  Future<SyncRecord> preparePersonalMediaForPlayback(
    String sourceId,
    SourceEntry entry, {
    CancelToken? cancel,
  }) {
    playbackPreparations++;
    if (failPlaybackPreparation) {
      throw const AppFailure('测试播放准备失败');
    }
    return super.preparePersonalMediaForPlayback(
      sourceId,
      entry,
      cancel: cancel,
    );
  }

  @override
  Future<SourceAdapter> adapter(String id) {
    if (failInfoRequest) {
      infoRequests++;
      throw const AppFailure('测试文件信息读取失败');
    }
    return super.adapter(id);
  }
}

void main() {
  late Directory directory;
  late AppStore store;
  late _ViewerModel model;
  late AlbumSnapshot snapshot;
  late List<SourceEntry> entries;
  late List<List<dynamic>> orientations;
  var captures = 0;

  setUp(() async {
    captures = 0;
    orientations = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientations.add(call.arguments as List<dynamic>);
          }
          return null;
        });
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('album-video-viewer-');
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG1sAAAAASUVORK5CYII=',
    );
    entries = [];
    for (final name in ['000.png', '001.mp4', '002.png']) {
      final file = File('${directory.path}/$name');
      await file.writeAsBytes(name.endsWith('.mp4') ? Uint8List(32) : image);
      final stat = await file.stat();
      entries.add(
        SourceEntry(
          name: name,
          path: file.path,
          size: stat.size,
          modified: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    snapshot = AlbumIndex(
      entries,
      sourceId: 'local',
      directory: directory.path,
    ).filter(AlbumOptions());
    store = AppStore(':memory:');
    final videoCover = Uint8List.fromList(
      raster.encodeJpg(raster.Image(width: 90, height: 160)),
    );
    model = _ViewerModel(
      store,
      directory,
      capture: (_, _) async {
        captures++;
        return MediaPreview(videoCover, 60, 90, 160);
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
    model.dispose();
    await model.flushMetadataTasks();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> until(
    WidgetTester tester,
    bool Function() ready, {
    String Function()? diagnostics,
  }) async {
    for (var i = 0; i < 300 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue, reason: diagnostics?.call());
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await until(
      tester,
      () =>
          !tester.binding.hasScheduledFrame &&
          tester
              .widgetList<AlbumThumbnail>(find.byType(AlbumThumbnail))
              .every((thumbnail) => thumbnail.service.pendingCount == 0) &&
          ArtworkDecodeQueue.instance.activeCount == 0 &&
          ArtworkDecodeQueue.instance.pendingCount == 0,
    );
  }

  Future<void> mount(
    WidgetTester tester, {
    int index = 0,
    AppModel? owner,
    bool albumMode = true,
    bool television = false,
    String? initialVideoThumbnail,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            TelevisionInputScope(overrideTelevision: television, child: child!),
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(
            padding: const EdgeInsets.only(top: 24, bottom: 30),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 30),
          ),
          child: AlbumViewer(
            model: owner ?? model,
            source: const {'id': 'local', 'kind': 'local'},
            password: '',
            snapshot: snapshot,
            initialIndex: index,
            albumMode: albumMode,
            initialVideoThumbnail: initialVideoThumbnail,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var previewsPaused = false;
    model.pausePreviews().then((_) => previewsPaused = true);
    await tester.pump(const Duration(milliseconds: 400));
    await until(
      tester,
      () =>
          previewsPaused &&
          AlbumPage.pendingDisposals == 0 &&
          ArtworkDecodeQueue.instance.activeCount == 0 &&
          ArtworkDecodeQueue.instance.pendingCount == 0,
    );
  }

  final canvas = find.byKey(const ValueKey('album-photo-canvas'));
  TransformationController transform(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!;
  bool coverDecoded(WidgetTester tester) => tester
      .widgetList<RawImage>(
        find.descendant(
          of: find.byType(AlbumVideoThumbnail),
          matching: find.byType(RawImage),
        ),
      )
      .any((image) => image.image != null);

  testWidgets(
    'video retains the gallery canvas color and requests a full-size cover',
    (tester) async {
      await mount(tester);
      await tester.drag(canvas, const Offset(-240, 0));
      await settle(tester);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.white,
      );
      expect(
        tester
            .widget<AlbumVideoSurface>(find.byType(AlbumVideoSurface))
            .backgroundColor,
        Colors.white,
      );
      final cover = tester.widget<AlbumVideoThumbnail>(
        find.byType(AlbumVideoThumbnail),
      );
      expect(cover.fit, BoxFit.contain);
      expect(cover.originalResolution, isTrue);
      expect(find.byTooltip('使用完整播放器'), findsOneWidget);
      await tester.drag(canvas, const Offset(240, 0));
      await settle(tester);
      await tester.tapAt(const Offset(350, 260));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.drag(canvas, const Offset(-240, 0));
      await settle(tester);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.black,
      );
      expect(
        tester
            .widget<AlbumVideoSurface>(find.byType(AlbumVideoSurface))
            .backgroundColor,
        Colors.black,
      );
      await unmount(tester);
    },
  );

  testWidgets('mixed-media swipes show video covers without opening playback', (
    tester,
  ) async {
    await mount(tester);
    for (final step in [
      (const Offset(-240, 0), '001.mp4'),
      (const Offset(-240, 0), '002.png'),
      (const Offset(240, 0), '001.mp4'),
      (const Offset(240, 0), '000.png'),
    ]) {
      await tester.drag(canvas, step.$1);
      await settle(tester);
      expect(find.text(step.$2), findsOneWidget);
      if (step.$2.endsWith('.mp4')) {
        await until(
          tester,
          () => captures > 0 && coverDecoded(tester),
          diagnostics: () =>
              'captures=$captures active=${tester.widget<AlbumVideoThumbnail>(find.byType(AlbumVideoThumbnail)).activity?.value} '
              'covers=${tester.widgetList<MediaArtwork>(find.byType(MediaArtwork)).map((artwork) => artwork.thumbnail).toList()}',
        );
        expect(find.byType(AlbumVideoThumbnail), findsOneWidget);
        final surface = tester.widget<AlbumVideoSurface>(
          find.byType(AlbumVideoSurface),
        );
        expect(surface.controller.session, isNull);
        expect(surface.controller.playing, isFalse);
      }
      expect(model.playbackPreparations, 0);
      expect(find.byType(PlayerPage), findsNothing);
    }
    expect(store.records('media'), isEmpty);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets(
    'album video taps switch the canvas without replacing its cover',
    (tester) async {
      await mount(tester, index: 1);
      await until(tester, () => coverDecoded(tester));
      final surface = tester.state(find.byType(AlbumVideoSurface));
      final cover = tester.state(find.byType(AlbumVideoThumbnail));
      for (final color in [Colors.black, Colors.white]) {
        await tester.tapAt(const Offset(240, 230));
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
          color,
        );
        expect(
          tester
              .widget<AlbumVideoSurface>(find.byType(AlbumVideoSurface))
              .backgroundColor,
          color,
        );
        expect(tester.state(find.byType(AlbumVideoSurface)), same(surface));
        expect(tester.state(find.byType(AlbumVideoThumbnail)), same(cover));
        expect(coverDecoded(tester), isTrue);
        final controls = color == Colors.white ? findsOneWidget : findsNothing;
        expect(find.byType(AlbumVideoControls), controls);
        expect(find.byKey(const ValueKey('album-viewer-toolbar')), controls);
        expect(model.playbackPreparations, 0);
      }
      await unmount(tester);
    },
  );

  testWidgets('TV video keeps volume for audio and disables gallery zoom', (
    tester,
  ) async {
    await mount(tester, index: 1, television: true);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(viewer.scaleEnabled, isFalse);
    expect(viewer.panEnabled, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
    await tester.pump();
    expect(transform(tester).value.getMaxScaleOnAxis(), 1);
    final target = tester.widget<RemoteControlTarget>(
      find.byType(RemoteControlTarget).last,
    );
    final result = await target.onCommand(
      RemoteCommand(1, 'zoomIn', null, null, null, () => true),
    );
    expect(result!.ok, isFalse);
    await tester.tapAt(const Offset(240, 230));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(240, 230));
    await tester.pump();
    expect(transform(tester).value.getMaxScaleOnAxis(), 1);
    await unmount(tester);
  });

  testWidgets('video zoom uses gallery gestures and suppresses page swipes', (
    tester,
  ) async {
    await mount(tester, index: 1);
    expect(find.byKey(const ValueKey('album-video-play')), findsNothing);
    final play = find.byKey(const ValueKey('album-video-toggle'));
    final playRect = tester.getRect(play);
    final controlsRect = tester.getRect(find.byType(AlbumVideoControls));
    const focal = Offset(240, 230);
    await tester.tapAt(focal);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(focal);
    await tester.pump();
    expect(transform(tester).value.getMaxScaleOnAxis(), closeTo(2, .001));
    expect(transform(tester).toScene(focal), focal);
    expect(tester.getRect(play), playRect);
    expect(tester.getRect(find.byType(AlbumVideoControls)), controlsRect);
    expect(play.hitTestable(), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
      Colors.white,
    );
    await tester.dragFrom(const Offset(450, 200), const Offset(-240, 0));
    await tester.pump();
    expect(find.byType(AlbumVideoSurface), findsOneWidget);
    expect(tester.getRect(play), playRect);
    expect(play.hitTestable(), findsOneWidget);
    expect(model.playbackPreparations, 0);
    expect(find.byType(AlbumVideoControls), findsOneWidget);
    expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
    await tester.tapAt(const Offset(240, 230));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(AlbumVideoControls), findsOneWidget);
    expect(transform(tester).value.getMaxScaleOnAxis(), closeTo(2, .001));
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
      Colors.black,
    );
    await tester.tapAt(const Offset(240, 230));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(AlbumVideoControls), findsOneWidget);
    expect(tester.getRect(play), playRect);
    expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
    model.failPlaybackPreparation = true;
    await tester.tap(play);
    await until(tester, () => model.playbackPreparations == 1);
    await until(tester, () => find.byTooltip('重试播放').evaluate().isNotEmpty);
    expect(find.byTooltip('重试播放'), findsOneWidget);
    expect(transform(tester).value.getMaxScaleOnAxis(), closeTo(2, .001));
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
      Colors.white,
    );
    // Dismissal is also available through the platform Back action when chrome
    // is hidden by zoom. The first Back returns to the full video frame.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(transform(tester).value.getMaxScaleOnAxis(), 1);
    await tester.dragFrom(const Offset(450, 200), const Offset(-240, 0));
    await settle(tester);
    expect(find.text('002.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('zoom reveals bottom transport after the controls were hidden', (
    tester,
  ) async {
    await mount(tester, index: 1);
    final play = find.byKey(const ValueKey('album-video-toggle'));
    final bounds = tester.getRect(play);
    const focal = Offset(240, 230);
    await tester.tapAt(focal);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(AlbumVideoControls), findsNothing);
    await tester.tapAt(focal);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(focal);
    await tester.pump();
    expect(transform(tester).value.getMaxScaleOnAxis(), closeTo(2, .001));
    expect(tester.getRect(play), bounds);
    expect(play.hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('album-video-play')), findsNothing);
    expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
    expect(model.playbackPreparations, 0);
    await unmount(tester);
  });

  testWidgets('replacing a viewer owner retires its controller and old cover', (
    tester,
  ) async {
    await mount(tester, index: 1);
    await until(tester, () => coverDecoded(tester));
    final initialThumbnail = tester
        .widget<MediaArtwork>(find.byType(MediaArtwork))
        .thumbnail;
    final viewerState = tester.state(find.byType(AlbumViewer));
    final old = tester
        .widget<AlbumVideoSurface>(find.byType(AlbumVideoSurface))
        .controller;
    final replacementStore = AppStore(':memory:');
    final replacement = _ViewerModel(
      replacementStore,
      directory,
      capture: (_, cancel) => cancel.whenCancelled.then<MediaPreview>(
        (_) => throw const Cancelled(),
      ),
    );
    try {
      await mount(
        tester,
        index: 1,
        owner: replacement,
        initialVideoThumbnail: initialThumbnail,
      );
      expect(tester.state(find.byType(AlbumViewer)), same(viewerState));
      final current = tester
          .widget<AlbumVideoSurface>(find.byType(AlbumVideoSurface))
          .controller;
      expect(old.closed, isTrue);
      expect(current, isNot(same(old)));
      expect(current.model, same(replacement));
      expect(current.session, isNull);
      expect(coverDecoded(tester), isFalse);
      expect(
        tester.widget<MediaArtwork>(find.byType(MediaArtwork)).thumbnail,
        isNull,
      );
      await mount(tester, index: 1, owner: replacement, albumMode: false);
      expect(tester.state(find.byType(AlbumViewer)), same(viewerState));
      expect(current.closed, isTrue);
      expect(
        tester
            .widget<AlbumVideoSurface>(find.byType(AlbumVideoSurface))
            .controller
            .session,
        isNull,
      );
      expect(
        tester
            .widget<AlbumVideoThumbnail>(find.byType(AlbumVideoThumbnail))
            .firstFrame,
        isFalse,
      );
      expect(coverDecoded(tester), isFalse);
      expect(model.playbackPreparations, 0);
      expect(replacement.playbackPreparations, 0);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      var retired = false;
      replacement.pausePreviews().then((_) => retired = true);
      await until(tester, () => retired);
      replacement.dispose();
      await tester.runAsync(replacement.flushMetadataTasks);
      replacementStore.dispose();
    }
  });

  testWidgets('a cached adjacent video cover appears during a held photo drag', (
    tester,
  ) async {
    await mount(tester, index: 1);
    await until(tester, () => coverDecoded(tester));
    final captureCount = captures;
    // A new viewer cannot rely on the old viewer's resident cover map. It must
    // look up the adjacent cached binding without opening a second decoder.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 400));
    await mount(tester);
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    expect(find.text('000.png'), findsOneWidget);
    final adjacent = tester.widget<AlbumVideoThumbnail>(
      find.byType(AlbumVideoThumbnail),
    );
    expect(adjacent.active, isFalse);
    expect(adjacent.initialThumbnail, isNotNull);
    expect(coverDecoded(tester), isTrue);
    expect(captures, captureCount);
    expect(model.playbackPreparations, 0);
    await gesture.cancel();
    await settle(tester);
    expect(find.text('000.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('video info opens a media inspection sheet without playback', (
    tester,
  ) async {
    await mount(tester, index: 1);
    await until(tester, () => captures > 0 && coverDecoded(tester));
    model.failInfoRequest = true;
    await tester.tap(find.byTooltip('视频信息'));
    await until(tester, () => model.infoRequests > 0);
    await settle(tester);
    expect(find.byType(MediaFileDetailsSheet), findsOneWidget);
    expect(find.byType(AlbumPhotoInfoSheet), findsNothing);
    expect(find.text('文件详情'), findsOneWidget);
    expect(model.playbackPreparations, 0);
    await tester.tap(find.byTooltip('关闭文件详情'));
    await settle(tester);
    expect(find.byType(MediaFileDetailsSheet), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('TV arrows reach video information and transport controls', (
    tester,
  ) async {
    await mount(tester, index: 1, television: true);
    await until(tester, () => coverDecoded(tester));
    final viewerFocus = tester
        .widgetList<Focus>(find.byType(Focus))
        .singleWhere((focus) => focus.focusNode?.debugLabel == 'album-viewer')
        .focusNode!;
    bool focusedWithin(Finder finder) {
      final targets = finder.evaluate().toSet();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused is! Element) return false;
      var found = targets.contains(focused);
      focused.visitAncestorElements((element) {
        found |= targets.contains(element);
        return !found;
      });
      return found;
    }

    expect(viewerFocus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(transform(tester).value.getMaxScaleOnAxis(), 1);
    expect(
      focusedWithin(find.byKey(const ValueKey('album-viewer-toolbar'))),
      isTrue,
      reason: '${FocusManager.instance.primaryFocus}',
    );
    final info = find.byTooltip('视频信息');
    if (!focusedWithin(info)) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(focusedWithin(info), isTrue);
    model.failInfoRequest = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(tester, () => model.infoRequests > 0);
    await settle(tester);
    expect(find.byType(MediaFileDetailsSheet), findsOneWidget);
    await tester.tap(find.byTooltip('关闭文件详情'));
    await settle(tester);

    viewerFocus.requestFocus();
    await tester.pump();
    await tester.dragFrom(const Offset(450, 200), const Offset(0, -100));
    await tester.pump();
    expect(find.byType(AlbumVideoControls), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(
      focusedWithin(find.byKey(const ValueKey('album-video-toggle'))),
      isTrue,
    );
    expect(transform(tester).value.getMaxScaleOnAxis(), 1);
    expect(model.playbackPreparations, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump(TelevisionInputScope.menuDoublePressInterval);
    await tester.pump();
    expect(focusedWithin(info), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      focusedWithin(find.byKey(const ValueKey('album-video-toggle'))),
      isTrue,
    );
    // Exercise actual OK dispatch without creating a native player in widgets.
    model.failPlaybackPreparation = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await until(
      tester,
      () => model.playbackPreparations == 1,
      diagnostics: () {
        final controller = tester
            .widget<AlbumVideoControls>(find.byType(AlbumVideoControls))
            .controller;
        return 'focus=${FocusManager.instance.primaryFocus}, prepares=${model.playbackPreparations}, active=${controller.presentationActive}, loading=${controller.loading}, error=${controller.error}';
      },
    );
    await settle(tester);
    expect(find.text('测试播放准备失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets(
    'video fills both orientations while controls avoid system bars',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(400, 800), const Size(800, 400)]) {
        tester.view.physicalSize = size;
        await mount(tester, index: 1);
        await until(tester, () => coverDecoded(tester));
        final frame = tester
            .widgetList<RawImage>(
              find.descendant(
                of: find.byType(AlbumVideoThumbnail),
                matching: find.byType(RawImage),
              ),
            )
            .singleWhere((frame) => frame.image != null);
        expect(frame.image!.width, 90);
        expect(frame.image!.height, 160);
        expect(frame.fit, BoxFit.contain);
        expect(tester.getRect(canvas), Offset.zero & size);
        expect(
          tester.getTopLeft(find.byType(BackButton)).dy,
          greaterThanOrEqualTo(24),
        );
        final controls = find.byType(AlbumVideoControls);
        expect(controls, findsOneWidget);
        expect(
          tester.getBottomRight(controls).dy,
          lessThanOrEqualTo(size.height - 30),
        );
        expect(model.playbackPreparations, 0);
        expect(tester.takeException(), isNull);
      }
      expect(orientations, isNotEmpty);
      expect(orientations.every((requested) => requested.isEmpty), isTrue);
      await unmount(tester);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'tapping an album video opens the shared viewer without autoplay',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumPage(
            model: model,
            source: const {'id': 'local', 'kind': 'local'},
            initialPath: directory.path,
            initialEntries: entries,
          ),
        ),
      );
      await until(
        tester,
        () =>
            find.byType(AlbumWall).evaluate().isNotEmpty &&
            tester
                .widget<AlbumWall>(find.byType(AlbumWall))
                .snapshot
                .items
                .any((item) => item.isVideo),
      );
      final wall = tester.widget<AlbumWall>(find.byType(AlbumWall));
      final video = wall.snapshot.items.singleWhere((item) => item.isVideo);
      await until(tester, () => coverDecoded(tester));
      final wallCover = tester
          .widget<MediaArtwork>(
            find.descendant(
              of: find.byType(AlbumVideoThumbnail),
              matching: find.byType(MediaArtwork),
            ),
          )
          .thumbnail;
      expect(wallCover, isNotNull);
      await tester.tap(find.byKey(ValueKey(video.id)));
      await until(tester, () => find.byType(AlbumViewer).evaluate().isNotEmpty);
      expect(
        tester
            .widget<AlbumViewer>(find.byType(AlbumViewer))
            .initialVideoThumbnail,
        wallCover,
      );
      await settle(tester);
      expect(find.byType(AlbumVideoSurface), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
      expect(model.playbackPreparations, 0);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets('the file-browser viewer keeps its ordinary video cover policy', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: SourceBrowser(
          model: model,
          source: const {'id': 'local', 'kind': 'local', 'label': '本地'},
          initialPath: directory.path,
          initialAlbumMode: false,
        ),
      ),
    );
    await until(tester, () => find.text('000.png').evaluate().isNotEmpty);
    await tester.tap(find.text('000.png'));
    await until(tester, () => find.byType(AlbumViewer).evaluate().isNotEmpty);
    await settle(tester);
    expect(
      tester.widget<AlbumViewer>(find.byType(AlbumViewer)).albumMode,
      isFalse,
    );
    await tester.drag(canvas, const Offset(-240, 0));
    await settle(tester);
    expect(find.text('001.mp4'), findsOneWidget);
    expect(
      tester
          .widget<AlbumVideoThumbnail>(find.byType(AlbumVideoThumbnail))
          .firstFrame,
      isFalse,
    );
    expect(model.playbackPreparations, 0);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
