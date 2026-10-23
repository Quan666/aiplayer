import 'dart:io';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/preferences.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('high refresh defaults on but respects saved opt-out', () {
    expect(AppPreferences({}).highRefreshRate, true);
    expect(AppPreferences({'highRefreshRate': false}).highRefreshRate, false);
    expect(AppPreferences({'highRefreshRate': 'bad'}).highRefreshRate, true);
  });

  testWidgets(
    'app-wide refresh preference applies on library and only changes with the setting',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterSecureStorage.setMockInitialValues({});
      const channel = MethodChannel('app.aiplayer/display');
      final requests = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'setHighRefreshRate') {
          requests.add(call.arguments as bool);
        }
        return null;
      });
      final directory = Directory.systemTemp.createTempSync(
        'aiplayer-refresh-',
      );
      final store = AppStore(':memory:')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final model = AppModel(store, directory);
      try {
        await tester.pumpWidget(AIPlayerApp(model: model));
        await tester.pumpAndSettle();
        expect(find.text('我的影视库'), findsOneWidget);
        expect(requests, [true]);
        model.changed();
        await tester.pump();
        expect(requests, [true]);
        await model.updatePreferences({'highRefreshRate': false});
        await tester.pump();
        expect(requests, [true, false]);
        await model.updatePreferences({'highRefreshRate': true});
        await tester.pump();
        expect(requests, [true, false, true]);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
