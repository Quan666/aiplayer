import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final chunked in [false, true]) {
    test(
      'album listing rejects oversized ${chunked ? 'chunked' : 'known-length'} response before XML parsing',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.multiStatus;
          final bytes = utf8.encode('<broken>${'x' * 2048}</broken>');
          if (!chunked) request.response.contentLength = bytes.length;
          try {
            request.response.add(bytes);
            await request.response.close();
          } catch (_) {}
        });
        final source = HttpSource(
          'http://127.0.0.1:${server.port}/',
          webdav: true,
          maxListingBytes: 1024,
          proxyResolver: (_, {cancel}) async => null,
        );
        try {
          await expectLater(
            source.list(''),
            throwsA(
              isA<AppFailure>().having(
                (e) => e.message,
                'message',
                contains('读取预算'),
              ),
            ),
          );
        } finally {
          await source.close();
          await server.close(force: true);
        }
      },
    );
  }

  test('album listing entry ceiling rejects partial results and leaves ordinary API compatible', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = HttpStatus.multiStatus;
      request.response.write(
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response><d:href>/photos/</d:href><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:response>'
        '${List.generate(3, (i) => '<d:response><d:href>/photos/$i.jpg</d:href><d:prop><d:getcontentlength>12</d:getcontentlength></d:prop></d:response>').join()}'
        '</d:multistatus>',
      );
      await request.response.close();
    });
    final source = HttpSource(
      'http://127.0.0.1:${server.port}/photos/',
      webdav: true,
      proxyResolver: (_, {cancel}) async => null,
    );
    try {
      await expectLater(
        source.listWithLimits('', maxEntries: 2),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains('超过 2 项'),
          ),
        ),
      );
      expect((await source.list('')).length, 3);
      expect((await source.listWithLimits('', maxEntries: 3)).length, 3);
    } finally {
      await source.close();
      await server.close(force: true);
    }
  });
}
