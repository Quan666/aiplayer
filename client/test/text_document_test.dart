import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/core/system_proxy.dart';
import 'package:aiplayer/data/text_document.dart';
import 'package:aiplayer/sources/source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => overrideSystemProxyPlatformForTesting('unsupported'));

  test('recognizes source and configuration documents as plain text', () {
    for (final name in [
      'FILE.TXT',
      'index.html',
      'main.py',
      'module.js',
      'data.json',
      'README.md',
      '.env',
      '.gitignore',
      'Makefile',
      'movie.srt',
    ]) {
      expect(isTextFile(name), isTrue, reason: name);
    }
    for (final name in ['photo.jpg', 'video.mkv', 'archive.zip', 'file.pdf']) {
      expect(isTextFile(name), isFalse, reason: name);
    }
  });

  test(
    'worker loads, normalizes and searches text without executing markup',
    () async {
      final root = await Directory.systemTemp.createTemp('text-document-');
      final file = File('${root.path}/index.html');
      await file.writeAsString(
        '\ufeff<script>alert(1)</script>\r\n你好\tWORLD\nworld',
      );
      final service = TextDocumentService(
        source: const {'kind': 'local'},
        documentsPath: root.path,
      );
      try {
        final document = await service.load(
          await LocalSource().stat(file.path),
        );
        expect(document.lines, [
          '<script>alert(1)</script>',
          '你好    WORLD',
          'world',
        ]);
        expect(document.maxColumns, greaterThanOrEqualTo(13));
        final search = await service.search('world');
        expect(search.matches.map((m) => (m.row, m.start, m.end)), [
          (1, 6, 11),
          (2, 0, 5),
        ]);
        expect(search.matchesByRow.keys, [1, 2]);
        expect(search.truncated, isFalse);
        expect(() => document.lines.add('changed'), throwsUnsupportedError);
        expect(() => search.matchesByRow[1]!.clear(), throwsUnsupportedError);
      } finally {
        service.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'worker supports UTF16, empty documents, bounded lines and results',
    () async {
      final root = await Directory.systemTemp.createTemp('text-encodings-');
      final file = File('${root.path}/document.txt');
      final service = TextDocumentService(
        source: const {'kind': 'local'},
        documentsPath: root.path,
      );
      Future<TextDocumentSnapshot> load(List<int> bytes) async {
        await file.writeAsBytes(bytes);
        return service.load(await LocalSource().stat(file.path));
      }

      try {
        expect((await load([0xff, 0xfe, 0x60, 0x4f, 0x7d, 0x59])).lines, [
          '你好',
        ]);
        expect((await load([0xfe, 0xff, 0x4f, 0x60, 0x59, 0x7d])).lines, [
          '你好',
        ]);
        expect((await load([])).lines, ['']);
        final long = await load(utf8.encode('a' * 5000));
        expect(long.lines.map((line) => line.length), [2048, 2048, 904]);
        await load(utf8.encode('a\n' * 10001));
        final search = await service.search('a');
        expect(search.matches, hasLength(10000));
        expect(search.truncated, isTrue);
        expect((await service.search('')).matches, isEmpty);
      } finally {
        service.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('rejects oversized, binary and malformed encoded text', () async {
    final root = await Directory.systemTemp.createTemp('text-limits-');
    final file = File('${root.path}/document.txt');
    final service = TextDocumentService(
      source: const {'kind': 'local'},
      documentsPath: root.path,
      maxTextBytes: 16,
    );
    Future<void> rejects(List<int> bytes, String message) async {
      await file.writeAsBytes(bytes);
      await expectLater(
        service.load(await LocalSource().stat(file.path)),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
      );
    }

    try {
      await rejects(List.filled(17, 65), '文本超过');
      await rejects([65, 0, 66], '二进制');
      await rejects([0xff], '编码');
      service.dispose();
      await expectLater(service.search('a'), throwsA(isA<Cancelled>()));
    } finally {
      service.dispose();
      await root.delete(recursive: true);
    }
  });

  test(
    'search crosses visual row splits and preserves actual newlines',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'text-search-boundary-',
      );
      final file = await File('${root.path}/long.txt')
          .writeAsString('${'x' * 2046}needle\nother');
      final service = TextDocumentService(
        source: const {'kind': 'local'},
        documentsPath: root.path,
      );
      try {
        await service.load(await LocalSource().stat(file.path));
        final search = await service.search('needle');
        expect(search.matches, hasLength(1));
        expect(search.matchesByRow.keys, [0, 1]);
        expect(search.matchesByRow[0]!.single.id, search.matches.single.id);
        expect(search.matchesByRow[1]!.single.id, search.matches.single.id);
        expect((await service.search('needleother')).matches, isEmpty);
        final multiline = await service.search('needle\nother');
        expect(multiline.matches, hasLength(1));
        expect(multiline.matchesByRow.keys, [0, 1, 2]);
      } finally {
        service.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('disposal during worker startup cancels without late work', () async {
    final root = await Directory.systemTemp.createTemp('text-startup-cancel-');
    final cache = Directory('${root.path}/cache');
    final service = TextDocumentService(
      source: const {'kind': 'webdav', 'url': 'http://127.0.0.1:9/'},
      documentsPath: root.path,
    );
    final result = service.prepareExternal(
      const SourceEntry(name: 'file', path: 'file'),
      cacheDirectory: cache.path,
    );
    final cancelled = expectLater(result, throwsA(isA<Cancelled>()));
    service.dispose();
    await cancelled;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await cache.exists(), isFalse);
    await root.delete(recursive: true);
  });

  test(
    'local external handoff retains the original file and creates no copy',
    () async {
      final root = await Directory.systemTemp.createTemp('external-local-');
      final file = await File('${root.path}/original.pdf')
          .writeAsString('original');
      final service = TextDocumentService(
        source: const {'kind': 'local'},
        documentsPath: root.path,
      );
      try {
        final path = await service.prepareExternal(
          await LocalSource().stat(file.path),
          cacheDirectory: '${root.path}/cache',
        );
        expect(path, file.path);
        await discardExternalFile(path);
        expect(await file.readAsString(), 'original');
        expect(await Directory('${root.path}/cache').exists(), isFalse);
      } finally {
        service.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'remote handoff downloads completely and discards failed handoff files',
    () async {
      final root = await Directory.systemTemp.createTemp('external-remote-');
      final bytes = utf8.encode('remote file content');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      final subscription = server.listen((request) async {
        requests.add(request.method);
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = bytes.length;
        if (request.method != 'HEAD') request.response.add(bytes);
        await request.response.close();
      });
      final service = TextDocumentService(
        source: {'kind': 'webdav', 'url': 'http://127.0.0.1:${server.port}/'},
        documentsPath: root.path,
      );
      try {
        await expectLater(
          service.prepareExternal(
            const SourceEntry(name: 'report.pdf', path: 'report.pdf'),
            cacheDirectory: '${root.path}/cache',
            maxCacheBytes: bytes.length - 1,
          ),
          throwsA(isA<AppFailure>()),
        );
        expect(requests, ['HEAD']);
        requests.clear();
        final path = await service.prepareExternal(
          const SourceEntry(name: 'report.pdf', path: 'report.pdf'),
          cacheDirectory: '${root.path}/cache',
          maxCacheBytes: bytes.length * 2,
        );
        expect(await File(path).readAsBytes(), bytes);
        expect(requests, ['HEAD', 'GET']);
        await expectLater(
          service.prepareExternal(
            const SourceEntry(name: 'another.pdf', path: 'another.pdf'),
            cacheDirectory: '${root.path}/cache',
            maxCacheBytes: bytes.length,
          ),
          throwsA(isA<AppFailure>()),
        );
        expect(
          await File(path).readAsBytes(),
          bytes,
          reason: 'A smaller limit blocks new handoffs without deleting a file another app may still use.',
        );
        await cleanupExternalFileCache('${root.path}/cache');
        expect(await File(path).exists(), isTrue);
        await discardExternalFile(path);
        expect(await File(path).exists(), isFalse);

        final collision = await service.prepareExternal(
          const SourceEntry(name: '.complete', path: '.complete'),
          cacheDirectory: '${root.path}/cache',
        );
        expect(await File(collision).readAsBytes(), bytes);
        await discardExternalFile(collision);
      } finally {
        service.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'disposing during a remote download cancels it and removes partial files',
    () async {
      final root = await Directory.systemTemp.createTemp('external-cancel-');
      final cache = Directory('${root.path}/cache');
      final started = Completer<void>();
      final finish = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.contentLength = 1024;
        if (request.method != 'HEAD') {
          request.response.add(List.filled(64, 65));
          await request.response.flush();
          started.complete();
          await finish.future;
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      final service = TextDocumentService(
        source: {'kind': 'webdav', 'url': 'http://127.0.0.1:${server.port}/'},
        documentsPath: root.path,
      );
      try {
        final download = service.prepareExternal(
          const SourceEntry(name: 'large.zip', path: 'large.zip'),
          cacheDirectory: cache.path,
        );
        final cancelled = expectLater(download, throwsA(isA<Cancelled>()));
        await started.future.timeout(const Duration(seconds: 10));
        service.dispose();
        await cancelled;
        for (var count = 0; count < 100; count++) {
          if (!await cache.exists() || await cache.list().isEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(!await cache.exists() || await cache.list().isEmpty, isTrue);
      } finally {
        finish.complete();
        service.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'event cleanup preserves active staging and fresh successful handoffs',
    () async {
      final root = await Directory.systemTemp.createTemp('external-cleanup-');
      final fresh = await Directory('${root.path}/open-fresh').create();
      await File('${fresh.path}/.complete').writeAsString('');
      final partial = await Directory('${root.path}/open-active').create();
      await File('${partial.path}/.download.part').writeAsString('partial');
      try {
        await cleanupExternalFileCache(root.path);
        expect(await fresh.exists(), isTrue);
        expect(await partial.exists(), isTrue);
        await cleanupExternalFileCache(root.path, removeIncomplete: true);
        expect(await fresh.exists(), isTrue);
        expect(await partial.exists(), isFalse);
        await cleanupExternalFileCache(root.path, maxAge: Duration.zero);
        expect(await fresh.exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'startup cleanup cutoff preserves a newer concurrent download',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'external-cleanup-race-',
      );
      final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
      final partial = await Directory('${root.path}/open-new-download')
          .create();
      await File('${partial.path}/.download.part')
          .writeAsString('still downloading');
      try {
        await cleanupExternalFileCache(
          root.path,
          removeIncomplete: true,
          incompleteBefore: cutoff,
        );
        expect(await partial.exists(), isTrue);
        expect(
          await File('${partial.path}/.download.part').readAsString(),
          'still downloading',
        );
        await cleanupExternalFileCache(root.path, removeIncomplete: true);
        expect(await partial.exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
