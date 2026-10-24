import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/ui/glass.dart';
import 'package:aiplayer/ui/library_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

HttpSource _webdav(String address) => HttpOverrides.runWithHttpOverrides(
  () => HttpSource(address, webdav: true),
  _RealHttp(),
);

class _WebDavModel extends AppModel {
  final String address;
  int completedSeriesLoads = 0;
  _WebDavModel(super.store, super.documents, this.address)
    : super(backgroundWork: false);

  @override
  Future<SourceAdapter> adapter(String id) async => _webdav(address);

  @override
  Future<List<SyncRecord>> loadSeriesEpisodes(
    SyncRecord record, {
    CancelToken? cancel,
  }) async {
    final episodes = await super.loadSeriesEpisodes(record, cancel: cancel);
    completedSeriesLoads++;
    return episodes;
  }
}

String _seriesListing(int count) {
  final result = StringBuffer('<d:multistatus xmlns:d="DAV:">');
  result.write(
    '<d:response><d:href>/dav/Series/</d:href>'
    '<d:propstat><d:prop><d:resourcetype><d:collection/>'
    '</d:resourcetype></d:prop></d:propstat></d:response>',
  );
  for (var episode = 1; episode <= count; episode++) {
    final path = Uri(path: '/dav/Series/Example S01E0$episode.mkv');
    result.write(
      '<d:response><d:href>$path</d:href><d:propstat><d:prop>'
      '<d:getcontentlength>42</d:getcontentlength>'
      '<d:resourcetype/></d:prop></d:propstat></d:response>',
    );
  }
  result.write('</d:multistatus>');
  return result.toString();
}

void _writeChunk(Socket socket, String value) {
  final bytes = utf8.encode(value);
  socket.write('${bytes.length.toRadixString(16)}\r\n');
  socket.add(bytes);
  socket.write('\r\n');
}

