import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:aiplayer/cast/bridge.dart';
import 'package:aiplayer/cast/dlna.dart';
import 'package:aiplayer/cast/start_guard.dart';
import 'package:aiplayer/cast/position.dart';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

String description([String endpoint = '/control']) =>
    '''<?xml version="1.0"?>
<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>客厅 &amp; TV</friendlyName><UDN>uuid:local-test</UDN><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<controlURL>$endpoint</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
<controlURL>/volume</controlURL></service></serviceList></device></root>''';
void main() {
  test(
    'cancelled cast start closes a late source without waiting for its connection',
    () async {
      final guard = CastStartGuard();
      final source = Completer<Object>();
      final released = Completer<void>();
      var releaseCount = 0;
      final start = guard.run(() async {
        await guard.acquire(source.future, (_) {
          releaseCount++;
          released.complete();
        });
        fail('Cancelled source must not become an active cast');
      });
      guard.cancel();
      await expectLater(start, throwsA(isA<Cancelled>()));
      await guard.settle().timeout(const Duration(milliseconds: 100));
      source.complete(Object());
      await released.future;
      expect(releaseCount, 1);
    },
  );

  test(
    'cancel during renderer assignment settles before final Stop and never sends late Play',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final assigned = Completer<void>(), releaseResponse = Completer<void>();
      final actions = <String>[];
      server.listen((request) async {
        final document = XmlDocument.parse(
          await utf8.decoder.bind(request).join(),
        );
        final action = document.descendants
            .whereType<XmlElement>()
            .firstWhere((e) => e.name.prefix == 'u')
            .name
            .local;
        actions.add(action);
        if (action == 'SetAVTransportURI') {
          assigned.complete();
          await releaseResponse.future;
        }
        try {
          request.response.write('<ok/>');
          await request.response.close();
        } catch (_) {}
      });
      final device = DlnaDevice.parse(
        Uri.parse('http://127.0.0.1:${server.port}/description.xml'),
        description(),
      );
      final client = DlnaClient(), finalClient = DlnaClient();
      final guard = CastStartGuard();
      try {
        final start = guard.run(
          () => client.open(
            device,
            Uri.parse('http://127.0.0.1/temporary/video.mp4'),
            'test',
            'video/mp4',
          ),
        );
        final failed = expectLater(start, throwsA(isA<Cancelled>()));
        await assigned.future;
        guard.cancel();
        client.close();
        await guard.settle();
        await finalClient.stop(device);
        releaseResponse.complete();
        await failed;
        expect(actions, ['SetAVTransportURI', 'Stop']);
      } finally {
        if (!releaseResponse.isCompleted) releaseResponse.complete();
        client.close();
        finalClient.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'local resume requires observed remote position, not just a successful seek command',
    () async {
      var current = Duration.zero;
      expect(
        await restoreCastPosition(
          target: const Duration(seconds: 30),
          seek: (_) async {
            Future<void>.delayed(const Duration(milliseconds: 20), () {
              current = const Duration(seconds: 30);
            });
          },
          position: () => current,
        ),
        isTrue,
      );
      expect(
        await restoreCastPosition(
          target: const Duration(seconds: 90),
          seek: (_) async {},
          position: () => current,
          deadline: const Duration(milliseconds: 60),
        ),
        isFalse,
      );
      expect(
        await restoreCastPosition(
          target: const Duration(seconds: 30),
          seek: (_) async {
            throw StateError('failed');
          },
          position: () => current,
        ),
        isFalse,
      );
      expect(
        await restoreCastPosition(
          target: const Duration(seconds: 30),
          seek: (_) async {},
          position: () => current,
          cancelled: () => true,
        ),
        isFalse,
      );
    },
  );

  test(
    'relay source and unsupported range errors are reported safely to the player',
    () async {
      final errors = <AppFailure>[];
      final source = _FailingSource();
      final bridge = await CastBridge.open(
        source,
        '/private/file.mkv',
        localAddress: InternetAddress.loopbackIPv4,
        renderer: InternetAddress.loopbackIPv4,
        onError: errors.add,
      );
      final client = HttpClient();
      try {
        try {
          final request = await client.getUrl(bridge.uri);
          final response = await request.close();
          await response.drain<void>();
        } catch (_) {
          /* A stream that ended early fails at the HTTP client too. */
        }
        expect(errors.single.message, contains('读取投屏视频失败'));
        expect(errors.single.message, isNot(contains('/private')));
        final request = await client.getUrl(bridge.uri);
        request.headers.set('Range', 'bytes=900-');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 416);
        expect(errors.last.message, contains('范围无效'));
      } finally {
        client.close(force: true);
        await bridge.close();
      }
    },
  );

  test('renderer control endpoints stay on the selected local address', () {
    final uri = Uri.parse('http://192.168.1.20:8000/description.xml');
    final device = DlnaDevice.parse(uri, description());
    expect(device.name, '客厅 & TV');
    expect(device.control.toString(), 'http://192.168.1.20:8000/control');
    for (final location in [
      'http://8.8.8.8/tv',
      'https://example.com/tv',
      'http://user:password@192.168.1.20/tv',
    ]) {
      expect(
        () => DlnaDevice.parse(Uri.parse(location), description()),
        throwsA(isA<AppFailure>()),
      );
    }
    expect(
      () => DlnaDevice.parse(uri, description('http://8.8.8.8/control')),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => DlnaDevice.parse(uri, '<!DOCTYPE root>${description()}'),
      throwsA(isA<AppFailure>()),
    );
  });

  test(
    'SOAP actions escape video metadata and read remote position without uploading content',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final requests = <(String, Map<String, String>)>[];
      server.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType(
          'text',
          'xml',
          charset: 'utf-8',
        );
        if (request.method == 'GET') {
          response.write(description());
        } else {
          final bytes = await request.fold<List<int>>(
            <int>[],
            (result, chunk) => result..addAll(chunk),
          );
          expect(request.contentLength, bytes.length);
          expect(request.headers.value('transfer-encoding'), isNull);
          final body = XmlDocument.parse(utf8.decode(bytes));
          final action = body.descendants.whereType<XmlElement>().firstWhere(
            (e) => e.name.prefix == 'u',
          );
          final args = {
            for (final child in action.childElements)
              child.name.local: child.innerText,
          };
          requests.add((action.name.local, args));
          response.write(
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
            '<u:${action.name.local}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
            '<RelTime>00:01:02.500</RelTime><TrackDuration>00:24:00</TrackDuration>'
            '</u:${action.name.local}Response></s:Body></s:Envelope>',
          );
        }
        await response.close();
      });
      final client = DlnaClient();
      try {
        final device = await client.describe(
          Uri.parse('http://127.0.0.1:${server.port}/description.xml'),
        );
        final video = Uri.parse('http://192.168.1.10:3333/temporary/video.mp4');
        await client.open(device, video, '作品 <01> & 中文', 'video/mp4');
        await client.pause(device);
        await client.seek(device, const Duration(seconds: 62));
        await client.volume(device, 35);
        final position = await client.command(device, 'GetPositionInfo');
        await client.stop(device);
        expect(requests.map((r) => r.$1), [
          'SetAVTransportURI',
          'Play',
          'Pause',
          'Seek',
          'SetVolume',
          'GetPositionInfo',
          'Stop',
        ]);
        expect(requests.first.$2['CurrentURI'], video.toString());
        final metadata = XmlDocument.parse(
          requests.first.$2['CurrentURIMetaData']!,
        );
        expect(
          metadata.findAllElements('dc:title').single.innerText,
          '作品 <01> & 中文',
        );
        expect(requests[3].$2, {
          'InstanceID': '0',
          'Unit': 'REL_TIME',
          'Target': '00:01:02',
        });
        expect(
          DlnaClient.parseTime(position['RelTime']),
          const Duration(milliseconds: 62500),
        );
      } finally {
        client.close();
        await server.close(force: true);
      }
    },
  );

  test('device errors expose numeric code, not returned secrets', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 500;
      request.response.write(
        '<error><errorCode>714</errorCode><private>secret-token</private></error>',
      );
      await request.response.close();
    });
    final client = DlnaClient();
    final location = Uri.parse(
      'http://127.0.0.1:${server.port}/description.xml',
    );
    try {
      await expectLater(
        client.play(DlnaDevice.parse(location, description())),
        throwsA(
          isA<AppFailure>()
              .having((e) => e.message, 'numeric', contains('714'))
              .having(
                (e) => e.message,
                'safe',
                isNot(contains('secret-token')),
              ),
        ),
      );
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test(
    'selected renderer relay supports ranges and HEAD, denies foreign clients and tokens',
    () async {
      final source = _MemorySource();
      final bridge = await CastBridge.open(
        source,
        'private/directory/movie.mkv',
        localAddress: InternetAddress.loopbackIPv4,
        renderer: InternetAddress.loopbackIPv4,
      );
      final client = HttpClient();
      Future<(int, List<int>, HttpHeaders)> request(
        Uri uri, {
        String method = 'GET',
        String? range,
      }) async {
        final request = await client.openUrl(method, uri);
        if (range != null) request.headers.set('Range', range);
        final response = await request.close();
        return (
          response.statusCode,
          await response.expand((b) => b).toList(),
          response.headers,
        );
      }

      try {
        expect(bridge.uri.toString(), isNot(contains('private')));
        final partial = await request(bridge.uri, range: 'bytes=5-9');
        expect(partial.$1, 206);
        expect(partial.$2, [5, 6, 7, 8, 9]);
        expect(partial.$3.value('content-type'), 'video/x-matroska');
        expect(partial.$3.value('content-range'), 'bytes 5-9/100');
        final reads = source.reads;
        final head = await request(bridge.uri, method: 'HEAD');
        expect(head.$1, 200);
        expect(head.$2, isEmpty);
        expect(source.reads, reads);
        expect(
          (await request(bridge.uri.replace(path: '/wrong/video.mkv'))).$1,
          404,
        );
        expect((await request(bridge.uri, range: 'bytes=500-')).$1, 416);
        final foreign = await Socket.connect(
          bridge.uri.host,
          bridge.uri.port,
          sourceAddress: InternetAddress('127.0.0.2'),
        );
        foreign.write(
          'GET ${bridge.uri.path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n',
        );
        final foreignResponse = await utf8.decoder.bind(foreign).join();
        expect(foreignResponse, startsWith('HTTP/1.1 404'));
        foreign.destroy();
      } finally {
        client.close(force: true);
        await bridge.close();
      }
      await expectLater(
        Socket.connect(bridge.uri.host, bridge.uri.port),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'public destinations and nonseekable offsets never expose file bytes',
    () async {
      final source = _MemorySource(seekable: false);
      await expectLater(
        CastBridge.open(
          source,
          'video',
          localAddress: InternetAddress.loopbackIPv4,
          renderer: InternetAddress('8.8.8.8'),
        ),
        throwsA(isA<AppFailure>()),
      );
      final bridge = await CastBridge.open(
        source,
        'video',
        localAddress: InternetAddress.loopbackIPv4,
        renderer: InternetAddress.loopbackIPv4,
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(bridge.uri);
        request.headers.set('Range', 'bytes=5-');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 416);
        expect(source.reads, 0);
      } finally {
        client.close(force: true);
        await bridge.close();
      }
    },
  );
}

class _MemorySource extends SourceAdapter {
  final bool seekable;
  int reads = 0;
  _MemorySource({this.seekable = true});
  @override
  Future<SourceEntry> stat(String path) async =>
      SourceEntry(path: path, name: 'video.mkv', size: 100, seekable: seekable);
  @override
  Future<List<SourceEntry>> list(String path) async => [];
  @override
  Stream<Uint8List> read(String path, int start, int end) async* {
    reads++;
    yield Uint8List.fromList(List.generate(end - start + 1, (i) => start + i));
  }
}

class _FailingSource extends _MemorySource {
  @override
  Stream<Uint8List> read(String path, int start, int end) async* {
    throw const FileSystemException(
      'sensitive private failure',
      '/private/file.mkv',
    );
  }
}
