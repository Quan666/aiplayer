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
  test('system refresh defaults on and respects explicit high refresh', () {
    expect(AppPreferences({}).highRefreshRate, false);
    expect(AppPreferences({'highRefreshRate': false}).highRefreshRate, false);
    expect(AppPreferences({'highRefreshRate': true}).highRefreshRate, true);
    expect(AppPreferences({'highRefreshRate': 'bad'}).highRefreshRate, false);
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
        expect(requests, [false]);
        model.changed();
        await tester.pump();
        expect(requests, [false]);
        await model.updatePreferences({'highRefreshRate': true});
        await tester.pump();
        expect(requests, [false, true]);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(requests, [false, true, false]);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(requests, [false, true, false, true]);
        await model.updatePreferences({'highRefreshRate': false});
        await tester.pump();
        expect(requests, [false, true, false, true, false]);
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
