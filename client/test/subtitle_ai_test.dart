import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:aiplayer/subtitles/document.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAi implements SubtitleAiTransport {
  final Future<String> Function(Map<String, dynamic>, CancelToken) handler;
  int calls = 0;
  FakeAi(this.handler);
  @override
  Future<String> complete(
    SubtitleAiConfig config,
    Map<String, dynamic> body,
    CancelToken cancel,
  ) {
    calls++;
    return handler(body, cancel);
  }

  @override
  Future<List<String>> models(
    SubtitleAiConfig config,
    CancelToken cancel,
  ) async => ['test'];
}

List<Map> _cues(Map<String, dynamic> body) {
  final user =
      jsonDecode((body['messages'] as List).last['content'] as String) as Map;
  return (user['cues'] as List).cast<Map>();
}

String translated(Map<String, dynamic> body) => jsonEncode(
  _cues(body).map((c) => {'id': c['id'], 'text': '译文 ${c['id']}'}).toList(),
);
SubtitleDocument _document([int count = 1]) => SubtitleDocument(
  List.generate(
    count,
    (i) => '${i + 1}\n00:00:01,000 --> 00:00:02,000\nSource $i\n',
  ).join('\n'),
  'srt',
);
void main() {
  test(
    'synopsis translation sends only the text and target language',
    () async {
      final fake = FakeAi((body, _) async {
        expect(body['model'], 'synopsis-model');
        final messages = body['messages'] as List;
        final user = jsonDecode(messages.last['content'] as String) as Map;
        expect(user, {
          'targetLanguage': '简体中文',
          'text': 'A pilot returns home.\nA new journey begins.',
        });
        expect(jsonEncode(body), isNot(contains('secret-key')));
        expect(jsonEncode(body), isNot(contains('subtitle-only instruction')));
        return ' 飞行员返回故乡。\n新的旅程开始了。 ';
      });
      expect(
        await translateText(
          'A pilot returns home.\nA new journey begins.',
          config: SubtitleAiConfig(
            model: 'synopsis-model',
            token: 'secret-key',
            prompt: 'subtitle-only instruction',
          ),
          cancel: CancelToken(),
          transport: fake,
        ),
        '飞行员返回故乡。\n新的旅程开始了。',
      );
      expect(fake.calls, 1);
    },
  );
  test(
    'synopsis validation avoids requests and rejects empty replies',
    () async {
      final fake = FakeAi((_, _) async => ' ');
      final config = SubtitleAiConfig(model: 'm');
      expect(
        await translateText(
          ' ',
          config: config,
          cancel: CancelToken(),
          transport: fake,
        ),
        '',
      );
      await expectLater(
        translateText(
          'Synopsis',
          config: SubtitleAiConfig(model: ''),
          cancel: CancelToken(),
          transport: fake,
        ),
        throwsA(isA<AppFailure>()),
      );
      await expectLater(
        translateText(
          'a' * 32001,
          config: config,
          cancel: CancelToken(),
          transport: fake,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(fake.calls, 0);
      await expectLater(
        translateText(
          'Synopsis',
          config: config,
          cancel: CancelToken(),
          transport: fake,
        ),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test('cancelled synopsis results are never returned to the caller', () async {
    final pending = Completer<String>();
    final fake = FakeAi((_, _) => pending.future);
    final cancel = CancelToken();
    final assertion = expectLater(
      translateText(
        'Synopsis',
        config: SubtitleAiConfig(model: 'm'),
        cancel: cancel,
        transport: fake,
      ),
      throwsA(isA<Cancelled>()),
    );
    cancel.cancel();
    pending.complete('迟到结果');
    await assertion;
  });
  test(
    'provider URLs are normalized and reject embedded credentials and token queries',
    () {
      expect(
        SubtitleAiConfig.normalizeOrigin(
          'https://api.example/v1/chat/completions/',
        ).toString(),
        'https://api.example/v1',
      );
      for (final address in [
        'https://user:key@example/v1',
        'https://example/v1?token=key',
        'file:///tmp/api',
        'https://example/v1#key',
      ]) {
        expect(
          () => SubtitleAiConfig.normalizeOrigin(address),
          throwsA(isA<AppFailure>()),
        );
      }
    },
  );
  test(
    'AI cache isolates credentials, endpoint, model and target language',
    () async {
      final cache = <String, Map<String, dynamic>>{};
      final fake = FakeAi((body, _) async => translated(body));
      final translator = SubtitleTranslator(
        transport: fake,
        load: (key) => cache[key],
        save: (key, value) => cache[key] = value,
      );
      for (final config in [
        SubtitleAiConfig(model: 'm', token: 'one'),
        SubtitleAiConfig(model: 'm', token: 'one'),
        SubtitleAiConfig(model: 'm', token: 'two'),
        SubtitleAiConfig(model: 'other', token: 'one'),
        SubtitleAiConfig(model: 'm', token: 'one', target: 'English'),
        SubtitleAiConfig(
          model: 'm',
          token: 'one',
          origin: 'https://other.example/v1',
        ),
      ]) {
        expect(
          await translator.translate(_document(), config, CancelToken()),
          contains('译文'),
        );
      }
      expect(fake.calls, 5);
      expect(
        cache.keys.any((key) => key.contains('one') || key.contains('Source')),
        false,
      );
    },
  );
  test(
    'translation sends only dialogue and preserves completed batches on retry',
    () async {
      final cache = <String, Map<String, dynamic>>{};
      var failSecond = true, calls = 0;
      final batches = <List<int>>[];
      final fake = FakeAi((body, _) async {
        calls++;
        final user = jsonDecode((body['messages'] as List).last['content']);
        expect(
          (user as Map).keys,
          unorderedEquals(['targetLanguage', 'previousContext', 'cues']),
        );
        batches.add(_cues(body).map((c) => c['id'] as int).toList());
        if (calls == 2 && failSecond) throw const AppFailure('模拟断网');
        return translated(body);
      });
      final translator = SubtitleTranslator(
        transport: fake,
        load: (key) => cache[key],
        save: (key, value) => cache[key] = value,
      );
      final document = _document(31), config = SubtitleAiConfig(model: 'm');
      await expectLater(
        translator.translate(document, config, CancelToken()),
        throwsA(isA<AppFailure>()),
      );
      expect((cache.values.single['values'] as Map).length, 30);
      failSecond = false;
      expect(
        await translator.translate(document, config, CancelToken()),
        contains('译文 30'),
      );
      expect(batches.map((b) => b.length), [30, 1, 1]);
      expect(batches.last, [30]);
    },
  );
  test('late cancelled model results cannot populate cache', () async {
    final pending = Completer<String>(),
        cache = <String, Map<String, dynamic>>{};
    final fake = FakeAi((body, token) => pending.future);
    final translator = SubtitleTranslator(
      transport: fake,
      load: (k) => cache[k],
      save: (k, v) => cache[k] = v,
    );
    final token = CancelToken();
    final future = translator.translate(
      _document(),
      SubtitleAiConfig(model: 'm'),
      token,
    );
    final assertion = expectLater(future, throwsA(isA<Cancelled>()));
    token.cancel();
    pending.complete('[{"id":0,"text":"迟到结果"}]');
    await assertion;
    expect(cache, isEmpty);
  });
  test(
    'all batch IDs, placeholders and new formatting must validate atomically',
    () {
      final document = SubtitleDocument(
        '1\n00:00:01,000 --> 00:00:02,000\n<i>hello</i>\n',
        'srt',
      );
      for (final value in [
        '[]',
        '[{"id":1,"text":"wrong"}]',
        '[{"id":0,"text":"lost tags"}]',
        '[{"id":0,"text":"⟦S1⟧wrong⟦S0⟧"}]',
        '[{"id":0,"text":"⟦S0⟧<script>⟦S1⟧"}]',
      ]) {
        expect(
          () => validateTranslationBatch(document, document.cues, value),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(
        validateTranslationBatch(
          document,
          document.cues,
          '```json\n[{"id":0,"text":"⟦S0⟧你好⟦S1⟧"}]\n```',
        )[0],
        '⟦S0⟧你好⟦S1⟧',
      );
    },
  );

  late HttpServer server;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
  tearDown(() async {
    await server.close(force: true);
  });
  SubtitleAiConfig config() => SubtitleAiConfig(
    origin: 'http://127.0.0.1:${server.port}/v1',
    model: 'test',
    token: 'local-test-key',
  );
  test(
    'JSON chat and explicit model-list requests use configured endpoint and auth',
    () async {
      server.listen((request) async {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer local-test-key',
        );
        if (request.uri.path == '/v1/models') {
          request.response.write('{"data":[{"id":"z"},{"id":"a"}]}');
        } else {
          expect(request.uri.path, '/v1/chat/completions');
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          expect(body['model'], 'test');
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '[{"id":0,"text":"你好"}]'},
                  'finish_reason': 'stop',
                },
              ],
            }),
          );
        }
        await request.response.close();
      });
      final transport = IoSubtitleAiTransport();
      expect(await transport.models(config(), CancelToken()), ['a', 'z']);
      expect(
        await transport.complete(config(), {'model': 'test'}, CancelToken()),
        contains('你好'),
      );
    },
  );
  test(
    'AI completion and model list use the resolved proxy before destination DNS',
    () async {
      final paths = <String>[];
      server.listen((request) async {
        expect(request.uri.host, 'unresolvable.invalid');
        paths.add(request.uri.path);
        await request.drain();
        if (request.uri.path == '/v1/models') {
          request.response.write('{"data":[{"id":"test"}]}');
        } else {
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'recognized'},
                  'finish_reason': 'stop',
                },
              ],
            }),
          );
        }
        await request.response.close();
      });
      final transport = IoSubtitleAiTransport(
        proxyResolver: (uri, {cancel}) async =>
            'PROXY 127.0.0.1:${server.port}',
      );
      expect(
        await transport.complete(
          SubtitleAiConfig(
            origin: 'http://unresolvable.invalid/v1',
            model: 'test',
          ),
          {'model': 'test'},
          CancelToken(),
        ),
        'recognized',
      );
      expect(
        await transport.models(
          SubtitleAiConfig(
            origin: 'http://unresolvable.invalid/v1',
            model: 'test',
          ),
          CancelToken(),
        ),
        ['test'],
      );
      expect(paths, ['/v1/chat/completions', '/v1/models']);
    },
  );
  test(
    'SSE fragmented Unicode and usage-only events complete without losing deltas',
    () async {
      server.listen((request) async {
        await request.drain();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        final response =
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '你'},
                },
              ],
            })}\n\ndata: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '好'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\ndata: {"choices":[],"usage":{"total_tokens":8}}\n\ndata: [DONE]\n\n';
        final bytes = utf8.encode(response);
        for (var offset = 0; offset < bytes.length; offset += 7) {
          request.response.add(
            bytes.sublist(offset, (offset + 7).clamp(0, bytes.length)),
          );
          await request.response.flush();
        }
        await request.response.close();
      });
      expect(
        await IoSubtitleAiTransport().complete(config(), {}, CancelToken()),
        '你好',
      );
    },
  );
  test('truncated streaming output is an error', () async {
    server.listen((request) async {
      await request.drain();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
      );
      await request.response.close();
    });
    await expectLater(
      IoSubtitleAiTransport().complete(config(), {}, CancelToken()),
      throwsA(
        isA<AppFailure>().having((e) => e.message, 'message', contains('中断')),
      ),
    );
  });
  test('redirect is blocked rather than forwarding API credentials', () async {
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain();
      request.response.statusCode = 302;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${server.port}/unexpected',
      );
      await request.response.close();
    });
    await expectLater(
      IoSubtitleAiTransport().complete(config(), {}, CancelToken()),
      throwsA(isA<AppFailure>().having((e) => e.status, 'status', 302)),
    );
    expect(requests, 1);
  });
  test('idle timeout and explicit cancellation stop waiting', () async {
    server.listen((request) async {
      await request.drain();
    });
    await expectLater(
      IoSubtitleAiTransport(
        inactivity: const Duration(milliseconds: 40),
      ).complete(config(), {}, CancelToken()),
      throwsA(
        isA<AppFailure>().having((e) => e.message, 'message', contains('长时间')),
      ),
    );
    final token = CancelToken();
    final request = IoSubtitleAiTransport().complete(config(), {}, token);
    final check = expectLater(request, throwsA(isA<Cancelled>()));
    token.cancel();
    await check;
  });
}
