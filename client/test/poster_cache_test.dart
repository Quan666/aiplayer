import 'dart:async';
import 'dart:io';

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
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aiplayer-poster-cache-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    png = await File('assets/branding/app_icon.png').readAsBytes();
    requests = active = peak = 0;
    ports.clear();
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      requests++;
      active++;
      if (active > peak) peak = active;
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
    cache.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  String url(String name) => 'http://127.0.0.1:${server.port}/$name';

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
    cache = PosterCache(directory: directory, createClient: () {
      clients++;
      return _client();
    });
    for (var i = 0; i < 8; i++) {
      expect(await cache.load(url('reuse-$i')), isNotNull);
    }
    expect(requests, 8);
    expect(clients, 1);
    expect(ports, hasLength(1));
  });

  test('timing out a stalled download does not close another pooled request', () async {
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
    cache = PosterCache(directory: directory, timeout: const Duration(seconds: 2), createClient: _client);
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
  });

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
