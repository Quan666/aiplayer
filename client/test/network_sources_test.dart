import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:aiplayer_smb/aiplayer_smb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:aiplayer/sources/range_bridge.dart';

void main() {
  test('large WebDAV listing preserves metadata when parsed off-isolate', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      request.response.statusCode = 207;
      request.response.write('<d:multistatus xmlns:d="DAV:">');
      for (var index = 0; index < 1200; index++) {
        request.response.write(
          '''<d:response><d:href>/dav/episode-$index.mkv</d:href><d:propstat><d:prop><d:getcontentlength>${index + 10}</d:getcontentlength><d:getlastmodified>Wed, 21 Oct 2026 12:00:00 GMT</d:getlastmodified><d:resourcetype/><d:ishidden>${index.isEven ? 'true' : 'false'}</d:ishidden></d:prop></d:propstat></d:response>''',
        );
      }
      request.response.write(
        '<d:response><d:href>/dav/season/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response></d:multistatus>',
      );
      await request.response.close();
    });
    final source = HttpSource(
      'http://127.0.0.1:${server.port}/dav/',
      webdav: true,
    );
    try {
      final entries = await source.list('');
      expect(entries, hasLength(1201));
      expect(entries[0].hidden, true);
      expect(entries[1].hidden, false);
      expect(entries[1199].path, 'episode-1199.mkv');
      expect(entries[1199].size, 1209);
      expect(
        entries[1199].modified,
        DateTime.utc(2026, 10, 21, 12).millisecondsSinceEpoch,
      );
      expect(entries.last.name, 'season');
      expect(entries.last.directory, true);
    } finally {
      await source.close();
      await server.close(force: true);
    }
  });

  test(
    'server-level SMB enumerates shares and routes reads to the selected share',
    () async {
      final connections = <String, _SmbFixture>{};
      final server = SmbServerSource(
        (share) async => connections[share] = _SmbFixture(),
      );
      expect((await server.stat('video/')).directory, true);
      expect(
        await server
            .read('video/中文.mkv', 3, 5)
            .expand((bytes) => bytes)
            .toList(),
        [3, 4, 5],
      );
      // A stored playback path already selects its share; discovery would add
      // an unnecessary IPC$ authentication before the first video read.
      expect(connections.keys, ['video']);
      expect((await server.list('')).single.path, 'video/');
      expect(server.dialect, 0x0311);
      expect(connections.keys, containsAll(['IPC\$', 'video']));
      expect(connections['video']!.offsets, [3]);
      await server.close();
      expect(connections.values.every((connection) => connection.closed), true);
    },
  );
  test(
    'concurrent SMB root listings share one lazy discovery connection',
    () async {
      final pending = Completer<SmbConnection>();
      var connections = 0;
      final server = SmbServerSource((share) {
        expect(share, 'IPC\$');
        connections++;
        return pending.future;
      });
      final connection = _SmbFixture();
      try {
        final first = server.list(''), second = server.list('');
        expect(connections, 1);
        pending.complete(connection);
        expect((await first).single.path, 'video/');
        expect((await second).single.path, 'video/');
        expect((await server.list('')).single.path, 'video/');
        expect(connections, 1);
      } finally {
        await server.close();
      }
      expect(connection.closed, true);
    },
  );
  test('failed lazy SMB discovery can retry', () async {
    var connections = 0;
    final connection = _SmbFixture();
    final server = SmbServerSource((_) async {
      if (++connections == 1) throw const SmbFailure(-111);
      return connection;
    });
    try {
      await expectLater(server.list(''), throwsA(isA<SmbFailure>()));
      expect((await server.list('')).single.path, 'video/');
      expect(connections, 2);
    } finally {
      await server.close();
    }
    expect(connection.closed, true);
  });
  test('closing during SMB discovery releases a late connection', () async {
    final pending = Completer<SmbConnection>();
    var connections = 0;
    final server = SmbServerSource((_) {
      connections++;
      return pending.future;
    });
    final opening = expectLater(server.list(''), throwsA(isA<AppFailure>()));
    await server.close();
    final connection = _SmbFixture();
    pending.complete(connection);
    await opening;
    expect(connection.closed, true);
    await expectLater(server.initialize(), throwsA(isA<AppFailure>()));
    expect(connections, 1);
  });
  test(
    'SMB errors preserve actionable status without native server messages',
    () {
      expect(const SmbFailure(-1073741715).message, contains('登录失败'));
      expect(const SmbFailure(0xc00000cc).message, contains('共享不存在'));
      expect(const SmbFailure(-111).message, contains('连接被拒绝'));
    },
  );

  test(
    'HTTP errors include status and never include authenticated request URLs',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        request.response.statusCode = 401;
        request.response.write('private-token private-password');
        await request.response.close();
      });
      final source = HttpSource(
        'http://127.0.0.1:${server.port}/private-path?token=private-token',
        webdav: true,
        user: 'user',
        password: 'private-password',
      );
      try {
        await expectLater(
          source.list(''),
          throwsA(
            isA<AppFailure>()
                .having((error) => error.status, 'status', 401)
                .having(
                  (error) => error.message,
                  'message',
                  contains('HTTP 401'),
                )
                .having(
                  (error) => error.message,
                  'redacted',
                  isNot(contains('private')),
                ),
          ),
        );
      } finally {
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'WebDAV reports unauthorized immediately even when the error body never ends',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        try {
          request.response.statusCode = 401;
          request.response.bufferOutput = false;
          request.response.write('Authentication required');
          await request.response.flush();
          // Deliberately leave this chunked response open.
        } on SocketException {
          // The client is expected to abandon the response body.
        }
      });
      final source = HttpSource(
        'http://127.0.0.1:${server.port}/dav/',
        webdav: true,
      );
      try {
        await expectLater(
          source.list('').timeout(const Duration(seconds: 2)),
          throwsA(isA<AppFailure>().having((e) => e.status, 'status', 401)),
        );
      } finally {
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'HTTP HEAD fallback reports forbidden without consuming a stalled GET body',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final methods = <String>[];
      server.listen((request) async {
        methods.add(request.method);
        try {
          if (request.method == 'HEAD') {
            request.response.statusCode = 405;
            await request.response.close();
            return;
          }
          request.response.statusCode = 403;
          request.response.bufferOutput = false;
          request.response.write('Permission denied');
          await request.response.flush();
          // Deliberately leave this chunked response open.
        } on SocketException {
          // The client is expected to abandon the response body.
        }
      });
      final source = HttpSource('http://127.0.0.1:${server.port}/video.mp4');
      try {
        await expectLater(
          source.stat('').timeout(const Duration(seconds: 2)),
          throwsA(isA<AppFailure>().having((e) => e.status, 'status', 403)),
        );
        expect(methods, ['HEAD', 'GET']);
      } finally {
        await source.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'SMB header and seek probes arrive before the remaining video is available',
    () async {
      final connection = _SmbProbeFixture();
      final source = SmbSource(connection);
      try {
        // The fixture exposes only the first 64 KiB of each probe. Waiting for
        // a larger native read would withhold the decoder's header forever.
        for (final offset in [0, 5 * 1024 * 1024 + 13]) {
          final probe = await source
              .read('video.mkv', offset, offset + 8 * 1024 * 1024 - 1)
              .first
              .timeout(const Duration(seconds: 2));
          expect(probe.length, 64 * 1024);
          expect(probe.first, offset % 256);
          expect(probe.last, (offset + probe.length - 1) % 256);
        }
        // Taking only the probe cancels the stream before any bulk read starts.
        expect(connection.offsets, [0, 5 * 1024 * 1024 + 13]);
      } finally {
        await source.close();
      }
    },
  );
  test(
    'SMB sequential reads keep large chunks and exact range boundaries',
    () async {
      final connection = _SmbFixture();
      final source = SmbSource(connection);
      const start = 17, length = 3 * 1024 * 1024 + 31;
      try {
        final chunks = await source
            .read('video.mkv', start, start + length - 1)
            .toList();
        expect(chunks.length, lessThanOrEqualTo(5));
        var offset = start;
        for (final chunk in chunks) {
          expect(chunk.first, offset % 256);
          expect(chunk.last, (offset + chunk.length - 1) % 256);
          offset += chunk.length;
        }
        expect(offset, start + length);
        final tail = await source.read('video.mkv', 987, 1000).toList();
        expect(tail.single, [for (var i = 987; i <= 1000; i++) i % 256]);
      } finally {
        await source.close();
      }
    },
  );
  test(
    'SMB reconnect resumes at the failed byte offset without duplicating bytes',
    () async {
      final first = _SmbFixture(failAt: 64 * 1024), second = _SmbFixture();
      var connections = 0;
      final source = SmbSource(
        first,
        reconnect: () async {
          connections++;
          return second;
        },
      );
      final result = await source
          .read('中文.mkv', 0, 1024 * 1024 + 6)
          .expand((b) => b)
          .toList();
      expect(result.length, 1024 * 1024 + 7);
      expect(result.sublist(result.length - 7), [0, 1, 2, 3, 4, 5, 6]);
      expect(connections, 1);
      expect(second.offsets, [64 * 1024]);
      expect(first.closed, true);
      await source.close();
      expect(second.closed, true);
    },
  );
  test(
    'HTTP metadata probe keeps its socket for the first video range',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final ports = <int>[];
      server.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.contentLength = 10;
        if (request.method == 'GET') {
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 0-9/10');
          request.response.add(List.filled(10, 42));
        }
        await request.response.close();
      });
      final source = HttpSource('http://127.0.0.1:${server.port}/video.mkv');
      try {
        expect((await source.stat('')).size, 10);
        expect(
          await source.read('', 0, 9).expand((b) => b).toList(),
          List.filled(10, 42),
        );
        expect(ports, hasLength(2));
        expect(ports.toSet(), hasLength(1));
      } finally {
        await source.close();
        await server.close(force: true);
      }
    },
  );
  test(
    'HTTP probes omitted Range headers and rejects seeking on sequential sources',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((r) async {
        if (r.method == 'HEAD') {
          r.response.contentLength = 50;
        } else if (r.uri.path == '/ranged') {
          final range = ByteRange.parse(r.headers.value('range'), 50)!;
          r.response.statusCode = 206;
          r.response.headers.set(
            'content-range',
            'bytes ${range.start}-${range.end}/50',
          );
          r.response.add(List.filled(range.length, 1));
        } else {
          r.response.contentLength = 50;
          r.response.add(List.filled(50, 1));
        }
        await r.response.close();
      });
      final ranged = HttpSource('http://127.0.0.1:${server.port}/ranged');
      final sequential = HttpSource(
        'http://127.0.0.1:${server.port}/sequential',
      );
      expect((await ranged.stat('')).seekable, true);
      expect((await sequential.stat('')).seekable, false);
      await expectLater(
        sequential.read('', 20, 25).toList(),
        throwsA(isA<AppFailure>()),
      );
      await ranged.close();
      await sequential.close();
      await server.close(force: true);
    },
  );
  test(
    'range bridge serves exact suffix, open ranges, HEAD and rejects invalid tokens',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aiplayer-range-',
      );
      final file = File('${directory.path}/中文视频.mkv');
      await file.writeAsBytes(List.generate(1024, (i) => i % 256));
      final bridge = await RangeBridge.open(LocalSource(), file.path);
      final client = HttpClient();
      for (final item in [
        ('bytes=10-19', 10, 19),
        ('bytes=-3', 1021, 1023),
        ('bytes=1000-', 1000, 1023),
      ]) {
        final req = await client.getUrl(bridge.uri);
        req.headers.set('Range', item.$1);
        final response = await req.close();
        expect(response.statusCode, 206);
        expect(
          response.headers.value('Content-Range'),
          'bytes ${item.$2}-${item.$3}/1024',
        );
        expect(await response.expand((b) => b).toList(), [
          for (var i = item.$2; i <= item.$3; i++) i % 256,
        ]);
      }
      final head = await (await client.openUrl('HEAD', bridge.uri)).close();
      expect(head.contentLength, 1024);
      await head.drain<void>();
      final bad = await client.getUrl(bridge.uri);
      bad.headers.set('Range', 'bytes=2000-');
      final unsatisfied = await bad.close();
      expect(unsatisfied.statusCode, 416);
      await unsatisfied.drain<void>();
      final denied = await (await client.getUrl(
        bridge.uri.replace(path: '/invalid'),
      )).close();
      expect(denied.statusCode, 404);
      await denied.drain<void>();
      client.close(force: true);
      await bridge.close();
      await directory.delete(recursive: true);
    },
  );
  test(
    'HTTP source validates random ranges and does not follow redirects',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((r) async {
        if (r.uri.path == '/redirect') {
          r.response.statusCode = 302;
          r.response.headers.set('Location', '/video');
          await r.response.close();
          return;
        }
        r.response.headers.set('Accept-Ranges', 'bytes');
        if (r.method == 'HEAD') {
          r.response.contentLength = 100;
          await r.response.close();
          return;
        }
        final range = ByteRange.parse(r.headers.value('range'), 100)!;
        r.response.statusCode = 206;
        r.response.contentLength = range.length;
        r.response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/100',
        );
        r.response.add([for (var i = range.start; i <= range.end; i++) i]);
        await r.response.close();
      });
      final source = HttpSource('http://127.0.0.1:${server.port}/video');
      expect((await source.stat('')).size, 100);
      expect(
        await source.read('', 20, 29).expand((v) => v).toList(),
        List.generate(10, (i) => i + 20),
      );
      final redirect = HttpSource('http://127.0.0.1:${server.port}/redirect');
      await expectLater(redirect.stat(''), throwsA(isA<AppFailure>()));
      await source.close();
      await redirect.close();
      await server.close(force: true);
    },
  );
  test(
    'WebDAV handles namespaces, encoded Chinese names and foreign hrefs',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((r) async {
        expect(r.method, 'PROPFIND');
        expect(r.headers.value('Depth'), '1');
        expect(
          r.headers.value('Authorization'),
          'Basic ${base64Encode(utf8.encode('u:p'))}',
        );
        r.response.statusCode = 207;
        r.response.write(
          '''<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/</d:href></d:response><d:response><d:href>/dav/%E7%AC%AC01%E9%9B%86.mkv</d:href><d:propstat><d:prop><d:getcontentlength>42</d:getcontentlength><d:resourcetype/><d:ishidden>1</d:ishidden></d:prop></d:propstat></d:response><d:response><d:href>https://other.example/private</d:href></d:response></d:multistatus>''',
        );
        await r.response.close();
      });
      final source = HttpSource(
        'http://127.0.0.1:${server.port}/dav/',
        webdav: true,
        user: 'u',
        password: 'p',
      );
      final entries = await source.list('');
      expect(entries.single.name, '第01集.mkv');
      expect(entries.single.size, 42);
      expect(entries.single.hidden, true);
      await source.close();
      await server.close(force: true);
    },
  );
  test(
    'JSON inactivity timeout resets on each chunk; cancellation closes a stalled request',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((r) async {
        if (r.uri.path == '/stall') return;
        try {
          r.response.bufferOutput = false;
          r.response.write('{"items":[');
          await r.response.flush();
          for (var i = 0; i < 5; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            r.response.write('${i == 0 ? '' : ','}$i');
            await r.response.flush();
          }
          r.response.write(']}');
          await r.response.close();
        } catch (_) {}
      });
      final transport = IoJsonTransport(
        inactivity: const Duration(milliseconds: 600),
      );
      final data = await transport.send(
        Uri.parse('http://127.0.0.1:${server.port}/stream'),
      );
      expect(data['items'], [0, 1, 2, 3, 4]);
      final cancel = CancelToken();
      final future = transport.send(
        Uri.parse('http://127.0.0.1:${server.port}/stall'),
        cancel: cancel,
      );
      final assertion = expectLater(future, throwsA(isA<Cancelled>()));
      cancel.cancel();
      await assertion;
      await expectLater(
        transport.send(Uri.parse('http://127.0.0.1:${server.port}/stall')),
        throwsA(isA<NetworkUnavailable>()),
      );
      await server.close(force: true);
    },
  );
}

class _SmbFixture implements SmbConnection {
  @override
  int get dialect => 0x0311;
  @override
  Future<List<Map<String, dynamic>>> shares() async => [
    {'name': 'video', 'hidden': false},
  ];
  final int? failAt;
  bool closed = false;
  final offsets = <int>[];
  _SmbFixture({this.failAt});
  @override
  Future<Uint8List> read(String path, int offset, int length) async {
    offsets.add(offset);
    if (failAt != null && offset >= failAt!) {
      throw const SocketException('fixture disconnect');
    }
    return Uint8List.fromList(List.generate(length, (i) => (i + offset) % 256));
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<List<Map<String, dynamic>>> list(String path) async => [];
  @override
  Future<Map<String, dynamic>> stat(String path) async => {};
}

class _SmbProbeFixture extends _SmbFixture {
  final _remainingVideo = Completer<void>();

  @override
  Future<Uint8List> read(String path, int offset, int length) async {
    if (length > 64 * 1024) await _remainingVideo.future;
    return super.read(path, offset, length);
  }

  @override
  Future<void> close() async {
    if (!_remainingVideo.isCompleted) _remainingVideo.complete();
    await super.close();
  }
}
