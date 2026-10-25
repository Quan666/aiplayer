import 'dart:async';
import 'dart:convert';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class _Transport implements SubtitleAiTransport {
  final List<Map<String, dynamic>> bodies = [];
  final List<SubtitleAiConfig> configs = [];
  FutureOr<String> Function() reply;
  _Transport(this.reply);
  @override
  Future<String> complete(
    SubtitleAiConfig config,
    Map<String, dynamic> body,
    CancelToken cancel,
  ) async {
    configs.add(config);
    bodies.add(body);
    return await reply();
  }

  Map<String, dynamic> get input =>
      jsonDecode((bodies.last['messages'] as List).last['content'])
          as Map<String, dynamic>;
  @override
  Future<List<String>> models(
    SubtitleAiConfig config,
    CancelToken cancel,
  ) async => [];
}

Map<String, dynamic> _identityJson([Map<String, dynamic> changes = const {}]) =>
    {
      'name': '葬送のフリーレン',
      'titles': {
        'zh': '葬送的芙莉莲',
        'en': 'Frieren: Beyond Journey’s End',
        'ja': '葬送のフリーレン',
      },
      'aliases': ['Sousou no Frieren'],
      'kind': 'anime',
      'season': 1,
      'episode': 12.5,
      'year': 2023,
      'confidence': .98,
      ...changes,
    };

String _selection(
  String? id, {
  String provider = 'bangumi',
  String type = 'tv',
  String status = 'match',
  double confidence = .98,
}) => jsonEncode({
  'status': status,
  'selection': id == null
      ? null
      : {'provider': provider, 'mediaType': type, 'id': id},
  'confidence': confidence,
});

String _batchResponse(Map<String, dynamic> input) => jsonEncode({
  'items': [
    for (final item in (input['items'] as List).reversed)
      {
        'id': item['id'],
        'identity': _identityJson({
          'episode': int.parse(
            RegExp(r'(\d+)\.mkv$').firstMatch(item['fileName'])![1]!,
          ),
        }),
      },
  ],
});

