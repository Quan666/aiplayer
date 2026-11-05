import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/data/album_catalog.dart';
import 'package:aiplayer/data/album_images.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/album_thumbnail.dart';
import 'package:aiplayer/ui/album_viewer.dart';
import 'package:aiplayer/ui/artwork_decode_queue.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/remote_control.dart';
import 'package:aiplayer/ui/television_input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as raster;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedSlideshowPreferences extends AppModel {
  final save = Completer<void>();
  _DelayedSlideshowPreferences(super.store, super.documents)
    : super(backgroundWork: false);

  @override
  Future<void> updatePreferences(Map<String, dynamic> patch) async {
    if (patch.containsKey('albumSlideshowSeconds')) await save.future;
    await super.updatePreferences(patch);
  }
}

void main() {
  late Directory directory;
  late AppStore store;
  late AppModel model;
  late AlbumSnapshot snapshot;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('album-viewer-');
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG1sAAAAASUVORK5CYII=',
    );
    final entries = <SourceEntry>[];
    for (var index = 0; index < 3; index++) {
      final file = File('${directory.path}/00$index.png');
      await file.writeAsBytes(bytes);
      entries.add(SourceEntry(name: '00$index.png', path: file.path));
    }
    snapshot = AlbumIndex(
      entries,
      sourceId: 'local',
      directory: directory.path,
    ).filter(AlbumOptions());
    store = AppStore(':memory:');
    model = AppModel(store, directory, backgroundWork: false);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    model.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    // Worker I/O uses real time; an intentional loading ticker never settles
    // while only the fake widget clock advances.
    for (var i = 0; i < 300; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      if (find
              .byKey(const ValueKey('album-image-loading'))
              .evaluate()
              .isEmpty &&
          !tester.binding.hasScheduledFrame &&
          tester
              .widgetList<AlbumThumbnail>(find.byType(AlbumThumbnail))
              .every((thumbnail) => thumbnail.service.pendingCount == 0) &&
          ArtworkDecodeQueue.instance.activeCount == 0 &&
          ArtworkDecodeQueue.instance.pendingCount == 0) {
        return;
      }
    }
    fail(
      'Viewer image did not finish loading: loading=${find.byKey(const ValueKey("album-image-loading")).evaluate().length}, frames=${tester.binding.hasScheduledFrame}, tickers=${tester.binding.transientCallbackCount}, services=${tester.widgetList<AlbumThumbnail>(find.byType(AlbumThumbnail)).map((thumbnail) => thumbnail.service.pendingCount).toList()}, decode=${ArtworkDecodeQueue.instance.activeCount}/${ArtworkDecodeQueue.instance.pendingCount}',
    );
  }

  Future<void> mount(
    WidgetTester tester, {
    Future<void> Function()? onClosed,
    AlbumImageResult? initialPreview,
    bool motionEnabled = true,
    bool disableAnimations = false,
    bool television = false,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            TelevisionInputScope(overrideTelevision: television, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('open viewer'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      padding: const EdgeInsets.only(top: 24, bottom: 30),
                      viewPadding: const EdgeInsets.only(top: 24, bottom: 30),
                      disableAnimations: disableAnimations,
                    ),
                    child: MotionScope(
                      enabled: motionEnabled,
                      child: AlbumViewer(
                        model: model,
                        source: const {'id': 'local', 'kind': 'local'},
                        password: '',
                        snapshot: snapshot,
                        initialIndex: 0,
                        initialPreview: initialPreview,
                      ),
                    ),
                  ),
                ),
              ).then((_) => onClosed?.call()),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open viewer'));
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Flutter's double-tap tracker retains its short minimum interval timer.
    await tester.pump(const Duration(milliseconds: 50));
    final decodes = ArtworkDecodeQueue.instance;
    for (
      var i = 0;
      i < 180 && (decodes.activeCount > 0 || decodes.pendingCount > 0);
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(decodes.activeCount, 0);
    expect(decodes.pendingCount, 0);
  }

  TransformationController transform(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!;

  testWidgets(
    'TV OK toggles photo canvas once per press and Menu reaches zoomed toolbar',
    (tester) async {
      await mount(tester, television: true);
      final viewerFocus = tester
          .widgetList<Focus>(find.byType(Focus))
          .singleWhere((focus) => focus.focusNode?.debugLabel == 'album-viewer')
          .focusNode!;
      Color? canvasColor() =>
          tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor;
      expect(canvasColor(), Colors.white);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(canvasColor(), Colors.white);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(canvasColor(), Colors.black);
      expect(viewerFocus.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.pump();
      final zoom = transform(tester).value.clone();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(canvasColor(), Colors.white);
      expect(transform(tester).value, zoom);
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump(TelevisionInputScope.menuDoublePressInterval);
      await tester.pump();
      final infoFocus = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '照片信息',
            ),
          )
          .focusNode!;
      expect(infoFocus.hasPrimaryFocus, isTrue);
      expect(transform(tester).value, zoom);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(viewerFocus.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump();
      expect(infoFocus.hasPrimaryFocus, isTrue);
      expect(find.byType(AlbumViewer), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'viewer keeps system navigation hidden with toolbar and restores without a frame',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      final orientationReply = Completer<void>();
      var delayOrientation = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          if (delayOrientation &&
              call.method == 'SystemChrome.setPreferredOrientations') {
            await orientationReply.future;
          }
          return null;
        },
      );
      await mount(tester, television: true);
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      expect(
        calls
            .lastWhere(
              (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
            )
            .arguments,
        'SystemUiMode.immersiveSticky',
      );
      calls.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        calls.where(
          (call) => call.method == 'SystemChrome.setEnabledSystemUIOverlays',
        ),
        isEmpty,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.pump();
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      delayOrientation = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Pause also reveals chrome, superseding the pending orientation request.
      // Its delayed reply must still restore system bars without another frame.
      delayOrientation = false;
      orientationReply.complete();
      await tester.idle();
      expect(
        calls.any(
          (call) =>
              call.method == 'SystemChrome.setEnabledSystemUIOverlays' &&
              (call.arguments as List).contains('SystemUiOverlay.bottom'),
        ),
        isTrue,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.idle();
      expect(
        calls
            .lastWhere(
              (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
            )
            .arguments,
        'SystemUiMode.immersiveSticky',
      );
      await unmount(tester);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'TV photos navigate toolbar, zoom with volume and pan with arrows',
    (tester) async {
      await mount(tester, television: true);
      final viewerFocus = tester
          .widgetList<Focus>(find.byType(Focus))
          .singleWhere((focus) => focus.focusNode?.debugLabel == 'album-viewer')
          .focusNode!;
      final infoFocus = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '照片信息',
            ),
          )
          .focusNode!;
      expect(viewerFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(infoFocus.hasPrimaryFocus, isTrue);
      expect(transform(tester).value.getMaxScaleOnAxis(), 1);
      final iconTheme = IconButtonTheme.of(
        tester.element(find.byTooltip('照片信息')),
      );
      expect(iconTheme.style!.side!.resolve({WidgetState.focused})!.width, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(viewerFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), closeTo(1.25, .001));
      expect(viewerFocus.hasPrimaryFocus, isTrue);
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      final matrix = transform(tester).value.clone();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), closeTo(1.25, .001));
      expect(transform(tester).value.storage[13], lessThan(matrix.storage[13]));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(transform(tester).value.storage[12], lessThan(matrix.storage[12]));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AlbumViewer), findsOneWidget);
      expect(transform(tester).value.getMaxScaleOnAxis(), 1);
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(find.text('001.png'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(AlbumViewer), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('TV slideshow toolbar stays visible while remotely focused', (
    tester,
  ) async {
    await tester.runAsync(
      () => model.updatePreferences({
        'controlsHideSeconds': 1,
        'albumSlideshowSeconds': 60,
      }),
    );
    await mount(tester, television: true);
    final target = tester.widget<RemoteControlTarget>(
      find.byType(RemoteControlTarget).last,
    );
    await target.onCommand(
      RemoteCommand(1, 'play', null, null, null, () => true),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump();
    final focus = tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '照片信息',
          ),
        )
        .focusNode!;
    expect(focus.hasPrimaryFocus, isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsOneWidget);
    expect(focus.hasPrimaryFocus, isTrue);
    await unmount(tester);
  });

  for (final television in [false, true]) {
    testWidgets(
      'photo toolbar auto-hides and reveals with television=$television',
      (tester) async {
        await tester.runAsync(
          () => model.updatePreferences({'controlsHideSeconds': 1}),
        );
        await mount(tester, television: television);
        final toolbar = find.byKey(const ValueKey('album-viewer-toolbar'));
        expect(toolbar, findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(toolbar, findsNothing);
        if (television) {
          await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
          await tester.pump(TelevisionInputScope.menuDoublePressInterval);
          await tester.pump();
        } else {
          await tester.drag(
            find.byKey(const ValueKey('album-photo-canvas')),
            const Offset(0, 180),
          );
          await tester.pump();
        }
        expect(toolbar, findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(toolbar, television ? findsOneWidget : findsNothing);
        if (television) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(toolbar, findsNothing);
        }
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'painted photo stays centered across aspect, zoom, rotation and resize',
    (tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 2; i++) {
          await File('${directory.path}/00$i.png').writeAsBytes(
            raster.encodePng(
              raster.Image(width: i == 0 ? 120 : 60, height: i == 0 ? 60 : 120),
            ),
          );
        }
      });
      await mount(tester);
      void centered() {
        final raw = find.descendant(
          of: find.byType(AlbumThumbnail),
          matching: find.byType(RawImage),
        );
        final render = tester.renderObject<RenderImage>(raw);
        final image = render.image!;
        final fitted = applyBoxFit(
          render.fit ?? BoxFit.scaleDown,
          Size(image.width.toDouble(), image.height.toDouble()),
          render.size,
        );
        final local = render.alignment
            .resolve(render.textDirection)
            .inscribe(fitted.destination, Offset.zero & render.size);
        final painted = MatrixUtils.transformRect(
          render.getTransformTo(null),
          local,
        );
        final canvas = tester.getRect(
          find.byKey(const ValueKey('album-photo-canvas')),
        );
        expect(painted.center.dx, closeTo(canvas.center.dx, .01));
        expect(painted.center.dy, closeTo(canvas.center.dy, .01));
      }

      Future<void> command(String action) async {
        await tester
            .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
            .onCommand(RemoteCommand(1, action, null, null, null, () => true));
        await settle(tester);
      }

      centered();
      await command('zoomIn');
      centered();
      await command('rotate');
      centered();
      await command('next');
      centered();
      await command('rotate');
      centered();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await settle(tester);
      centered();
      await command('zoomIn');
      centered();
      await unmount(tester);
    },
  );

  testWidgets(
    'large real-format groups build lazy rows and reject stale selection',
    (tester) async {
      final members = <SourceEntry>[];
      for (final extension in [
        'jpeg',
        'webp',
        'heif',
        'tiff',
        'arw',
        'dng',
        'nef',
      ]) {
        // A case-sensitive NAS can contain these distinct same-stem filenames.
        for (var variant = 0; variant < 1 << extension.length; variant++) {
          final suffix = [
            for (var i = 0; i < extension.length; i++)
              variant & (1 << i) == 0
                  ? extension[i]
                  : extension[i].toUpperCase(),
          ].join();
          members.add(
            SourceEntry(
              name: '001.$suffix',
              path: '${directory.path}/001.$suffix',
            ),
          );
        }
      }
      snapshot = AlbumIndex(
        members,
        sourceId: 'local',
        directory: directory.path,
      ).filter(AlbumOptions());
      final group = snapshot.items.single;
      expect(group.members, hasLength(88));
      await mount(tester);
      final remote = tester.widget<RemoteControlTarget>(
        find.byType(RemoteControlTarget),
      );
      await remote.onCommand(
        RemoteCommand(1, 'zoomIn', null, null, null, () => true),
      );
      await remote.onCommand(
        RemoteCommand(2, 'rotate', null, null, null, () => true),
      );
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), 2);
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        1,
      );
      await remote.onCommand(
        RemoteCommand(3, 'select', null, null, null, () => true),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('选择格式'));
      await settle(tester);
      final list = find.byKey(const ValueKey('album-formats-list'));
      expect(list, findsOneWidget);
      final rows = find.byWidgetPredicate(
        (widget) =>
            widget is ListTile &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('album-format:'),
      );
      expect(rows.evaluate().length, inExclusiveRange(0, 40));
      final last = find.byKey(
        ValueKey('album-format:${group.members.length - 1}'),
      );
      expect(last, findsNothing);
      await tester.scrollUntilVisible(
        last,
        260,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(rows.evaluate().length, lessThan(40));
      await tester.tap(last);
      await settle(tester);
      expect(find.text(group.members.last.name), findsOneWidget);
      expect(transform(tester).value.getMaxScaleOnAxis(), 1);
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        0,
      );
      await tester.tap(find.byTooltip('选择格式'));
      await settle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.tap(find.byKey(const ValueKey('album-format:0')));
      await settle(tester);
      expect(find.text(group.members.last.name), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'navigation skips generic files and opens a compact information sheet',
    (tester) async {
      snapshot = AlbumIndex(
        [
          snapshot.items[0].preferred,
          const SourceEntry(name: '000.txt', path: '/000.txt'),
          snapshot.items[1].preferred,
          const SourceEntry(name: '999.txt', path: '/999.txt'),
        ],
        sourceId: 'local',
        directory: directory.path,
      ).filter(AlbumOptions(types: const {'*'}));
      await mount(tester);
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(-220, 0),
      );
      await tester.pump();
      expect(find.text('001.png'), findsOneWidget);
      expect(find.byTooltip('下一项'), findsNothing);
      expect(find.byTooltip('上一项'), findsNothing);
      await tester.tap(find.byTooltip('照片信息'));
      await settle(tester);
      expect(find.byType(AlbumPhotoInfoSheet), findsOneWidget);
      expect(
        tester.getSize(find.byType(AlbumPhotoInfoSheet)).height,
        lessThanOrEqualTo(450),
      );
      expect(find.text('文件名'), findsOneWidget);
      expect(find.text('导出'), findsNothing);
      await tester.tap(find.byTooltip('关闭照片信息'));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.text('000.png'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'taps switch canvas color while swipes and zoom control immersive chrome',
    (tester) async {
      await mount(tester);
      final canvas = find.byKey(const ValueKey('album-photo-canvas'));
      expect(tester.getTopLeft(canvas), Offset.zero);
      expect(tester.getBottomRight(canvas), const Offset(800, 600));
      expect(
        tester.getTopLeft(find.byType(BackButton)).dy,
        greaterThanOrEqualTo(24),
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '照片信息',
              ),
            )
            .color,
        Colors.white,
      );
      expect(find.byTooltip('旋转'), findsNothing);
      expect(find.byTooltip('缩放'), findsNothing);
      expect(find.byTooltip('幻灯片'), findsNothing);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.white,
      );
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.black,
      );
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      await tester.drag(canvas, const Offset(0, -180));
      await tester.pump();
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      expect(find.byType(BackButton), findsNothing);
      await tester.drag(canvas, const Offset(-220, 0));
      await tester.pump();
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.white,
      );
      await tester.drag(canvas, const Offset(0, 180));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      expect(find.text('001.png'), findsOneWidget);
      const focal = Offset(250, 230);
      await tester.tapAt(focal);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(focal);
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), closeTo(2, .001));
      expect(transform(tester).toScene(focal), focal);
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.white,
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'Back restores system UI before a later page can request immersive mode',
    (tester) async {
      final release = Completer<void>();
      final modes = <String>[];
      var closed = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
            modes.add('restore-bars');
            await release.future;
          } else if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            modes.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await mount(
        tester,
        onClosed: () async {
          closed = true;
          await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.immersiveSticky,
          );
        },
      );
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(modes, contains('restore-bars'));
      expect(closed, isFalse);
      expect(find.byType(AlbumViewer), findsOneWidget);
      release.complete();
      await settle(tester);
      expect(closed, isTrue);
      expect(find.byType(AlbumViewer), findsNothing);
      expect(modes.last, 'SystemUiMode.immersiveSticky');
      await tester.idle();
      expect(modes.last, 'SystemUiMode.immersiveSticky');
      await unmount(tester);
    },
  );

  testWidgets(
    'swipe navigates once, zoomed drag pans and Back resets zoom before leaving',
    (tester) async {
      await mount(tester);
      final canvas = find.byKey(const ValueKey('album-photo-canvas'));
      await tester.drag(canvas, const Offset(-220, 0));
      await tester.pump();
      expect(find.text('001.png'), findsOneWidget);
      await tester.drag(canvas, const Offset(220, 0));
      await tester.pump();
      expect(find.text('000.png'), findsOneWidget);
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), 2);
      await tester.drag(canvas, const Offset(-220, 0));
      await tester.pump();
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '000.png',
      );
      await tester
          .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
          .onCommand(RemoteCommand(1, 'back', null, null, null, () => true));
      await tester.pump();
      expect(find.byType(AlbumViewer), findsOneWidget);
      expect(transform(tester).value.getMaxScaleOnAxis(), 1);
      await tester.drag(canvas, const Offset(0, -220));
      await tester.pump();
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await tester.drag(canvas, const Offset(0, 180));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byType(AlbumViewer), findsNothing);
      expect(find.text('open viewer'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'drag follows the finger with both photographs and a fixed gap; short drag snaps back',
    (tester) async {
      await mount(tester);
      final canvas = find.byKey(const ValueKey('album-photo-canvas'));
      final resident = tester.state(find.byType(AlbumThumbnail));
      final gesture = await tester.startGesture(tester.getCenter(canvas));
      await gesture.moveBy(
        const Offset(-300, 0),
        timeStamp: const Duration(seconds: 1),
      );
      await tester.pump();
      final current = find.byKey(const ValueKey('album-current-page'));
      final other = find.byKey(const ValueKey('album-other-page'));
      Rect pixels(Finder page) => tester.getRect(
        find.byWidget(tester.widget<FractionalTranslation>(page).child!),
      );
      expect(pixels(current).left, closeTo(-300, .01));
      expect(pixels(other).left - pixels(current).right, closeTo(12, .01));
      expect(find.text('000.png'), findsOneWidget);
      expect(tester.state(find.byType(AlbumThumbnail)), same(resident));
      final held = pixels(current);
      await tester.pump(const Duration(milliseconds: 300));
      expect(pixels(current), held);
      await gesture.up(timeStamp: const Duration(milliseconds: 1400));
      await settle(tester);
      expect(find.text('001.png'), findsOneWidget);
      expect(find.byKey(const ValueKey('album-image-loading')), findsNothing);

      final nextResident = tester.state(find.byType(AlbumThumbnail));
      final short = await tester.startGesture(tester.getCenter(canvas));
      await short.moveBy(
        const Offset(-65, 0),
        timeStamp: const Duration(seconds: 1),
      );
      await tester.pump();
      expect(pixels(current).left, closeTo(-65, .01));
      await short.up(timeStamp: const Duration(milliseconds: 1400));
      await settle(tester);
      expect(find.text('001.png'), findsOneWidget);
      expect(pixels(current).left, closeTo(0, .01));
      expect(tester.state(find.byType(AlbumThumbnail)), same(nextResident));
      expect(other, findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('cancel and background discard a held page without advancing', (
    tester,
  ) async {
    await mount(tester);
    final canvas = find.byKey(const ValueKey('album-photo-canvas'));
    final resident = tester.state(find.byType(AlbumThumbnail));
    final cancelled = await tester.startGesture(tester.getCenter(canvas));
    await cancelled.moveBy(const Offset(-300, 0));
    await tester.pump();
    await cancelled.cancel();
    await settle(tester);
    expect(find.text('000.png'), findsOneWidget);
    expect(tester.state(find.byType(AlbumThumbnail)), same(resident));

    final held = await tester.startGesture(tester.getCenter(canvas));
    await held.moveBy(const Offset(-300, 0));
    await tester.pump();
    final images = tester
        .widget<AlbumThumbnail>(find.byType(AlbumThumbnail))
        .service;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Do not pump: Android can stop delivering frames immediately on pause.
    expect(images.active, isFalse);
    final animation =
        tester
                .widget<AnimatedBuilder>(
                  find.byKey(const ValueKey('album-photo-transition')),
                )
                .animation
            as AnimationController;
    expect(animation.isAnimating, isFalse);
    await held.up();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    expect(images.pendingCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(find.text('000.png'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('album-current-page'))).left,
      closeTo(0, .01),
    );
    expect(tester.state(find.byType(AlbumThumbnail)), same(resident));
    await unmount(tester);
  });

  testWidgets(
    'pinch never changes image and remote navigation/zoom still works',
    (tester) async {
      await mount(tester);
      final first = await tester.startGesture(
        const Offset(330, 300),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(470, 300),
        pointer: 2,
      );
      await first.moveTo(const Offset(220, 300));
      await second.moveTo(const Offset(580, 300));
      await tester.pump();
      await second.up();
      await first.up();
      await tester.pump();
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '000.png',
      );
      final target = tester.widget<RemoteControlTarget>(
        find.byType(RemoteControlTarget),
      );
      Future<RemoteCommandResult?> command(String action) async => await target
          .onCommand(RemoteCommand(1, action, null, null, null, () => true));
      expect((await command('next'))!.ok, isTrue);
      await tester.pump();
      expect(find.text('001.png'), findsOneWidget);
      expect(transform(tester).value.getMaxScaleOnAxis(), 1);
      expect((await command('up'))!.ok, isTrue);
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), 2);
      expect((await command('down'))!.ok, isTrue);
      await tester.pump();
      expect(transform(tester).value.getMaxScaleOnAxis(), 1);
      await unmount(tester);
    },
  );

  testWidgets(
    'manual slideshow paging keeps physical spacing through the release snap',
    (tester) async {
      await mount(tester);
      await tester
          .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
          .onCommand(RemoteCommand(1, 'play', null, null, null, () => true));
      await tester.pump();
      final canvas = find.byKey(const ValueKey('album-photo-canvas'));
      final gesture = await tester.startGesture(tester.getCenter(canvas));
      await gesture.moveBy(
        const Offset(-300, 0),
        timeStamp: const Duration(seconds: 1),
      );
      await tester.pump();
      await gesture.up(timeStamp: const Duration(milliseconds: 1400));
      await tester.pump(const Duration(milliseconds: 100));
      final current = find.byKey(const ValueKey('album-current-page'));
      final outgoing = find.byKey(const ValueKey('album-other-page'));
      Rect page(Finder finder) => tester.getRect(
        find.byWidget(tester.widget<FractionalTranslation>(finder).child!),
      );
      expect(page(current).left - page(outgoing).right, closeTo(12, .01));
      expect(
        tester
            .widgetList<Opacity>(find.byType(Opacity))
            .every((opacity) => opacity.opacity == 1),
        isTrue,
      );
      await settle(tester);
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      await unmount(tester);
    },
  );

  for (final cancel in [true, false]) {
    testWidgets(
      'slideshow continues after ${cancel ? 'a cancelled drag' : 'both pinch pointers release'}',
      (tester) async {
        await mount(tester);
        await tester
            .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
            .onCommand(RemoteCommand(1, 'play', null, null, null, () => true));
        await tester.pump();
        final first = await tester.startGesture(
          const Offset(330, 300),
          pointer: 1,
        );
        if (cancel) {
          await first.moveBy(const Offset(-100, 0));
          await tester.pump();
          await first.cancel();
        } else {
          final second = await tester.startGesture(
            const Offset(470, 300),
            pointer: 2,
          );
          await first.moveTo(const Offset(280, 300));
          await second.moveTo(const Offset(520, 300));
          await tester.pump();
          await first.up();
          await tester.pump(const Duration(seconds: 6));
          expect(
            tester
                .widget<AlbumThumbnail>(find.byType(AlbumThumbnail))
                .entry
                .name,
            '000.png',
            reason: 'Slideshow must wait while the remaining finger is held.',
          );
          await second.up();
        }
        await tester.pump(const Duration(seconds: 5));
        expect(
          tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
          '001.png',
        );
        await unmount(tester);
      },
    );
  }

  for (final keyboard in [false, true]) {
    testWidgets(
      '${keyboard ? 'keyboard' : 'remote'} navigation cancels a held drag before its next move',
      (tester) async {
        await mount(tester);
        final canvas = find.byKey(const ValueKey('album-photo-canvas'));
        final gesture = await tester.startGesture(tester.getCenter(canvas));
        await gesture.moveBy(const Offset(-250, 0));
        await tester.pump();
        if (keyboard) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        } else {
          await tester
              .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
              .onCommand(
                RemoteCommand(1, 'next', null, null, null, () => true),
              );
        }
        await tester.pump(const Duration(milliseconds: 30));
        await gesture.moveBy(const Offset(-60, 0));
        await tester.pump(const Duration(milliseconds: 30));
        expect(tester.takeException(), isNull);
        await gesture.up();
        await settle(tester);
        expect(
          tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
          '001.png',
        );
        expect(find.byKey(const ValueKey('album-other-page')), findsNothing);
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'paging preloads neighbors and pauses transitions without a frame',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = raster.encodePng(raster.Image(width: 96, height: 64));
        for (final item in snapshot.items) {
          await File(item.preferred.path).writeAsBytes(bytes);
        }
      });
      await mount(tester);
      final images = tester
          .widget<AlbumThumbnail>(find.byType(AlbumThumbnail))
          .service;
      final next = snapshot.items[snapshot.nextMediaIndex[0]!].preferred;
      for (
        var attempt = 0;
        attempt < 200 && images.peek(next)?.path == null;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(images.peek(next)?.path, isNotNull);
      expect(images.pendingCount, lessThanOrEqualTo(3));
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(-220, 0),
      );
      await tester.pump();
      final animation =
          tester
                  .widget<AnimatedBuilder>(
                    find.byKey(const ValueKey('album-photo-transition')),
                  )
                  .animation
              as AnimationController;
      expect(animation.isAnimating, isTrue);
      await tester.pump(const Duration(milliseconds: 120));
      expect(animation.value, inExclusiveRange(0, 1));
      final movingFrames = find.descendant(
        of: find.byKey(const ValueKey('album-photo-transition')),
        matching: find.byType(FractionalTranslation),
      );
      expect(movingFrames, findsNWidgets(2));
      final offsets = tester
          .widgetList<FractionalTranslation>(movingFrames)
          .map((frame) => frame.translation)
          .toList();
      expect(offsets[0].dy, 0);
      expect(offsets[1].dy, 0);
      expect(
        offsets[1].dx - offsets[0].dx,
        closeTo(
          1 +
              12 /
                  tester
                      .getSize(find.byKey(const ValueKey('album-photo-canvas')))
                      .width,
          .001,
        ),
      );
      expect(
        tester
            .widgetList<Opacity>(
              find.descendant(
                of: find.byKey(const ValueKey('album-photo-transition')),
                matching: find.byType(Opacity),
              ),
            )
            .every((frame) => frame.opacity == 1),
        isTrue,
      );
      expect(find.text(next.name), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(animation.isAnimating, isFalse);
      expect(animation.value, 1);
      expect(images.active, isFalse);
      final pending = images.pendingCount;
      // No pump: background suspension must take effect directly from lifecycle.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.idle();
      expect(images.pendingCount, lessThanOrEqualTo(pending));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(images.active, isTrue);
      expect(find.text(next.name), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'disabled motion switches photos without an outgoing frame or ticker',
    (tester) async {
      for (final settings in [(false, false), (true, true)]) {
        await mount(
          tester,
          motionEnabled: settings.$1,
          disableAnimations: settings.$2,
        );
        final target = tester.widget<RemoteControlTarget>(
          find.byType(RemoteControlTarget),
        );
        await target.onCommand(
          RemoteCommand(1, 'next', null, null, null, () => true),
        );
        await tester.pump();
        final transition = find.byKey(const ValueKey('album-photo-transition'));
        final animation =
            tester.widget<AnimatedBuilder>(transition).animation
                as AnimationController;
        expect(animation.isAnimating, isFalse);
        expect(animation.value, 1);
        expect(find.text('001.png'), findsOneWidget);
        expect(
          find.descendant(
            of: transition,
            matching: find.byType(FractionalTranslation),
          ),
          findsOneWidget,
        );
        await unmount(tester);
      }
    },
  );

  testWidgets(
    'info is compact and omits unknown original dimensions and secret URI fields',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumPhotoInfoSheet(
              entry: const SourceEntry(
                name: '001.arw',
                path: 'https://user:secret@example.com/album/001.arw?token=hidden',
                size: 2048,
              ),
              source: const {
                'kind': 'webdav',
                'label': 'NAS',
                'password': 'source-secret',
              },
              result: const AlbumImageResult(
                width: 320,
                height: 240,
                previewOnly: true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('尺寸'), findsNothing);
      expect(find.text('拍摄时间'), findsNothing);
      expect(find.text('修改时间'), findsNothing);
      expect(find.text('320 × 240'), findsNothing);
      expect(find.text('https://example.com/album/001.arw'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('media-parameters-more')));
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/album/001.arw'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(find.textContaining('hidden'), findsNothing);
      expect(find.text('导出'), findsNothing);
      expect(find.text('2.0 KB'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('information uses prepared source dimensions and capture date', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlbumPhotoInfoSheet(
            entry: const SourceEntry(name: '001.jpg', path: '/photos/001.jpg'),
            source: const {'kind': 'local'},
            result: const AlbumImageResult(
              width: 600,
              height: 400,
              metadata: AlbumFileMetadata(
                width: 6000,
                height: 4000,
                capturedAt: 1000,
              ),
              captureTimeRaw: '2024:06:07 08:09:10',
              exif: {'相机': 'Sony ILCE-7M4', '光圈': 'f/2.8', 'ISO': '400'},
            ),
          ),
        ),
      ),
    );
    expect(find.text('6000 × 4000'), findsOneWidget);
    expect(find.text('600 × 400'), findsNothing);
    expect(find.text('2024:06:07 08:09:10'), findsOneWidget);
    expect(find.text('Sony ILCE-7M4'), findsOneWidget);
    expect(find.text('F2.8'), findsOneWidget);
    expect(find.text('400'), findsOneWidget);
    expect(find.text('大小'), findsNothing);
    await unmount(tester);
  });

  testWidgets('desktop slideshow owns fullscreen until stop or background', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    const channel = MethodChannel('app.aiplayer/window_mode');
    final fullscreen = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setVideoFullscreen') {
        final enabled = (call.arguments as Map)['enabled'] as bool;
        fullscreen.add(enabled);
        return enabled;
      }
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    try {
      await mount(tester);
      final remote = tester.widget<RemoteControlTarget>(
        find.byType(RemoteControlTarget),
      );
      Future<void> command(String action) async {
        await remote.onCommand(
          RemoteCommand(1, action, null, null, null, () => true),
        );
        await tester.idle();
      }

      await command('play');
      expect(fullscreen, [true]);
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      expect(fullscreen, [true]);
      await command('pause');
      expect(fullscreen, [true, false]);
      await command('play');
      expect(fullscreen, [true, false, true]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.idle();
      expect(fullscreen, [true, false, true, false]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.idle();
      expect(fullscreen, [true, false, true, false]);
      await unmount(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'mobile slideshow groups orientation and settings in the revealed top toolbar',
    (tester) async {
      final orientations = <List<dynamic>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientations.add(call.arguments as List<dynamic>);
          }
          return null;
        },
      );
      await mount(tester);
      final remote = tester.widget<RemoteControlTarget>(
        find.byType(RemoteControlTarget),
      );
      await remote.onCommand(
        RemoteCommand(1, 'play', null, null, null, () => true),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      final button = find.byKey(const ValueKey('album-slideshow-orientation'));
      expect(button, findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump();
      expect(button, findsOneWidget);
      expect(
        find.ancestor(
          of: button,
          matching: find.byKey(const ValueKey('album-viewer-toolbar')),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('幻灯片'), findsOneWidget);
      expect(tester.getSize(button), const Size(40, 40));
      expect(find.byTooltip('切换竖屏'), findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      await tester.idle();
      expect(orientations.last, [
        'DeviceOrientation.portraitUp',
        'DeviceOrientation.portraitDown',
      ]);
      expect(find.byTooltip('切换横屏'), findsOneWidget);
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        Colors.black,
      );
      expect(button, findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      await tester.idle();
      expect(orientations.last, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.idle();
      expect(orientations.last, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(button, findsNothing);
      expect(orientations.last, isEmpty);
      await unmount(tester);
    },
  );

  testWidgets(
    '320px mobile toolbar and slideshow settings keep every control reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () =>
            File('${directory.path}/000.png').copy('${directory.path}/000.jpg'),
      );
      snapshot = AlbumIndex(
        [
          for (final item in snapshot.items) ...item.members,
          SourceEntry(name: '000.jpg', path: '${directory.path}/000.jpg'),
        ],
        sourceId: 'local',
        directory: directory.path,
      ).filter(AlbumOptions());
      await mount(tester);
      await tester
          .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
          .onCommand(RemoteCommand(1, 'play', null, null, null, () => true));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump();
      void reachable(Finder control) {
        final bounds = tester.getRect(control);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(320));
        expect(bounds.height, greaterThanOrEqualTo(40));
      }

      for (final control in [
        find.byType(BackButton),
        find.byTooltip('选择格式'),
        find.byTooltip('照片信息'),
        find.byKey(const ValueKey('album-slideshow-orientation')),
        find.byKey(const ValueKey('album-slideshow-settings')),
        find.byTooltip('更多选项'),
      ]) {
        reachable(control);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('album-slideshow-settings')));
      await settle(tester);
      final interval = find.byKey(const ValueKey('album-slideshow-interval'));
      final transition = find.byKey(
        const ValueKey('album-slideshow-transition'),
      );
      for (final control in [interval, transition]) {
        final bounds = tester.getRect(control);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(320));
      }
      await tester.tap(interval);
      await tester.pumpAndSettle();
      await tester.tap(find.text('3 秒').last);
      await tester.pumpAndSettle();
      await tester.tap(transition);
      await tester.pumpAndSettle();
      await tester.tap(find.text('推拉').last);
      await tester.pumpAndSettle();
      expect(model.preferences.albumSlideshowSeconds, 3);
      expect(model.preferences.albumSlideshowTransition, 'slide');
      await tester.tap(find.byKey(const ValueKey('album-slideshow-exit')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('album-slideshow-settings')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  testWidgets(
    'slideshow menu pauses advance, persists options and exits slideshow',
    (tester) async {
      await mount(tester);
      await tester
          .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
          .onCommand(RemoteCommand(1, 'play', null, null, null, () => true));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('幻灯片'));
      await settle(tester);
      expect(find.text('幻灯片设置'), findsOneWidget);
      expect(tester.getSize(find.byType(BottomSheet)).height, lessThan(300));
      await tester.pump(const Duration(seconds: 6));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '000.png',
      );
      await tester.tap(find.byKey(const ValueKey('album-slideshow-interval')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 秒').last);
      await tester.pumpAndSettle();
      expect(model.preferences.albumSlideshowSeconds, 10);
      await tester.tap(
        find.byKey(const ValueKey('album-slideshow-transition')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('无').last);
      await tester.pumpAndSettle();
      expect(model.preferences.albumSlideshowTransition, 'none');
      final resumedAt = tester.binding.clock.now();
      await tester.tap(find.byTooltip('关闭幻灯片设置'));
      await settle(tester);
      // Worker I/O in settle may advance the fake clock. Assert the interval
      // from the close event, rather than adding that I/O time to nine seconds.
      await tester.pump(
        const Duration(seconds: 9) -
            tester.binding.clock.now().difference(resumedAt),
      );
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '000.png',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      final animation =
          tester
                  .widget<AnimatedBuilder>(
                    find.byKey(const ValueKey('album-photo-transition')),
                  )
                  .animation
              as AnimationController;
      expect(animation.isAnimating, isFalse);
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('幻灯片'));
      await settle(tester);
      expect(
        tester
            .widget<DropdownButton<int>>(
              find.byKey(const ValueKey('album-slideshow-interval')),
            )
            .value,
        10,
      );
      await tester.tap(find.text('退出幻灯片模式'));
      await settle(tester);
      expect(find.byTooltip('幻灯片'), findsNothing);
      expect(
        find.byKey(const ValueKey('album-slideshow-orientation')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 11));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    'dismissing during a slow settings save applies the committed interval',
    (tester) async {
      model.dispose();
      final delayed = _DelayedSlideshowPreferences(store, directory);
      model = delayed;
      await mount(tester);
      await tester
          .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
          .onCommand(RemoteCommand(1, 'play', null, null, null, () => true));
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('幻灯片'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('album-slideshow-interval')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 秒').last);
      await tester.pumpAndSettle();
      expect(model.preferences.albumSlideshowSeconds, 5);
      final resumedAt = tester.binding.clock.now();
      await tester.tap(find.byTooltip('关闭幻灯片设置'));
      await settle(tester);
      await tester.pump(
        const Duration(seconds: 4) -
            tester.binding.clock.now().difference(resumedAt),
      );
      delayed.save.complete();
      await tester.pump();
      await tester.idle();
      expect(model.preferences.albumSlideshowSeconds, 10);
      await tester.pump(const Duration(seconds: 2));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '000.png',
      );
      await tester.pump(const Duration(seconds: 8));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      await unmount(tester);
    },
  );

  testWidgets('backgrounding an open slideshow menu never resumes its timer', (
    tester,
  ) async {
    await mount(tester);
    await tester
        .widget<RemoteControlTarget>(find.byType(RemoteControlTarget))
        .onCommand(RemoteCommand(1, 'play', null, null, null, () => true));
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('album-photo-canvas')),
      const Offset(0, 180),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('幻灯片'));
    await settle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Android can stop drawing immediately. Cancellation must not require pump.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.byTooltip('关闭幻灯片设置'));
    await settle(tester);
    expect(find.byTooltip('幻灯片'), findsNothing);
    await tester.pump(const Duration(seconds: 7));
    expect(
      tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
      '000.png',
    );
    await unmount(tester);
  });

  testWidgets(
    'rotated slideshow waits for the original viewport before return',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      final remote = tester.widget<RemoteControlTarget>(
        find.byType(RemoteControlTarget),
      );
      await remote.onCommand(
        RemoteCommand(1, 'play', null, null, null, () => true),
      );
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('切换横屏'));
      await tester.pump();
      tester.view.physicalSize = const Size(800, 600);
      await tester.pump();
      await remote.onCommand(
        RemoteCommand(1, 'back', null, null, null, () => true),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(AlbumViewer), findsOneWidget);
      tester.view.physicalSize = const Size(600, 800);
      await settle(tester);
      expect(find.byType(AlbumViewer), findsNothing);
      expect(find.text('open viewer'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'slideshow reveal honors control timeout and pause cancels it without a frame',
    (tester) async {
      await tester.runAsync(
        () => model.updatePreferences({'controlsHideSeconds': 3}),
      );
      await mount(tester);
      final remote = tester.widget<RemoteControlTarget>(
        find.byType(RemoteControlTarget),
      );
      await remote.onCommand(
        RemoteCommand(1, 'play', null, null, null, () => true),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // No pump after pause: both the slideshow and control timer must cancel
      // directly, before Android stops delivering frames.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.idle();
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('000.png'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 4));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '000.png',
      );
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    'zero control timeout keeps revealed slideshow controls visible',
    (tester) async {
      await tester.runAsync(
        () => model.updatePreferences({'controlsHideSeconds': 0}),
      );
      await mount(tester);
      final remote = tester.widget<RemoteControlTarget>(
        find.byType(RemoteControlTarget),
      );
      await remote.onCommand(
        RemoteCommand(1, 'play', null, null, null, () => true),
      );
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('album-photo-canvas')),
        const Offset(0, 180),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(seconds: 6));
      expect(
        find.byKey(const ValueKey('album-viewer-toolbar')),
        findsOneWidget,
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'overflow starts slideshow; paused without a frame stops image work and advance',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mount(tester);
      await tester.tap(find.byTooltip('更多选项'));
      await settle(tester);
      expect(find.text('开始幻灯片'), findsOneWidget);
      expect(find.text('放大'), findsNothing);
      expect(find.text('黑色背景'), findsNothing);
      await tester.tap(find.text('开始幻灯片'));
      await settle(tester);
      expect(find.byKey(const ValueKey('album-viewer-toolbar')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      final images = tester
          .widget<AlbumThumbnail>(find.byType(AlbumThumbnail))
          .service;
      expect(images.active, isTrue);
      expect(
        calls.any(
          (call) =>
              call.method == 'SystemChrome.setEnabledSystemUIMode' &&
              call.arguments == 'SystemUiMode.immersiveSticky',
        ),
        isTrue,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(images.active, isFalse);
      await tester.idle();
      expect(
        calls.any(
          (call) =>
              call.method == 'SystemChrome.setEnabledSystemUIOverlays' &&
              (call.arguments as List).contains('SystemUiOverlay.top'),
        ),
        isTrue,
        reason: calls
            .map((call) => '${call.method}: ${call.arguments}')
            .join('\n'),
      );
      await tester.pump(const Duration(seconds: 6));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 6));
      expect(
        tester.widget<AlbumThumbnail>(find.byType(AlbumThumbnail)).entry.name,
        '001.png',
      );
      expect(images.active, isTrue);
      await unmount(tester);
    },
  );
}
