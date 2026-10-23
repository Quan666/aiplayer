import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/credential_storage.dart';
import 'package:aiplayer/data/poster_cache.dart';
import 'package:aiplayer/data/record_keys.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/data/sync.dart';
import 'package:aiplayer/data/sync_artwork.dart';
import 'package:aiplayer/data/sync_profile.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;

const _token = 'full-sync-worker-test-token-with-24-characters';

void main() {
  // No widget HTTP override: these tests exercise the production isolate and
  // loopback network, including the secure-storage RPC boundary.
  test(
    'disposing a worker cancels credential work and rejects queued synchronization',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      final entered = Completer<void>(), release = Completer<void>();
      device.secrets.beforeRead = (_) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final result = expectLater(device.sync(), throwsA(isA<Cancelled>()));
      await entered.future.timeout(const Duration(seconds: 5));
      await device.client.dispose().timeout(const Duration(seconds: 2));
      await result;
      release.complete();
      await expectLater(device.sync(), throwsA(isA<Cancelled>()));
      expect(device.store.local('lastSync'), isNull);
      expect(device.client.backgroundWorkerStarts, 1);
    },
  );

  test(
    'a reused worker accesses the same local SQLite credential store',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      final secrets = LocalCredentialStorage(device.directory);
      final client = SyncClient(
        device.store,
        profile: SyncProfile(
          device.store,
          secrets,
          watchedKey: mediaWatchedKey,
          recoverMissingCredentials: true,
        ),
      );
      addTearDown(() async {
        await client.dispose();
        await secrets.close();
      });
      await secrets.write(
        key: 'aiSubtitleToken',
        value: 'local-credential-key',
      );
      device.store.setLocal('settings', {'subtitleSize': 24});
      await client.synchronize(server.origin, _token);
      final digest = await secrets.read(key: 'sync.digestKey');
      expect(digest, isNotNull);
      await client.synchronize(server.origin, _token);
      expect(await secrets.read(key: 'sync.digestKey'), digest);
      expect(
        await secrets.read(key: 'aiSubtitleToken'),
        'local-credential-key',
      );
      expect(client.backgroundWorkerStarts, 1);
      expect(device.store.snapshotReads, 0);
      expect(
        server.records.values.where((r) => r.kind == 'vault'),
        hasLength(2),
      );
    },
  );

  test(
    'full sync keeps catalogue SQL and profile crypto away from the UI store',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      final data = jsonEncode({'transient': true, 'summary': 'x' * 2048});
      device.store.transaction(() {
        final insert = device.store.db.prepare(
          'INSERT INTO records(kind,id,data) VALUES(?,?,?)',
        );
        try {
          for (var i = 0; i < 4000; i++) {
            insert.execute(['media', 'private-$i', data]);
          }
        } finally {
          insert.dispose();
        }
      });
      device.store.setLocal('settings', {
        for (var i = 0; i < 40; i++) 'future-setting-$i': 'value' * 128,
      });
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      await device.sync();
      expect(
        device.store.snapshotReads,
        0,
        reason: 'full table reads must use the independent worker connection',
      );
      expect(ticks, greaterThan(4));
      expect(
        server.records.values.where((r) => r.kind == 'vault'),
        hasLength(40),
      );
      expect(device.secrets.reads, greaterThan(0));
      expect(device.secrets.values['sync.digestKey'], isNotNull);
      expect(device.client.profileRevision, 1);
      expect(device.store.local('lastSync'), isNotNull);
      expect(device.store.local('syncCursor:${server.origin}'), 40);
    },
  );

  test(
    'workers share credentials, remote bindings and artwork across devices',
    () async {
      final server = await _Server.start();
      final first = await _Device.open(server),
          second = await _Device.open(server);
      first.seed();
      const url = 'https://images.example/poster.png';
      final picture = images.encodePng(
        images.Image(width: 16, height: 16)..setPixelRgb(0, 0, 12, 80, 200),
      );
      await first.posters.directory.create(recursive: true);
      await first.posters.cachedFile(url).writeAsBytes(picture);
      await first.sync();
      await second.sync();
      expect(first.store.snapshotReads, 0);
      expect(second.store.snapshotReads, 0);
      expect(second.secrets.values['source:nas'], 'nas-password');
      expect(second.secrets.values['aiSubtitleToken'], 'translation-key');
      expect(second.store.local('settings')['subtitleSize'], 24);
      expect(second.store.get('media', 'video')!.data['title'], 'Episode');
      expect(second.store.local('location:video')['path'], 'Show/E01.mkv');
      expect(await second.posters.cachedFile(url).readAsBytes(), picture);
      final watched = mediaWatchedKey(second.store.get('media', 'video')!);
      expect(second.store.get('watched', watched)!.data['watched'], true);
      expect(second.client.profileRevision, 1);
      final puts = server.puts;
      await second.sync();
      expect(
        server.puts,
        puts,
        reason: 'new worker instances must retain the profile baseline',
      );
      expect(second.client.backgroundWorkerStarts, 1);
    },
  );

  test(
    'worker poster commits invalidate the warm parent handle without touching other covers',
    () async {
      final server = await _Server.start();
      final first = await _Device.open(server),
          second = await _Device.open(server);
      first.seed();
      const url = 'https://images.example/poster.png';
      const otherUrl = 'https://images.example/unrelated.png';
      final picture = images.encodePng(images.Image(width: 32, height: 48));
      final oldPicture = images.encodePng(images.Image(width: 16, height: 24));
      await first.posters.directory.create(recursive: true);
      await first.posters.cachedFile(url).writeAsBytes(picture);
      await first.sync();
      await second.posters.directory.create(recursive: true);
      await second.posters.cachedFile(url).writeAsBytes(oldPicture);
      await second.posters.cachedFile(otherUrl).writeAsBytes(oldPicture);
      final old = (await second.posters.load(url))!;
      final unrelated = (await second.posters.load(otherUrl))!;
      final changed = <String>[];
      second.posters.changes.addListener(
        () => changed.add(second.posters.changes.value!.url),
      );

      await second.sync();
      expect(changed, [url]);
      expect(second.posters.resolvedFile(url), isNull);
      final current = (await second.posters.load(url))!;
      expect(posterFileRevision(current), isNot(posterFileRevision(old)));
      expect(await current.readAsBytes(), picture);
      expect(second.posters.resolvedFile(otherUrl), same(unrelated));
      changed.clear();
      await second.sync();
      expect(changed, isEmpty);
      expect(second.posters.resolvedFile(url), same(current));
      expect(second.client.backgroundWorkerStarts, 1);
    },
  );

  test(
    'a committed poster invalidates the parent even when a later artwork write fails',
    () async {
      final server = await _Server.start();
      final first = await _Device.open(server),
          second = await _Device.open(server);
      first.seed();
      const urls = [
        'https://images.example/poster.png',
        'https://images.example/other-poster.png',
      ];
      first.store.save('media', 'other-video', {
        ...first.store.get('media', 'video')!.data,
        'poster': urls[1],
      });
      first.store.setLocal('location:other-video', {
        'id': 'other-video',
        'source': 'nas',
        'path': 'Show/E02.mkv',
        'size': 10,
      });
      final picture = images.encodePng(images.Image(width: 32, height: 48));
      await first.posters.directory.create(recursive: true);
      for (final url in urls) {
        await first.posters.cachedFile(url).writeAsBytes(picture);
      }
      await first.sync();
      final baseline = first.store.local('syncProfile:baseline') as Map;
      final artworkIds =
          baseline.keys
              .cast<String>()
              .where((id) => id.startsWith('artwork:'))
              .toList()
            ..sort();
      expect(artworkIds, hasLength(2));
      String posterFor(String id) =>
          (baseline[id]['descriptor']['key'] as String).substring(7);
      final committedUrl = posterFor(artworkIds.first);
      final failingUrl = posterFor(artworkIds.last);
      await second.posters.directory.create(recursive: true);
      await second.posters
          .cachedFile(committedUrl)
          .writeAsBytes(images.encodePng(images.Image(width: 16, height: 24)));
      final old = (await second.posters.load(committedUrl))!;
      // An occupied destination makes only the second atomic rename fail.
      await Directory(second.posters.cachedFile(failingUrl).path).create();
      final changed = <String>[];
      second.posters.changes.addListener(
        () => changed.add(second.posters.changes.value!.url),
      );
      await expectLater(second.sync(), throwsA(isA<AppFailure>()));
      expect(second.store.local('lastSync'), isNull);
      expect(changed, [committedUrl]);
      expect(second.posters.resolvedFile(committedUrl), isNull);
      final current = (await second.posters.load(committedUrl))!;
      expect(posterFileRevision(current), isNot(posterFileRevision(old)));
      expect(await current.readAsBytes(), picture);
    },
  );

  test(
    'deferred worker downloads retain their cursor and apply on the next full sync',
    () async {
      final server = await _Server.start();
      final first = await _Device.open(server),
          second = await _Device.open(server);
      first.seed();
      await first.sync();
      await second.sync(sharedOnly: true, deferProfile: true);
      final cursor = second.store.local('syncCursor:${server.origin}');
      expect(second.store.local('settings'), isNull);
      expect(second.store.local('location:video'), isNull);
      expect(second.client.profileRevision, 0);
      expect(second.store.local('syncProfile:pendingApply'), true);
      await second.sync();
      expect(second.store.local('syncCursor:${server.origin}'), cursor);
      expect(second.store.local('location:video')['source'], 'nas');
      expect(second.client.profileRevision, 1);
      expect(second.store.local('syncProfile:pendingApply'), isNull);
    },
  );

  test(
    'a UI edit while the worker uploads survives acknowledgement and reaches the server',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      device.store.save('media', 'video', {'title': 'Before'});
      final entered = Completer<void>(), release = Completer<void>();
      server.beforePut = (record) async {
        if (record.kind != 'media') return;
        server.beforePut = null;
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final first = device.sync();
      await entered.future.timeout(const Duration(seconds: 5));
      device.store.save('media', 'video', {'title': 'After'});
      final queued = device.sync();
      release.complete();
      await Future.wait([first, queued]);
      expect(server.records['media:video']!.data['title'], 'After');
      expect(device.store.get('media', 'video')!.dirty, false);
      expect(device.store.conflicts, isEmpty);
    },
  );

  test(
    'cancelling a pending credential RPC exits and leaves synchronization retryable',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      final entered = Completer<void>(), release = Completer<void>();
      device.secrets.beforeRead = (_) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final cancel = CancelToken();
      final work = device.sync(cancel: cancel);
      final result = expectLater(work, throwsA(isA<Cancelled>()));
      await entered.future.timeout(const Duration(seconds: 5));
      cancel.cancel();
      await result.timeout(const Duration(seconds: 2));
      expect(device.store.local('lastSync'), isNull);
      expect(device.store.local('syncCursor:${server.origin}'), isNull);
      release.complete();
      device.secrets.beforeRead = null;
      await device.sync();
      expect(device.store.local('lastSync'), isNotNull);
    },
  );

  test(
    'credential failures return to the caller and the next worker can retry',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      device.secrets.beforeRead = (_) async =>
          throw StateError('sensitive plugin detail');
      await expectLater(device.sync(), throwsA(isA<AppFailure>()));
      expect(device.store.local('lastSync'), isNull);
      device.secrets.beforeRead = null;
      await device.sync();
      expect(device.client.profileRevision, 1);
    },
  );

  test(
    'cancellation interrupts full-sync SQLite contention without blocking UI timers',
    () async {
      final server = await _Server.start();
      final device = await _Device.open(server);
      device.store.save('media', 'video', {'title': 'Before'});
      final cancel = CancelToken();
      var locked = false, ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => ticks++,
      );
      addTearDown(() {
        timer.cancel();
        if (locked) device.store.db.execute('ROLLBACK');
      });
      server.beforePut = (_) async {
        server.beforePut = null;
        device.store.db.execute('BEGIN IMMEDIATE');
        locked = true;
        Timer(const Duration(milliseconds: 80), cancel.cancel);
      };
      await expectLater(
        device.sync(cancel: cancel).timeout(const Duration(seconds: 2)),
        throwsA(isA<Cancelled>()),
      );
      expect(ticks, greaterThanOrEqualTo(4));
      expect(locked, true);
      device.store.db.execute('COMMIT');
      locked = false;
      expect(device.store.local('lastSync'), isNull);
      await device.sync();
      expect(device.store.get('media', 'video')!.dirty, false);
    },
  );
}

