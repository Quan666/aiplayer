import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/continue_watching_presentation.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/ui/artwork_scroll_scope.dart';
import 'package:aiplayer/ui/continue_watching_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Model extends AppModel {
  _Model(AppStore store)
    : super(store, Directory.systemTemp, backgroundWork: false);
  var revision = 0;
  final requests = <Completer<Map<String, ContinueWatchingPresentation>>>[];
  final tokens = <CancelToken>[];
  @override
  Object get continueWatchingPresentationRevision => revision;
  @override
  Future<Map<String, ContinueWatchingPresentation>>
  loadContinueWatchingPresentations(
    List<SyncRecord> items, {
    CancelToken? cancel,
  }) {
    tokens.add(cancel!);
    final request = Completer<Map<String, ContinueWatchingPresentation>>();
    requests.add(request);
    return request.future;
  }

  void update({bool relevant = true}) {
    if (relevant) revision++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late _Model model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = AppStore(':memory:');
    model = _Model(store);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
  });

  Map<String, ContinueWatchingPresentation> view(String title) => {
    'a': ContinueWatchingPresentation(
      title: title,
      episode: '',
      thumbnail: null,
      position: 10,
      duration: 100,
      originDeviceId: '',
      originDeviceName: '',
      originDevicePlatform: '',
      remoteDeviceName: '',
      preparationIsolate: 0,
    ),
  };

  Widget surface({bool active = true, bool scrolling = false}) => MaterialApp(
    home: Scaffold(
      body: TickerMode(
        enabled: active,
        child: ArtworkScrollScope(
          child: Builder(
            builder: (context) {
              final content = ContinueWatchingContent(
                model: model,
                items: const [],
                builder: (_, views) => SizedBox(
                  height: scrolling ? 1200 : 100,
                  child: Text(views['a']?.title ?? 'loading'),
                ),
              );
              return scrolling ? ListView(children: [content]) : content;
            },
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'irrelevant updates preserve active read, hidden updates coalesce',
    (tester) async {
      await tester.pumpWidget(surface());
      expect(model.requests, hasLength(1));
      model.update(relevant: false);
      await tester.pump();
      expect(model.requests, hasLength(1));
      expect(model.tokens.first.cancelled, isFalse);
      model.requests.first.complete(view('ready'));
      await tester.pumpAndSettle();
      expect(find.text('ready'), findsOneWidget);
      await tester.pumpWidget(surface(active: false));
      for (var i = 0; i < 20; i++) {
        model.update();
      }
      await tester.pump();
      expect(model.requests, hasLength(1));
      await tester.pumpWidget(surface());
      expect(model.requests, hasLength(2));
      model.requests.last.complete(view('current'));
      await tester.pumpAndSettle();
      expect(find.text('current'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('scrolling defers presentation updates and refreshes once idle', (
    tester,
  ) async {
    await tester.pumpWidget(surface(scrolling: true));
    model.requests.first.complete(view('ready'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 30));
    for (var i = 0; i < 20; i++) {
      model.update();
    }
    await tester.pump();
    expect(model.requests, hasLength(1));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(model.requests, hasLength(2));
    model.requests.last.complete(view('current'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden and disposed surfaces ignore late presentation results', (
    tester,
  ) async {
    await tester.pumpWidget(surface());
    await tester.pumpWidget(surface(active: false));
    expect(model.tokens.first.cancelled, isTrue);
    model.requests.first.complete(view('stale'));
    await tester.pump();
    expect(find.text('stale'), findsNothing);
    await tester.pumpWidget(surface());
    expect(model.requests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    expect(model.tokens.last.cancelled, isTrue);
    model.requests.last.complete(view('late'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