Future<void> _settleSource(
  WidgetTester tester,
  bool Function() complete,
) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (complete()) return;
  }
  fail(
    'The real WebDAV request and background catalogue update did not settle.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'WebDAV collection URLs preserve encoded base, child and root paths',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        request.response.statusCode = 207;
        request.response.write('<d:multistatus xmlns:d="DAV:"/>');
        await request.response.close();
      });
      final origin = 'http://127.0.0.1:${server.port}';
      final source = _webdav('$origin${Uri(path: '/媒体 库')}');
      final root = _webdav(origin);
      try {
        await source.list('');
        await source.list('节目 #1');
        await root.list('');
        expect(requests, [
          Uri(path: '/媒体 库/').path,
          Uri(path: '/媒体 库/节目 #1/').path,
          '/',
        ]);
        expect(
          source.url('节目 #1/01.mkv').path,
          Uri(path: '/媒体 库/节目 #1/01.mkv').path,
        );
      } finally {
        await source.close();
        await root.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'old library details complete episodes from a WebDAV collection requiring its trailing slash',
    () async {
      final root = await Directory.systemTemp.createTemp('series-webdav-');
      final store = AppStore('${root.path}/library.db')
        ..setLocal('settings', {'metadataStrategy': 'off'});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final address = 'http://127.0.0.1:${server.port}/dav/';
      final model = _WebDavModel(store, root, address);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/dav/Series') {
          request.response.statusCode = HttpStatus.movedPermanently;
          request.response.headers.set('Location', '/dav/Series/');
        } else if (request.uri.path == '/dav/Series/') {
          request.response.statusCode = 207;
          request.response.write(_seriesListing(3));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      try {
        // Browsing uses the collection href returned by WebDAV, which ends /.
        final browser = _webdav(address);
        final listing = await browser.list('Series/');
        await browser.close();
        expect(listing, hasLength(3));
        final first = model.addMedia('nas', listing.first);
        final episodes = await model.loadSeriesEpisodes(
          store.get('media', first)!,
        );
        expect(episodes.map((record) => record.data['episode']), [
          '1',
          '2',
          '3',
        ], reason: 'WebDAV requests: $requests');
      } finally {
        model.dispose();
        store.dispose();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'All Videos details stay idle until reentered and pause without new frames',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      late Directory root;
      late AppStore store;
      late HttpServer server;
      late _WebDavModel model;
      late String first;
      var available = 1;
      final requests = <String>[];
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('series-webdav-entry-');
        store = AppStore('${root.path}/library.db')
          ..setLocal('settings', {'metadataStrategy': 'off'});
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request.uri.path);
          if (request.uri.path == '/dav/Series/') {
            request.response.statusCode = 207;
            request.response.write(_seriesListing(available));
          } else {
            request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        });
        model = _WebDavModel(
          store,
          root,
          'http://127.0.0.1:${server.port}/dav/',
        );
        first = model.addMedia(
          'nas',
          const SourceEntry(
            name: 'Example S01E01.mkv',
            path: 'Series/Example S01E01.mkv',
            size: 42,
          ),
        );
        await model.loadLibrarySnapshot();
      });
      final navigator = GlobalKey<NavigatorState>();
      final details = find.byKey(const ValueKey('series-details-list'));
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: GlassPalette.theme(),
            home: LibraryPage(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('play:$first')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settleSource(
          tester,
          () => requests.length == 1 && model.completedSeriesLoads == 1,
        );
        expect(find.textContaining('已收录 1 集'), findsOneWidget);
        final originalDetails = tester.element(details);

        available = 3;
        await tester.pump(const Duration(minutes: 6));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(requests, ['/dav/Series/']);
        expect(find.textContaining('已收录 1 集'), findsOneWidget);

        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settleSource(
          tester,
          () => find.textContaining('已收录 3 集').evaluate().isNotEmpty,
        );
        expect(requests, ['/dav/Series/', '/dav/Series/']);
        expect(tester.element(details), same(originalDetails));
        expect(store.records('progress'), isEmpty);

        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        available = 4;
        final beforeCovered = requests.length;
        await tester.pump(const Duration(minutes: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(requests.length, beforeCovered);

        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settleSource(
          tester,
          () => find.textContaining('已收录 4 集').evaluate().isNotEmpty,
        );
        expect(requests.length, beforeCovered + 1);
        expect(tester.element(details), same(originalDetails));

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        available = 5;
        final beforePaused = requests.length;
        // A paused Android app may receive no further frames. Lifecycle
        // handling must suspend requests directly, before any widget rebuild.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(requests.length, beforePaused);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await _settleSource(
          tester,
          () => find.textContaining('已收录 5 集').evaluate().isNotEmpty,
        );
        expect(requests.length, beforePaused + 1);
        expect(tester.element(details), same(originalDetails));

        await tester.pumpWidget(const SizedBox());
        final beforeDisposed = requests.length;
        await tester.pump(const Duration(minutes: 2));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(requests.length, beforeDisposed);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          model.dispose();
          store.dispose();
          await server.close(force: true);
          await root.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'entry-triggered WebDAV refresh stays bounded and cancels without a frame on pause',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      late Directory root;
      late AppStore store;
      late HttpServer server;
      late _WebDavModel model;
      late String first;
      late Completer<void> secondStarted;
      late Completer<void> secondClosed;
      late Completer<void> releaseStale;
      late Completer<void> staleFinished;
      Socket? pendingSocket;
      var requests = 0, activeRequests = 0, maxActiveRequests = 0;
      await tester.runAsync(() async {
        secondStarted = Completer<void>();
        secondClosed = Completer<void>();
        releaseStale = Completer<void>();
        staleFinished = Completer<void>();
        root = await Directory.systemTemp.createTemp('series-webdav-cancel-');
        store = AppStore('${root.path}/library.db')
          ..setLocal('settings', {'metadataStrategy': 'off'});
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final number = ++requests;
          activeRequests++;
          if (activeRequests > maxActiveRequests) {
            maxActiveRequests = activeRequests;
          }
          var requestClosed = false;
          void closed() {
            if (requestClosed) return;
            requestClosed = true;
            activeRequests--;
            if (number == 2 && !secondClosed.isCompleted) {
              secondClosed.complete();
            }
          }

          if (number != 2) {
            unawaited(
              request.response.done.then(
                (_) => closed(),
                onError: (Object _) => closed(),
              ),
            );
          }
          try {
            await request.drain<void>();
            if (request.uri.path != '/dav/Series/') {
              request.response.statusCode = HttpStatus.notFound;
            } else {
              request.response.statusCode = 207;
              if (number == 2) {
                // Observe TCP closure directly: HttpResponse.done only settles
                // after closing its sink and cannot observe this stalled body.
                final socket = pendingSocket = await request.response
                    .detachSocket(writeHeaders: false);
                socket.listen(
                  (_) {},
                  onDone: closed,
                  onError: (Object _) => closed(),
                );
                socket.write(
                  'HTTP/1.1 207 Multi-Status\r\n'
                  'Content-Type: application/xml\r\n'
                  'Transfer-Encoding: chunked\r\n'
                  'Connection: close\r\n\r\n',
                );
                _writeChunk(socket, '<?xml version="1.0"?>');
                await socket.flush();
                secondStarted.complete();
                await releaseStale.future;
                _writeChunk(socket, _seriesListing(99));
                socket.write('0\r\n\r\n');
                await socket.flush();
                socket.destroy();
                return;
              } else {
                request.response.write(_seriesListing(number == 1 ? 1 : 3));
              }
            }
            await request.response.close();
          } catch (_) {
            // The stale producer may discover the closed transport only when
            // it tries to finish its response after the source was cancelled.
          } finally {
            if (number == 2 && !staleFinished.isCompleted) {
              staleFinished.complete();
            }
          }
        });
        model = _WebDavModel(
          store,
          root,
          'http://127.0.0.1:${server.port}/dav/',
        );
        first = model.addMedia(
          'nas',
          const SourceEntry(
            name: 'Example S01E01.mkv',
            path: 'Series/Example S01E01.mkv',
            size: 42,
          ),
        );
        await model.loadLibrarySnapshot();
      });
      final details = find.byKey(const ValueKey('series-details-list'));
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: GlassPalette.theme(),
            home: LibraryPage(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('play:$first')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settleSource(
          tester,
          () =>
              requests == 1 &&
              activeRequests == 0 &&
              model.completedSeriesLoads == 1,
        );
        final originalDetails = tester.element(details);

        final navigator = Navigator.of(tester.element(details));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(builder: (_) => const Scaffold()),
          ),
        );
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settleSource(tester, () => secondStarted.isCompleted);
        expect(requests, 2);
        expect(activeRequests, 1);
        for (var interval = 0; interval < 6; interval++) {
          await tester.pump(const Duration(seconds: 10));
          await tester.runAsync(() async {
            // Keep this response alive beyond the former refresh intervals,
            // without testing the separate network inactivity timeout.
            _writeChunk(pendingSocket!, ' ');
            await pendingSocket!.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump();
        }
        expect(requests, 2);
        expect(maxActiveRequests, 1);
        expect(find.textContaining('已收录 1 集'), findsOneWidget);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.runAsync(
          () => secondClosed.future.timeout(const Duration(seconds: 3)),
        );
        expect(activeRequests, 0);
        expect(requests, 2);
        expect(store.records('media'), hasLength(1));

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await _settleSource(
          tester,
          () => find.textContaining('已收录 3 集').evaluate().isNotEmpty,
        );
        expect(requests, 3);
        expect(maxActiveRequests, 1);
        expect(tester.element(details), same(originalDetails));

        releaseStale.complete();
        await _settleSource(tester, () => staleFinished.isCompleted);
        expect(store.records('media'), hasLength(3));
        expect(find.textContaining('已收录 3 集'), findsOneWidget);
        expect(requests, 3);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        if (!releaseStale.isCompleted) releaseStale.complete();
        await tester.pump();
        await tester.runAsync(() async {
          model.dispose();
          store.dispose();
          pendingSocket?.destroy();
          await server.close(force: true);
          if (secondStarted.isCompleted) {
            await staleFinished.future.timeout(const Duration(seconds: 2));
          }
          await root.delete(recursive: true);
        });
      }
    },
  );
}