void main() {
  late AppStore store;
  late _Transport transport;
  late MediaAiRecognition service;
  final config = SubtitleAiConfig(
    model: 'recognition-model',
    token: 'token',
    prompt: 'DO NOT USE THE SUBTITLE PROMPT',
  );
  const identity = AiMediaIdentity(
    name: '葬送のフリーレン',
    kind: 'anime',
    season: '1',
    confidence: .98,
  );
  setUp(() {
    store = AppStore(':memory:');
    transport = _Transport(() => jsonEncode(_identityJson()));
    service = MediaAiRecognition(store, transport: transport);
  });
  tearDown(() => store.dispose());
  Future<AiMediaIdentity> analyze(
    String name, {
    SubtitleAiConfig? using,
    CancelToken? cancel,
  }) => service.analyzeFilename(
    name,
    config: using ?? config,
    cancel: cancel ?? CancelToken(),
  );
  Future<Map<String, AiMediaIdentity>> batch(
    List<String> names, {
    SubtitleAiConfig? using,
    CancelToken? cancel,
  }) => service.analyzeFilenames(
    names,
    config: using ?? config,
    cancel: cancel ?? CancelToken(),
  );
  Future<Map<String, dynamic>?> confirm(
    List<Map<String, dynamic>> candidates, {
    AiMediaIdentity using = identity,
    CancelToken? cancel,
  }) => service.confirm(
    using,
    candidates,
    config: config,
    cancel: cancel ?? CancelToken(),
  );
  Map<String, dynamic> candidate(
    String id, {
    String provider = 'bangumi',
    String type = 'tv',
    String? season,
  }) => {
    'provider': provider,
    'mediaType': type,
    'id': id,
    'name': '葬送のフリーレン',
    'season': ?season,
  };

  test(
    'only sends basename and keeps original plus multilingual search names',
    () async {
      final result = await analyze(
        '/private/home/alice/Shows/[Group] Frieren 12.5.mkv',
      );
      expect(transport.input, {'fileName': '[Group] Frieren 12.5.mkv'});
      expect(jsonEncode(transport.bodies), isNot(contains('/private')));
      expect(jsonEncode(transport.bodies), isNot(contains('DO NOT USE')));
      expect(transport.configs.single.prompt, 'media-recognition-v2');
      expect(result.name, '葬送のフリーレン');
      expect(result.searchNames, [
        '葬送のフリーレン',
        '葬送的芙莉莲',
        'Frieren: Beyond Journey’s End',
        'Sousou no Frieren',
      ]);
      expect(result.episode, '12.5');
      expect(result.season, '1');
      expect(result.year, 2023);
      await analyze(r'C:\Users\another\[Group] Frieren 12.5.mkv');
      expect(transport.bodies, hasLength(1));
    },
  );

  test(
    'rejects URLs, query strings and invalid names before calling AI',
    () async {
      for (final name in [
        'https://host/video.mkv?secret=abc',
        'file:///private/video.mkv',
        'data:video/secret',
        'smb://server/user/video.mkv',
        '/only/directory/',
        'video.mkv?token=secret',
        'video.mkv?secret',
        'video?token=secret',
        'name\nvideo.mkv',
      ]) {
        await expectLater(
          analyze(name),
          throwsA(isA<AppFailure>()),
          reason: name,
        );
      }
      expect(transport.bodies, isEmpty);
    },
  );

  for (final mode in ['single', 'batch', 'folder']) {
    test(
      '$mode AI recognition preserves title punctuation and brackets',
      () async {
        const title = '用【循环利息】强制收回借出的魔力：谁？ Why? (再会) [Re:Start]';
        const fileName = '$title - 02.mkv';
        final identityJson = _identityJson({
          'name': title,
          'titles': {'zh': title, 'en': '', 'ja': ''},
          'aliases': [],
          'episode': 2,
        });
        transport.reply = () => jsonEncode(
          mode == 'single'
              ? identityJson
              : {
                  'items': [
                    {'id': '0', 'identity': identityJson},
                  ],
                },
        );
        final result = switch (mode) {
          'single' => await analyze(fileName),
          'batch' => (await batch([fileName]))[fileName]!,
          _ => (await service.analyzeFolderFilenames(
            [fileName],
            config: config,
            cancel: CancelToken(),
          ))[fileName]!,
        };
        expect(result.name, title);
        expect(result.searchNames, [title]);
        expect(result.fileName, fileName);
        final messages = transport.bodies.single['messages'] as List;
        expect(
          messages.first['content'],
          contains('including meaningful punctuation'),
        );
        expect(messages.last['content'], contains(fileName));
      },
    );
  }

  test('filename question marks following title dots are not URL suffixes', () {
    expect(MediaAiRecognition.filenameOnly('Dr.Who?.mkv'), 'Dr.Who?.mkv');
  });

  test(
    'old name rules cannot reuse a cached identity that lost brackets',
    () async {
      const filename = '用【循环利息】强制收回借出的魔力 - 01.mkv';
      final oldConfig = SubtitleAiConfig(
        origin: config.origin.toString(),
        token: config.token,
        model: config.model,
        target: 'multilingual metadata',
        prompt: 'media-recognition-v1',
      );
      final oldKey = sha256.convert(
        utf8.encode(jsonEncode([1, filename, oldConfig.identity])),
      );
      store.setLocal(
        'media-ai-filename:$oldKey',
        _identityJson({'name': '用 强制收回借出的魔力'}),
      );
      transport.reply = () =>
          jsonEncode(_identityJson({'name': '用【循环利息】强制收回借出的魔力'}));
      expect((await analyze(filename)).name, '用【循环利息】强制收回借出的魔力');
      expect(transport.bodies, hasLength(1));
      await analyze(filename);
      expect(transport.bodies, hasLength(1));
    },
  );

  test(
    'supports season zero and isolates cache by source, model, credential and origin',
    () async {
      transport.reply = () =>
          jsonEncode(_identityJson({'season': 0, 'episode': 0}));
      expect((await analyze('special.mkv')).season, '0');
      await analyze(
        'special.mkv',
        using: SubtitleAiConfig(
          model: config.model,
          token: config.token,
          target: 'English',
          prompt: 'different subtitle prompt',
        ),
      );
      expect(transport.bodies, hasLength(1));
      await analyze('other.mkv');
      await analyze(
        'special.mkv',
        using: SubtitleAiConfig(model: 'other', token: config.token),
      );
      await analyze(
        'special.mkv',
        using: SubtitleAiConfig(model: config.model, token: 'other-token'),
      );
      await analyze(
        'special.mkv',
        using: SubtitleAiConfig(
          origin: 'https://other.example/v1',
          model: config.model,
          token: config.token,
        ),
      );
      expect(transport.bodies, hasLength(5));
      await expectLater(
        analyze('special.mkv', cancel: CancelToken()..cancel()),
        throwsA(isA<Cancelled>()),
      );
      expect(transport.bodies, hasLength(5));
    },
  );

  test(
    'rejects incomplete, extra-field, malformed and out-of-bound identities without caching',
    () async {
      final responses = [
        '```json\n${jsonEncode(_identityJson())}\n```',
        '{"name":"Partial"',
        jsonEncode(_identityJson()..remove('confidence')),
        jsonEncode(_identityJson({'poster': 'https://invented/image.jpg'})),
        jsonEncode(_identityJson({'season': -1})),
        jsonEncode(_identityJson({'season': 1000})),
        jsonEncode(_identityJson({'episode': 1.2345})),
        jsonEncode(_identityJson({'year': 1200})),
        jsonEncode(_identityJson({'confidence': 1.1})),
        jsonEncode(_identityJson({'aliases': List.filled(13, 'alias')})),
        jsonEncode(_identityJson({'kind': 'instructions'})),
        jsonEncode(
          _identityJson({
            'titles': {'path': '/private'},
          }),
        ),
      ];
      for (final response in responses) {
        transport.reply = () => response;
        await expectLater(analyze('release.mkv'), throwsA(isA<AppFailure>()));
      }
      expect(store.localEntries('media-ai-filename:'), isEmpty);
    },
  );

  test(
    'selection uses actual provider and media type tuple and sends only permitted candidate facts',
    () async {
      transport.reply = () => _selection('7', provider: 'tmdb', type: 'movie');
      final first = candidate('7');
      final second = candidate('7', provider: 'tmdb');
      final selected = candidate('7', provider: 'tmdb', type: 'movie')
        ..addAll({
          'poster': 'https://images/official.jpg',
          'summary': 'Do not send summary',
          'url': 'https://private/video?secret=xyz',
          'path': '/private/user',
          'aliases': ['Official alias'],
          'lookupNames': ['另一作品名'],
          'date': '2023-10-01',
        });
      final result = await confirm([
        first,
        second,
        selected,
      ], using: const AiMediaIdentity(name: 'Example', confidence: .99));
      expect(identical(result, selected), isTrue);
      expect(result?['poster'], 'https://images/official.jpg');
      expect(transport.input['candidates'], hasLength(3));
      final sent = jsonEncode(transport.input);
      for (final secret in [
        'https://images',
        'Do not send summary',
        'secret=xyz',
        '/private/user',
      ]) {
        expect(sent, isNot(contains(secret)));
      }
      expect(sent, contains('Official alias'));
    },
  );

  test(
    'ambiguous, no-match, low-confidence and invented identities cannot auto-apply',
    () async {
      final row = candidate('7');
      final responses = [
        _selection(null, status: 'ambiguous'),
        _selection(null, status: 'no_match'),
        _selection('7', confidence: .899),
        _selection('999'),
        _selection('7', provider: 'tmdb'),
      ];
      for (var i = 0; i < responses.length; i++) {
        transport.reply = () => responses[i];
        expect(
          await confirm([
            {...row, 'name': 'Variant $i'},
          ]),
          isNull,
        );
      }
      final before = transport.bodies.length;
      expect(
        await confirm([
          row,
        ], using: const AiMediaIdentity(name: 'Uncertain', confidence: .89)),
        isNull,
      );
      expect(transport.bodies, hasLength(before));
    },
  );

  test(
    'known media-type and season conflicts are excluded before confirmation',
    () async {
      expect(
        await confirm(
          [candidate('7')],
          using: const AiMediaIdentity(
            name: 'Movie',
            kind: 'movie',
            confidence: .99,
          ),
        ),
        isNull,
      );
      expect(
        await confirm([
          candidate('7', season: '2'),
          candidate('8', type: 'movie'),
        ]),
        isNull,
      );
      expect(transport.bodies, isEmpty);
      transport.reply = () => _selection('7');
      final series = candidate('7');
      expect(
        await confirm([series]),
        same(series),
        reason:
            'an entire TMDB/Bangumi series can be selected before official season detail validation',
      );
    },
  );

  test(
    'confirmation cache returns fresh official candidate maps and rejects incomplete selection schemas',
    () async {
      transport.reply = () => _selection('7');
      final old = candidate('7')..['poster'] = 'old';
      expect(await confirm([old]), same(old));
      final fresh = candidate('7')..['poster'] = 'new';
      expect(await confirm([fresh]), same(fresh));
      expect(transport.bodies, hasLength(1));
      transport.reply = () =>
          '{"status":"match","selection":{"id":"8"},"confidence":1}';
      await expectLater(confirm([candidate('8')]), throwsA(isA<AppFailure>()));
    },
  );

  test(
    'cancelled in-flight identity and confirmation responses never enter cache',
    () async {
      final filenameReply = Completer<String>();
      transport.reply = () => filenameReply.future;
      final firstCancel = CancelToken();
      final first = analyze('release.mkv', cancel: firstCancel);
      firstCancel.cancel();
      filenameReply.complete(jsonEncode(_identityJson()));
      await expectLater(first, throwsA(isA<Cancelled>()));
      expect(store.localEntries('media-ai-filename:'), isEmpty);
      final confirmationReply = Completer<String>();
      transport.reply = () => confirmationReply.future;
      final secondCancel = CancelToken();
      final second = confirm([candidate('7')], cancel: secondCancel);
      secondCancel.cancel();
      confirmationReply.complete(_selection('7'));
      await expectLater(second, throwsA(isA<Cancelled>()));
      expect(store.localEntries('media-ai-confirmation:'), isEmpty);
    },
  );

  test(
    'batch parsing shares single-file cache and binds reordered IDs to basenames',
    () async {
      await analyze('episode0.mkv');
      transport.reply = () => _batchResponse(transport.input);
      final result = await batch([
        '/private/user/episode0.mkv',
        '/private/user/episode1.mkv',
        r'C:\Users\private\episode2.mkv',
        '/another/path/episode1.mkv',
      ]);
      expect(result.keys, ['episode0.mkv', 'episode1.mkv', 'episode2.mkv']);
      expect(result['episode1.mkv']!.episode, '1');
      expect(result['episode2.mkv']!.episode, '2');
      expect(result['episode2.mkv']!.fileName, 'episode2.mkv');
      expect(transport.input, {
        'items': [
          {'id': '0', 'fileName': 'episode1.mkv'},
          {'id': '1', 'fileName': 'episode2.mkv'},
        ],
      });
      expect(jsonEncode(transport.bodies), isNot(contains('/private')));
      expect(jsonEncode(transport.bodies), isNot(contains('Users')));
      expect(jsonEncode(transport.bodies), isNot(contains('DO NOT USE')));
      expect(transport.bodies, hasLength(2));
      await analyze('episode1.mkv');
      await batch(['episode0.mkv', 'episode1.mkv', 'episode2.mkv']);
      expect(transport.bodies, hasLength(2));
      await batch([
        'episode1.mkv',
      ], using: SubtitleAiConfig(model: 'new-model'));
      expect(transport.bodies, hasLength(3));
      expect(store.localEntries('media-ai-filename:'), hasLength(4));
    },
  );

  test('batch rejects unsafe inputs before sending any request', () async {
    expect(await batch([]), isEmpty);
    await expectLater(
      batch(['episode1.mkv', 'https://private/video.mkv?secret=key']),
      throwsA(isA<AppFailure>()),
    );
    expect(transport.bodies, isEmpty);
    expect(store.localEntries('media-ai-filename:'), isEmpty);
  });

  test(
    'duplicate, missing, invented and invalid batch items never misassign files',
    () async {
      transport.reply = () => jsonEncode({
        'items': [
          {
            'id': '0',
            'identity': _identityJson({'episode': 1}),
          },
          {
            'id': '0',
            'identity': _identityJson({'episode': 999}),
          },
          {
            'id': '1',
            'identity': _identityJson({'episode': 2}),
          },
          {
            'id': '2',
            'identity': _identityJson({'episode': -1}),
          },
          {
            'id': '3',
            'identity': _identityJson({'episode': 4}),
            'fileName': 'forged.mkv',
          },
          {
            'id': 'invented',
            'identity': _identityJson({'episode': 500}),
          },
        ],
      });
      final result = await batch(
        List.generate(5, (i) => 'episode${i + 1}.mkv'),
      );
      expect(result.keys, ['episode2.mkv']);
      expect(result.values.single.episode, '2');
      expect(store.localEntries('media-ai-filename:'), hasLength(1));
      transport.reply = () => jsonEncode(_identityJson());
      await analyze('episode1.mkv');
      expect(transport.bodies, hasLength(2));
    },
  );

  test(
    'invalid batch envelopes and wholly unusable results fail without caching',
    () async {
      for (final response in [
        '{"items":[',
        jsonEncode({'items': []}),
        jsonEncode({'items': {}, 'extra': 'instructions'}),
        jsonEncode({'items': List.filled(41, {})}),
        jsonEncode({
          'items': [
            {'id': 0, 'identity': _identityJson()},
            {'id': 'unknown', 'identity': _identityJson()},
          ],
        }),
      ]) {
        transport.reply = () => response;
        await expectLater(batch(['episode1.mkv']), throwsA(isA<AppFailure>()));
      }
      expect(store.localEntries('media-ai-filename:'), isEmpty);
    },
  );

  test('failed batches retain valid results from other batches', () async {
    transport.reply = () {
      final input = transport.input;
      if ((input['items'] as List).first['fileName'] == 'episode20.mkv') {
        throw const AppFailure('temporary failure');
      }
      return _batchResponse(input);
    };
    final result = await batch(List.generate(45, (i) => 'episode$i.mkv'));
    expect(transport.bodies, hasLength(3));
    expect(result, hasLength(25));
    expect(result['episode19.mkv']!.episode, '19');
    expect(result.containsKey('episode20.mkv'), isFalse);
    expect(result['episode44.mkv']!.episode, '44');
    expect(store.localEntries('media-ai-filename:'), hasLength(25));
  });

  test(
    'all batch and single analyses share two request slots across concurrent calls',
    () async {
      var active = 0, maximum = 0;
      transport.reply = () async {
        final input = transport.input;
        active++;
        if (active > maximum) maximum = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return input.containsKey('items')
            ? _batchResponse(input)
            : jsonEncode(_identityJson());
      };
      final results = await Future.wait([
        batch(List.generate(45, (i) => 'episode$i.mkv')),
        batch(List.generate(25, (i) => 'episode${i + 100}.mkv')),
        analyze('single.mkv'),
      ]);
      expect(results[0], hasLength(45));
      expect(results[1], hasLength(25));
      expect(maximum, 2);
      expect(transport.bodies, hasLength(6));
      for (final body in transport.bodies) {
        final input =
            jsonDecode((body['messages'] as List).last['content']) as Map;
        if (input.containsKey('items')) {
          expect(input['items'], hasLength(lessThanOrEqualTo(20)));
        }
      }
    },
  );

  test(
    'cancelled queued batches do not send requests or consume a slot',
    () async {
      final gate = Completer<void>();
      transport.reply = () async {
        await gate.future;
        return jsonEncode(_identityJson());
      };
      final first = analyze('first.mkv'), second = analyze('second.mkv');
      expect(transport.bodies, hasLength(2));
      final cancel = CancelToken();
      final waiting = batch(['episode1.mkv'], cancel: cancel);
      final assertion = expectLater(waiting, throwsA(isA<Cancelled>()));
      cancel.cancel();
      await assertion;
      expect(transport.bodies, hasLength(2));
      gate.complete();
      await Future.wait([first, second]);
      transport.reply = () => _batchResponse(transport.input);
      expect(await batch(['episode1.mkv']), hasLength(1));
      expect(transport.bodies, hasLength(3));
      expect(store.localEntries('media-ai-filename:'), hasLength(3));
    },
  );

  test(
    'cancelled active batches neither cache unfinished responses nor start queued requests',
    () async {
      final gate = Completer<void>();
      transport.reply = () async {
        final input = transport.input;
        await gate.future;
        return _batchResponse(input);
      };
      final cancel = CancelToken();
      final pending = batch(
        List.generate(45, (i) => 'episode$i.mkv'),
        cancel: cancel,
      );
      final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
      expect(transport.bodies, hasLength(2));
      cancel.cancel();
      gate.complete();
      await assertion;
      expect(transport.bodies, hasLength(2));
      expect(store.localEntries('media-ai-filename:'), isEmpty);
    },
  );

  test(
    'resuming a cancelled batch reuses every completed filename analysis',
    () async {
      final gates = <Completer<void>>[];
      transport.reply = () async {
        final input = transport.input;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return _batchResponse(input);
      };
      final names = List.generate(60, (i) => 'episode$i.mkv');
      final cancel = CancelToken();
      final pending = batch(names, cancel: cancel);
      final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
      expect(gates, hasLength(2));
      gates.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(gates, hasLength(3));
      expect(store.localEntries('media-ai-filename:'), hasLength(20));
      cancel.cancel();
      gates[1].complete();
      gates[2].complete();
      await assertion;
      expect(store.localEntries('media-ai-filename:'), hasLength(20));

      transport.reply = () => _batchResponse(transport.input);
      final resumed = await batch(names);
      expect(resumed, hasLength(60));
      expect(transport.bodies, hasLength(5));
      final resumedNames = [
        for (final body in transport.bodies.skip(3))
          for (final item
              in (jsonDecode((body['messages'] as List).last['content'])
                      as Map)['items']
                  as List)
            item['fileName'],
      ];
      expect(resumedNames, names.skip(20).toList());
      expect(store.localEntries('media-ai-filename:'), hasLength(60));
    },
  );

  test(
    'episode numbers share work-level confirmation cache without losing episodic type checks',
    () async {
      transport.reply = () => _selection('7');
      final row = candidate('7');
      AiMediaIdentity episode(String number) =>
          AiMediaIdentity(name: 'Example', episode: number, confidence: .99);
      expect(await confirm([row], using: episode('1')), same(row));
      expect(await confirm([row], using: episode('12.5')), same(row));
      expect(transport.bodies, hasLength(1));
      final input = transport.input['identity'] as Map;
      expect(input.containsKey('episode'), isFalse);
      expect(input['episodic'], isTrue);
      expect(
        await confirm([candidate('7', type: 'movie')], using: episode('2')),
        isNull,
      );
      expect(transport.bodies, hasLength(1));
      expect(await confirm([row], using: episode('')), same(row));
      expect(transport.bodies, hasLength(2));
    },
  );
}