class _Device {
  final _Server server;
  final Directory directory;
  final _CountingStore store;
  final _Secrets secrets = _Secrets();
  late final PosterCache posters = PosterCache(
    directory: Directory('${directory.path}/posters'),
  );
  late final SyncClient client = SyncClient(
    store,
    profile: SyncProfile(
      store,
      secrets,
      watchedKey: mediaWatchedKey,
      artwork: SyncArtwork(store, directory, posters),
    ),
  );
  _Device(this.server, this.directory)
    : store = _CountingStore('${directory.path}/app.db');
  static Future<_Device> open(_Server server) async {
    final device = _Device(
      server,
      await Directory.systemTemp.createTemp('sync-worker-'),
    );
    addTearDown(() async {
      await device.client.dispose();
      device.posters.close();
      device.store.dispose();
      await device.directory.delete(recursive: true);
    });
    return device;
  }

  Future<void> sync({
    CancelToken? cancel,
    bool sharedOnly = false,
    bool deferProfile = false,
  }) => client.synchronize(
    server.origin,
    _token,
    cancel: cancel,
    sharedOnly: sharedOnly,
    deferProfile: deferProfile,
  );
  void seed() {
    secrets.values.addAll({
      'source:nas': 'nas-password',
      'aiSubtitleToken': 'translation-key',
    });
    store.setLocal('settings', {'subtitleSize': 24});
    store.setLocal('sources', [
      {
        'id': 'nas',
        'kind': 'webdav',
        'url': 'https://nas.example/dav/',
        'label': 'NAS',
      },
    ]);
    store.save('media', 'video', {
      'title': 'Episode',
      'series': 'Show',
      'season': '1',
      'episode': '1',
      'size': 10,
      'poster': 'https://images.example/poster.png',
    });
    store.setLocal('location:video', {
      'id': 'video',
      'source': 'nas',
      'path': 'Show/E01.mkv',
      'size': 10,
    });
    store.save('watched', mediaWatchedKey(store.get('media', 'video')!), {
      'watched': true,
    });
  }
}

