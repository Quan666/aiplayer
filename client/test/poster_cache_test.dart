import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aiplayer/data/poster_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

class _RealHttp extends HttpOverrides {}

HttpClient _client() =>
    HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late PosterCache cache;
  late List<int> png;
  var requests = 0, active = 0, peak = 0;
  final ports = <int>{};
  final paths = <String>[];
  Completer<void>? responseGate;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aiplayer-poster-cache-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    png = await File('assets/branding/app_icon.png').readAsBytes();
    requests = active = peak = 0;
    ports.clear();
    paths.clear();
    responseGate = null;
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      requests++;
      paths.add(request.uri.path);
      active++;
      if (active > peak) peak = active;
      await responseGate?.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (request.uri.path == '/broken') {
        request.response.write('not an image');
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
      }
      await request.response.close();
      active--;
    });
    cache = PosterCache(directory: directory, createClient: _client);
  });
  tearDown(() async {
    if (responseGate?.isCompleted == false) responseGate!.complete();
    cache.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  String url(String name) => 'http://127.0.0.1:${server.port}/$name';

  Future<void> waitForRequests(int count) async {
    await Future.doWhile(() async {
      if (requests >= count) return false;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return true;
    }).timeout(const Duration(seconds: 2));
  }

  test(
    'replacement and worker commits revise only the changed cover',
    () async {
      final address = url('revised'), otherAddress = url('unchanged');
      final changes = <String>[];
      cache.changes.addListener(() => changes.add(cache.changes.value!.url));
      await cache.restore(address, Uint8List.fromList(png));
      await cache.restore(otherAddress, Uint8List.fromList(png));
      final first = (await cache.load(address))!;
      final other = (await cache.load(otherAddress))!;
      final revision = posterFileRevision(first);
      changes.clear();
      expect(await cache.load(address), same(first));
      expect(changes, isEmpty);
      await cache.restore(address, Uint8List.fromList(png), replace: true);
      final replacement = (await cache.load(address))!;
      expect(posterFileRevision(replacement), isNot(revision));
      expect(changes, [address]);
      expect(await cache.load(otherAddress), same(other));
      cache.fileChanged(address);
      expect(cache.resolvedFile(address), isNull);
      final committed = (await cache.load(address))!;
      expect(
        posterFileRevision(committed),
        isNot(posterFileRevision(replacement)),
      );
      expect(await cache.load(otherAddress), same(other));
      expect(changes, [address, address]);
      expect(requests, 0);
    },
  );

  test(
    'visible covers bypass queued prefetches and duplicate downloads',
    () async {
      responseGate = Completer<void>();
      final downloads = [
        for (var i = 0; i < 12; i++) cache.load(url('queued-$i')),
      ];
      await waitForRequests(4);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final visible = cache.loadVisible(url('queued-11'));
      expect(visible, same(downloads[11]));
      responseGate!.complete();
      expect(await visible, isNotNull);
      await Future.wait(downloads);
      expect(paths[4], '/queued-11');
      expect(requests, 12);
      expect(peak, lessThanOrEqualTo(4));
    },
  );

  test(
    'full prefetch queue reserves disk lookups for visible covers',
    () async {
      final localUrl = url('already-on-disk');
      await cache.cachedFile(localUrl).writeAsBytes(png);
      responseGate = Completer<void>();
      final downloads = [
        for (var i = 0; i < PosterCache.maxPending; i++)
          cache.load(url('bulk-$i')),
      ];
      await waitForRequests(4);
      expect(await downloads.last, isNull);
      expect(await cache.load(url('overflow')), isNull);
      final local = await cache
          .loadVisible(localUrl)!
          .timeout(const Duration(seconds: 1));
      expect(await local!.readAsBytes(), png);
      expect(requests, 4);
      responseGate!.complete();
      await Future.wait(downloads);
      expect(requests, PosterCache.maxPending - 4);
    },
  );

  test(
    'full visible queue wakes deferred covers when capacity returns',
    () async {
      responseGate = Completer<void>();
      final downloads = [
        for (var i = 0; i < PosterCache.maxPending; i++)
          cache.loadVisible(url('visible-$i'))!,
      ];
      expect(cache.loadVisible(url('deferred')), isNull);
      final available = Completer<void>();
      void wake() {
        if (!available.isCompleted) available.complete();
      }

      cache.capacity.addListener(wake);
      await waitForRequests(4);
      responseGate!.complete();
      await available.future.timeout(const Duration(seconds: 2));
      cache.capacity.removeListener(wake);
      final retry = cache.loadVisible(url('deferred'));
      expect(retry, isNotNull);
      expect(await retry, isNotNull);
      await Future.wait(downloads);
      expect(requests, PosterCache.maxPending + 1);
      expect(peak, lessThanOrEqualTo(4));
    },
  );

  test('closing a full queue cancels active and waiting downloads', () async {
    responseGate = Completer<void>();
    final downloads = [
      for (var i = 0; i < 12; i++) cache.load(url('close-$i')),
    ];
    await waitForRequests(4);
    cache.close();
    final results = await Future.wait(
      downloads,
    ).timeout(const Duration(seconds: 2));
    expect(results, everyElement(isNull));
    expect(requests, 4);
    expect(await cache.load(url('after-close')), isNull);
  });

  test(
    'a failed local file repairs once without the network failure backoff',
    () async {
      final address = url('repair');
      await cache.cachedFile(address).writeAsString('corrupt image');
      final failed = (await cache.load(address))!;
      expect(requests, 0);
      final invalidation = cache.invalidate(
        address,
        failedFile: failed,
        retryImmediately: true,
      );
      expect(
        cache.invalidate(address, failedFile: failed, retryImmediately: true),
        same(invalidation),
      );
      responseGate = Completer<void>();
      final replacement = cache.loadVisible(address)!;
      await invalidation;
      await waitForRequests(1);
      final lateFailure = cache.invalidate(
        address,
        failedFile: failed,
        retryImmediately: true,
      );
      responseGate!.complete();
      await lateFailure;
      final repaired = (await replacement)!;
      expect(await repaired.readAsBytes(), png);
      expect(requests, 1);
      await cache.invalidate(
        address,
        failedFile: failed,
        retryImmediately: true,
      );
      expect(cache.resolvedFile(address), same(repaired));
      expect(await repaired.exists(), isTrue);
    },
  );

  test(
    'validation handles very narrow posters without upscaling them',
    () async {
      final bytes = images.encodePng(images.Image(width: 1, height: 8192));
      final address = url('narrow');
      await cache.restore(address, bytes);
      expect(await (await cache.load(address))!.readAsBytes(), bytes);
      expect(requests, 0);
    },
  );

  test('different posters reuse one connection and one client', () async {
    cache.close();
    var clients = 0;
    cache = PosterCache(
      directory: directory,
      createClient: () {
        clients++;
        return _client();
      },
    );
    for (var i = 0; i < 8; i++) {
      expect(await cache.load(url('reuse-$i')), isNotNull);
    }
    expect(requests, 8);
    expect(clients, 1);
    expect(ports, hasLength(1));
  });

  test(
    'timing out a stalled download does not close another pooled request',
    () async {
      cache.close();
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final slowStarted = Completer<void>(), fastStarted = Completer<void>();
      final releaseFast = Completer<void>();
      origin.listen((request) async {
        try {
          if (request.uri.path == '/slow') {
            slowStarted.complete();
            request.response.add([1]);
            await request.response.flush();
          } else {
            fastStarted.complete();
            await releaseFast.future;
            request.response.add(png);
            await request.response.close();
          }
        } on SocketException {
          // The deliberately stalled request is aborted by its deadline.
        } on HttpException {
          // The deliberately stalled request is aborted by its deadline.
        }
      });
      cache = PosterCache(
        directory: directory,
        timeout: const Duration(seconds: 2),
        createClient: _client,
      );
      try {
        final slow = cache.load('http://127.0.0.1:${origin.port}/slow');
        await slowStarted.future;
        await Future<void>.delayed(const Duration(seconds: 1));
        final fast = cache.load('http://127.0.0.1:${origin.port}/fast');
        await fastStarted.future;
        expect(await slow, isNull);
        releaseFast.complete();
        expect(await fast, isNotNull);
      } finally {
        if (!releaseFast.isCompleted) releaseFast.complete();
        cache.close();
        await origin.close(force: true);
      }
    },
  );

  test('failed client initialization releases all download slots', () async {
    cache.close();
    var clients = 0;
    cache = PosterCache(
      directory: directory,
      createClient: () {
        if (++clients <= 4) throw StateError('unavailable client');
        return _client();
      },
    );
    for (var i = 0; i < 4; i++) {
      expect(await cache.load(url('failed-$i')), isNull);
    }
    expect(
      await cache.load(url('recovered')).timeout(const Duration(seconds: 2)),
      isNotNull,
    );
    expect(requests, 1);
  });

  test(
    'simultaneous cards download once and a new cache reads from disk offline',
    () async {
      final address = url('poster');
      final files = await Future.wait(
        List.generate(12, (_) => cache.load(address)),
      );
      expect(files.every((file) => file != null), true);
      expect(files.map((file) => file!.path).toSet(), hasLength(1));
      expect(requests, 1);
      expect(await files.first!.readAsBytes(), png);
      cache.close();
      await server.close(force: true);
      cache = PosterCache(
        directory: directory,
        createClient: () => throw StateError('Must remain offline'),
      );
      final restored = await cache.load(address);
      expect(restored?.path, files.first!.path);
      expect(await restored!.readAsBytes(), png);
    },
  );

  test(
    'new covers have bounded parallel requests and invalid content is not cached or retried on rebuild',
    () async {
      final files = await Future.wait(
        List.generate(9, (i) => cache.load(url('poster-$i'))),
      );
      expect(files.whereType<File>(), hasLength(9));
      expect(peak, lessThanOrEqualTo(4));
      expect(await cache.load(url('broken')), isNull);
      final before = requests;
      expect(await cache.load(url('broken')), isNull);
      expect(requests, before);
      expect(directory.listSync().whereType<File>(), hasLength(9));
    },
  );

  test('old covers remain offline beyond the former disk size limit', () async {
    cache.close();
    cache = PosterCache(
      directory: directory,
      maxBytes: png.length * 2,
      createClient: _client,
    );
    final first = (await cache.load(url('one')))!;
    final second = (await cache.load(url('two')))!;
    await first.setLastModified(DateTime(2000));
    final third = (await cache.load(url('three')))!;
    expect(await first.exists(), true);
    expect(await second.exists(), true);
    expect(await third.exists(), true);
    final before = requests;
    cache.close();
    cache = PosterCache(
      directory: directory,
      createClient: () => throw StateError('Offline'),
    );
    expect(await cache.load(url('one')), isNotNull);
    expect(await cache.load(url('two')), isNotNull);
    expect(await cache.load(url('three')), isNotNull);
    expect(requests, before);
  });

  test(
    'revisiting a loaded cover resolves synchronously without disk or network waits',
    () async {
      final address = url('revisit');
      final file = await cache.load(address);
      final before = requests;
      var synchronous = false;
      cache.load(address).then((value) {
        expect(value, same(file));
        synchronous = true;
      });
      expect(synchronous, isTrue);
      expect(requests, before);
      await cache.invalidate(address);
      expect(cache.resolvedFile(address), isNull);
    },
  );
}
