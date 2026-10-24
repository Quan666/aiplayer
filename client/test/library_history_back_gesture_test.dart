import 'dart:io';

import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Android history survives canceled and committed system back', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = Directory.systemTemp.createTempSync('history-back-');
    final store = AppStore(':memory:');
    final model = AppModel(store, directory, backgroundWork: false);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 24; i++) {
      store.save('media', '$i', {
        'title': '作品 $i.mkv',
        'series': '作品 $i',
        'size': 100,
      });
      store.save('progress', '$i:100', {
        'position': 12,
        'duration': 1425,
        'updatedAt': DateTime.utc(2026, 10, 24, 0, i).toIso8601String(),
      });
    }
    Future<void> backEvent(String method, [double? progress]) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
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
      await tester.pump();
    }

    final history = find.byKey(const PageStorageKey('library-history-grid'));
    final carousel = find.byKey(
      const PageStorageKey('library-continue-scroll'),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassPalette.theme().copyWith(
            platform: TargetPlatform.android,
          ),
          home: LibraryPage(model: model),
        ),
      );
      await tester.pumpAndSettle();
      final header = tester.getRect(find.text('全部视频'));
      for (var visit = 0; visit < 3; visit++) {
        await tester.tap(find.text('继续观看'));
        await tester.pumpAndSettle();
        expect(history, findsOneWidget);
        final route = ModalRoute.of(tester.element(history))!;
        await backEvent('startBackGesture', 0);
        expect(route.navigator!.userGestureInProgress, isTrue);
        await backEvent('updateBackGestureProgress', .35);
        await backEvent('cancelBackGesture');
        await tester.pumpAndSettle();
        expect(history, findsOneWidget);
        await backEvent('startBackGesture', 0);
        await backEvent('updateBackGestureProgress', .6);
        await backEvent('commitBackGesture');
        await tester.pumpAndSettle();
        expect(history, findsNothing);
        expect(tester.takeException(), isNull);
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
        final library = find.byKey(const PageStorageKey('library-scroll'));
        final vertical = tester
            .state<ScrollableState>(
              find
                  .descendant(of: library, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        vertical.jumpTo(500);
        await tester.pumpAndSettle();
        expect(vertical.pixels, 500);
        vertical.jumpTo(0);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.text('全部视频')), header);
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      store.dispose();
      directory.deleteSync(recursive: true);
    }
  });
}