class _CountingStore extends AppStore {
  int snapshotReads = 0;
  _CountingStore(super.path);
  @override
  List<SyncRecord> records(String kind) {
    snapshotReads++;
    return super.records(kind);
  }

  @override
  Map<String, dynamic> localEntries(String prefix) {
    snapshotReads++;
    return super.localEntries(prefix);
  }

  @override
  List<Map<String, dynamic>> get locations {
    snapshotReads++;
    return super.locations;
  }

  @override
  List<SyncRecord> pendingRecords({
    bool includeVault = true,
    bool playbackOnly = false,
  }) {
    snapshotReads++;
    return super.pendingRecords(
      includeVault: includeVault,
      playbackOnly: playbackOnly,
    );
  }
}

class _Secrets extends FlutterSecureStorage {
  final values = <String, String>{};
  int reads = 0;
  Future<void> Function(String)? beforeRead;
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    await beforeRead?.call(key);
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

class _Server {
  final HttpServer server;
  final records = <String, SyncRecord>{};
  final changes = <SyncRecord>[];
  int puts = 0;
  Future<void> Function(SyncRecord)? beforePut;
  _Server(this.server);
  String get origin => 'http://127.0.0.1:${server.port}';
  static Future<_Server> start() async {
    final result = _Server(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    result.server.listen((request) => unawaited(result.handle(request)));
    addTearDown(() => result.server.close(force: true));
    return result;
  }

  Future<void> handle(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    if (request.method == 'PUT') {
      final incoming = SyncRecord.fromJson(
        jsonDecode(await utf8.decoder.bind(request).join()),
      );
      puts++;
      await beforePut?.call(incoming);
      final key = '${incoming.kind}:${incoming.id}';
      final previous = records[key];
      if (incoming.version != (previous?.version ?? 0)) {
        request.response.statusCode = HttpStatus.conflict;
        request.response.write(jsonEncode({'current': previous!.toJson()}));
      } else {
        final accepted = SyncRecord.fromJson({
          ...incoming.toJson(),
          'version': incoming.version + 1,
        });
        records[key] = accepted;
        changes.add(accepted);
        request.response.write(jsonEncode(accepted.toJson()));
      }
    } else {
      final cursor = int.parse(request.uri.queryParameters['after'] ?? '0');
      final page = changes.skip(cursor).take(50).toList();
      request.response.write(
        jsonEncode({
          'changes': page.map((r) => r.toJson()).toList(),
          'cursor': cursor + page.length,
          'hasMore': cursor + page.length < changes.length,
        }),
      );
    }
    try {
      await request.response.close();
    } on HttpException {
      /* Cancellation disconnects. */
    }
  }
}
