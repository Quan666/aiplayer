import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/directory_metadata_worker.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/sources/range_bridge.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native proxy channel serves root and background network isolates',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
        await request.response.close();
      });
      try {
        final uri = Uri.parse('http://127.0.0.1:${server.port}/proxy-check');
        final route = await resolveSystemProxy(uri);
        expect(route, isNotNull);
        expect(route, isNotEmpty);
        final configuration = SystemProxyWorkerConfiguration.capture();
        final worker = await Isolate.run(() async {
          initializeSystemProxyWorker(configuration);
          final route = await resolveSystemProxy(uri);
          final response = await IoJsonTransport().send(uri);
          return (route, response);
        });
        expect(worker.$1, route);
        expect(worker.$2, {'ok': true});
        expect(requests, 1);
      } finally {
        await server.close(force: true);
      }
    },
  );

  testWidgets('native directory worker exits after its final database read', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('proxy-worker-');
    final store = await AppStore.open('${directory.path}/library.db');
    store.save('media', 'episode', {'title': 'Fixture episode'});
    final worker = DirectoryMetadataWorker(store.path);
    try {
      final records = await worker.readRecords({'episode'});
      expect(records.single.id, 'episode');
      // The platform messenger owns a ReceivePort too. Closing only the
      // worker command port must not leave close() waiting for isolate exit.
      await worker.close().timeout(const Duration(seconds: 1));
    } finally {
      unawaited(worker.close());
      store.dispose();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('native directory startup failure still releases its worker', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('proxy-failure-');
    final worker = DirectoryMetadataWorker(
      '${directory.path}/missing/library.db',
    );
    try {
      await expectLater(worker.readRecords({}), throwsA(isA<AppFailure>()));
      await worker.close().timeout(const Duration(seconds: 1));
    } finally {
      unawaited(worker.close());
      await directory.delete(recursive: true);
    }
  });

  testWidgets('native sync worker exits after completed synchronization', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('proxy-sync-');
    final store = await AppStore.open('${directory.path}/library.db');
    final client = SyncClient(store);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.uri.path, '/v1/changes');
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"changes":[],"cursor":0,"hasMore":false}');
      await request.response.close();
    });
    try {
      await client.synchronize(
        'http://127.0.0.1:${server.port}',
        'native-worker-test-token-with-24-characters',
      );
      expect(client.backgroundWorkerStarts, 1);
      expect(requests, 1);
      await client.dispose().timeout(const Duration(seconds: 1));
    } finally {
      unawaited(client.dispose());
      await server.close(force: true);
      store.dispose();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('native HTTP bridge exits without its forced-kill fallback', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.method, 'HEAD');
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.contentLength = 1024;
      await request.response.close();
    });
    final source = HttpSource('http://127.0.0.1:${server.port}/episode.mkv');
    RangeBridge? bridge;
    try {
      bridge = await RangeBridge.open(source, '');
      expect(bridge.entry.size, 1024);
      await source.close();
      // A healthy shutdown must finish before the two-second kill fallback.
      await bridge.close().timeout(const Duration(seconds: 1));
    } finally {
      await bridge?.close();
      await source.close();
      await server.close(force: true);
    }
  });
}
