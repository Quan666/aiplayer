import 'dart:io';
import 'dart:ui' as ui;

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Run with flutter drive --profile -d linux and
// --driver=test_driver/artwork_performance_driver.dart. The explicit Android
// theme selects Flutter's real predictive-back transition on the native host.
// Supply HISTORY_RETURN_ARTIFACT_DIR to capture the bundled font and each
// gesture stage before asserting on framework errors. This is layout coverage,
// not Android device performance or native gesture-delivery validation.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native Android history survives predictive system back', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf'));
    await font.load();
    final directory = await Directory.systemTemp.createTemp('history-back-');
    final store = AppStore(':memory:');
    final model = AppModel(
      store,
      directory,
      backgroundWork: false,
      enableThumbnails: false,
    );
    final boundaryKey = GlobalKey();
    final errors = <String>[];
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 24; i++) {
      store.save('media', '$i', {
        'title': '作品 $i.mkv',
        'series': '作品 $i',
        'season': '1',
        'episode': '1',
        'size': 100,
        'poster': '${directory.path}/poster-$i.jpg',
      });
      store.save('progress', '$i:100', {
        'position': 12,
        'duration': 1425,
        'updatedAt': DateTime.utc(2026, 10, 24, 0, i).toIso8601String(),
      });
    }

    void recordError(String stage) {
      final error = tester.takeException();
      if (error != null) {
        errors.add('$stage: $error');
        debugPrint('HISTORY_BACK_ERROR $stage: $error');
      }
    }

    Future<void> capture(String stage) async {
      const path = String.fromEnvironment('HISTORY_RETURN_ARTIFACT_DIR');
      if (path.isEmpty) return;
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final artifacts = Directory(path);
      await artifacts.create(recursive: true);
      await File('${artifacts.path}/predictive-$stage.png').writeAsBytes(
        bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    }

    Future<void> backEvent(String method, [double? progress]) async {
      // This is an incoming OS message. Calling MethodChannel.invokeMethod
      // would send it in the opposite direction and require an Android host.
      final response = await tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(
            'flutter/backgesture',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(
                method,
                progress == null
                    ? null
                    : {
                        'touchOffset': <double>[5 + progress * 250, 300],
                        'progress': progress,
                        'swipeEdge': 0,
                      },
              ),
            ),
            (_) {},
          );
      if (method == 'startBackGesture') {
        expect(response, isNotNull);
        expect(const StandardMethodCodec().decodeEnvelope(response!), isTrue);
      }
      await tester.pump();
      recordError(method);
    }

    final history = find.byKey(const PageStorageKey('library-history-grid'));
    final carousel = find.byKey(
      const PageStorageKey('library-continue-scroll'),
    );
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            theme: GlassPalette.theme().copyWith(
              platform: TargetPlatform.android,
            ),
            home: LibraryPage(model: model),
          ),
        ),
      );
      await tester.pumpAndSettle();
      recordError('initial');
      await capture('initial');
      final header = tester.getRect(find.text('全部视频'));
      for (var visit = 0; visit < 3; visit++) {
        await tester.tap(find.text('继续观看'));
        await tester.pumpAndSettle();
        recordError('opened-$visit');
        expect(history, findsOneWidget);
        final route = ModalRoute.of(tester.element(history))!;
        await backEvent('startBackGesture', 0);
        expect(route.navigator!.userGestureInProgress, isTrue);
        await capture('started-$visit');
        await backEvent('updateBackGestureProgress', .35);
        await capture('dragged-$visit');
        await backEvent('cancelBackGesture');
        await tester.pumpAndSettle();
        recordError('cancel-settled-$visit');
        await capture('canceled-$visit');
        expect(history, findsOneWidget);
        await backEvent('startBackGesture', 0);
        await backEvent('updateBackGestureProgress', .6);
        await backEvent('commitBackGesture');
        await tester.pumpAndSettle();
        recordError('commit-settled-$visit');
        await capture('returned-$visit');
        expect(errors, isEmpty);
        expect(history, findsNothing);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(find.text('全部视频').hitTestable(), findsOneWidget);
        expect(tester.getRect(find.text('全部视频')), header);
        final progress = find.descendant(
          of: carousel,
          matching: find.byType(LinearProgressIndicator),
        );
        expect(progress, findsWidgets);
        for (final element in progress.evaluate()) {
          expect(tester.getSize(find.byWidget(element.widget)).height, 2);
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      await directory.delete(recursive: true);
    }
  });
}
