import 'dart:async';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/text_file_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _paths = MethodChannel('plugins.flutter.io/path_provider');

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var count = 0; count < 200 && !ready(); count++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

class _RemoteFile {
  final Directory root;
  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final Completer<void> started, release;
  final List<String> requests;

  _RemoteFile(
    this.root,
    this.server,
    this.subscription,
    this.started,
    this.release,
    this.requests,
  );

  static Future<_RemoteFile> create({bool stall = false}) async {
    final root = await Directory.systemTemp.createTemp('external-file-page-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>(), release = Completer<void>();
    final requests = <String>[];
    if (!stall) release.complete();
    final subscription = server.listen((request) async {
      requests.add(request.method);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.contentLength = 1024;
      try {
        if (request.method != 'HEAD') {
          request.response.add(List.filled(64, 65));
          await request.response.flush();
          if (!started.isCompleted) started.complete();
          await release.future;
          request.response.add(List.filled(960, 65));
        }
        await request.response.close();
      } catch (_) {
        // A lifecycle cancellation intentionally closes the client connection.
      }
    });
    return _RemoteFile(root, server, subscription, started, release, requests);
  }

  Map<String, dynamic> get source => {
    'id': 'remote',
    'kind': 'webdav',
    'url': 'http://127.0.0.1:${server.port}/',
  };

  Directory get cache => Directory('${root.path}/aiplayer-external-files-v1');

  Future<bool> get cacheEmpty async =>
      !await cache.exists() || await cache.list().isEmpty;

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await subscription.cancel();
    await server.close(force: true);
    await root.delete(recursive: true);
  }
}

Future<GlobalKey<NavigatorState>> _show(
  WidgetTester tester,
  _RemoteFile remote,
  Future<void> Function(String) opener,
) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_paths, (_) async => remote.root.path);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('home')),
    ),
  );
  unawaited(
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => ExternalFilePage(
          source: remote.source,
          documentsPath: remote.root.path,
          entry: const SourceEntry(name: 'report.pdf', path: 'report.pdf'),
          opener: opener,
        ),
      ),
    ),
  );
  await tester.pump();
  return navigator;
}

Future<void> _close(WidgetTester tester, _RemoteFile remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(remote.close);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_paths, null);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('successful handoff retains the copy after the page closes', (
    tester,
  ) async {
    final remote = (await tester.runAsync(_RemoteFile.create))!;
    String? opened;
    try {
      await _show(tester, remote, (path) async => opened = path);
      await _until(tester, () => opened != null);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ExternalFilePage), findsNothing);
      expect(await tester.runAsync(() => File(opened!).length()), 1024);
      expect(remote.requests, ['HEAD', 'GET']);
    } finally {
      await _close(tester, remote);
    }
  });

  testWidgets('failed late handoff deletes the copy after the page is popped', (
    tester,
  ) async {
    final remote = (await tester.runAsync(_RemoteFile.create))!;
    final handoff = Completer<void>();
    String? opened;
    var deleted = false;
    try {
      final navigator = await _show(tester, remote, (path) {
        opened = path;
        return handoff.future;
      });
      await _until(tester, () => opened != null);
      navigator.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 400));
      handoff.completeError(const AppFailure('没有可打开此文件的应用。'));
      for (var count = 0; count < 200 && !deleted; count++) {
        deleted = (await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return !await File(opened!).exists();
        }))!;
        await tester.pump();
      }
      expect(deleted, isTrue);
      expect(find.text('home'), findsOneWidget);
    } finally {
      if (!handoff.isCompleted) handoff.complete();
      await _close(tester, remote);
    }
  });

  testWidgets('paused without pumping cancels partial download then resumes', (
    tester,
  ) async {
    final remote = (await tester.runAsync(
      () => _RemoteFile.create(stall: true),
    ))!;
    var opened = 0;
    try {
      await _show(tester, remote, (_) async => opened++);
      await _until(tester, () => remote.started.isCompleted);
      // The route transition has its own ticker; measure the loading indicator
      // only after that transition reports completion.
      final route = ModalRoute.of(
        tester.element(find.byType(ExternalFilePage)),
      )!;
      await _until(tester, () => route.animation!.isCompleted);
      final requests = remote.requests.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      var cleaned = false;
      for (var count = 0; count < 200 && !cleaned; count++) {
        // Let asynchronous completions run, without drawing a frame.
        await tester.idle();
        cleaned = (await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return remote.cacheEmpty;
        }))!;
      }
      // No pump has occurred after paused: worker cancellation and cleanup
      // cannot depend on Flutter producing another frame.
      expect(tester.binding.transientCallbackCount, 0);
      expect(
        cleaned,
        isTrue,
        reason: await tester.runAsync(
          () async => (await remote.cache.exists())
              ? (await remote.cache.list(recursive: true).toList())
                    .map((entry) => entry.path)
                    .join(', ')
              : 'cache missing',
        ),
      );
      expect(remote.requests.length, requests);
      expect(opened, 0);
      remote.release.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(opened, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _until(tester, () => opened == 1);
      expect(remote.requests.length, greaterThan(requests));
    } finally {
      await _close(tester, remote);
    }
  });

  testWidgets('late successful handoff does not pop an overlay route', (
    tester,
  ) async {
    final remote = (await tester.runAsync(_RemoteFile.create))!;
    final handoff = Completer<void>();
    String? opened;
    try {
      final navigator = await _show(tester, remote, (path) {
        opened = path;
        return handoff.future;
      });
      await _until(tester, () => opened != null);
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('overlay')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      handoff.complete();
      await _until(
        tester,
        () => find.byType(ExternalFilePage).evaluate().isEmpty,
      );
      expect(find.text('overlay'), findsOneWidget);
      expect(await tester.runAsync(() => File(opened!).exists()), isTrue);
    } finally {
      if (!handoff.isCompleted) handoff.complete();
      await _close(tester, remote);
    }
  });
}
