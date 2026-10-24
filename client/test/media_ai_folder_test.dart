import 'dart:async';
import 'dart:convert';

import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/media_ai_catalog.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _identity(int episode) => {
  'name': 'Shared series',
  'titles': {'zh': '同一作品', 'en': 'Shared series', 'ja': ''},
  'aliases': [],
  'kind': 'anime',
  'season': 2,
  'episode': episode,
  'year': 2026,
  'confidence': .99,
};

Map<String, dynamic> _response(Map<String, dynamic> input) => {
  'items': [
    for (final item in (input['items'] as List).reversed)
      {
        'id': item['id'],
        'identity': _identity(
          int.parse(RegExp(r'(\d+)\.mkv$').firstMatch(item['fileName'])![1]!),
        ),
      },
  ],
};

class _Transport implements SubtitleAiTransport {
  final bodies = <Map<String, dynamic>>[];
  FutureOr<String> Function(Map<String, dynamic>) reply = (input) =>
      jsonEncode(_response(input));
  @override
  Future<String> complete(
    SubtitleAiConfig config,
    Map<String, dynamic> body,
    CancelToken cancel,
  ) async {
    bodies.add(body);
    final input =
        jsonDecode((body['messages'] as List).last['content'])
            as Map<String, dynamic>;
    return reply(input);
  }

  List<String> names(int request) => [
    for (final item
        in (jsonDecode((bodies[request]['messages'] as List).last['content'])
                as Map)['items']
            as List)
      item['fileName'] as String,
  ];

  @override
  Future<List<String>> models(
    SubtitleAiConfig config,
    CancelToken cancel,
  ) async => [];
}

void main() {
  late AppStore store;
  late _Transport transport;
  late MediaAiRecognition service;
  final config = SubtitleAiConfig(
    model: 'folder-model',
    token: 'private-token',
  );
  setUp(() {
    store = AppStore(':memory:');
    transport = _Transport();
    service = MediaAiRecognition(store, transport: transport);
  });
  tearDown(() => store.dispose());

  Future<Map<String, AiMediaIdentity>> analyze(
    List<String> names, {
    CancelToken? cancel,
    SubtitleAiConfig? using,
  }) => service.analyzeFolderFilenames(
    names,
    config: using ?? config,
    cancel: cancel ?? CancelToken(),
  );

  test(
    'one folder request includes all files despite existing individual cache',
    () async {
      transport.reply = (_) => jsonEncode(_identity(99));
      await service.analyzeFilename(
        'episode0.mkv',
        config: config,
        cancel: CancelToken(),
      );
      transport.reply = (input) => jsonEncode(_response(input));
      final names = List.generate(45, (index) => 'episode$index.mkv');
      final parsed = await analyze(names);
      expect(transport.bodies, hasLength(2));
      expect(transport.names(1).toSet(), names.toSet());
      for (var index = 0; index < names.length; index++) {
        expect(parsed[names[index]]!.episode, '$index');
        expect(parsed[names[index]]!.season, '2');
      }
      final prompt =
          (transport.bodies.last['messages'] as List).first['content'];
      expect(prompt, contains('complete set of filenames from one folder'));
      expect(() => parsed.clear(), throwsUnsupportedError);
      expect(store.localEntries('media-ai-filename:'), hasLength(1));
      expect(store.localEntries('media-ai-folder-v1:'), hasLength(1));
    },
  );

  test(
    'complete folder cache survives service restart and ordering changes',
    () async {
      final names = ['episode1.mkv', 'episode2.mkv'];
      await analyze(names);
      service = MediaAiRecognition(store, transport: transport);
      final resumed = await analyze(names.reversed.toList());
      expect(transport.bodies, hasLength(1));
      expect(resumed['episode1.mkv']!.episode, '1');
      await analyze([...names, 'episode3.mkv']);
      expect(transport.bodies, hasLength(2));
      expect(transport.names(1), hasLength(3));
      await analyze(['episode1.mkv']);
      expect(transport.bodies, hasLength(3));
      expect(transport.names(2), ['episode1.mkv']);
    },
  );

  test('folder results never become basename-only cache entries', () async {
    await analyze(['episode1.mkv', 'episode2.mkv']);
    transport.reply = (_) => jsonEncode(_identity(77));
    final individual = await service.analyzeFilename(
      'episode1.mkv',
      config: config,
      cancel: CancelToken(),
    );
    expect(individual.episode, '77');
    expect(transport.bodies, hasLength(2));
  });

  test('changed model or credentials reanalyze the entire folder', () async {
    final names = ['episode1.mkv', 'episode2.mkv'];
    await analyze(names);
    await analyze(
      names,
      using: SubtitleAiConfig(model: 'new-model', token: 'private-token'),
    );
    await analyze(
      names,
      using: SubtitleAiConfig(model: 'new-model', token: 'new-token'),
    );
    expect(transport.bodies, hasLength(3));
    for (var index = 0; index < 3; index++) {
      expect(transport.names(index), names);
    }
    expect(jsonEncode(transport.bodies), isNot(contains('private-token')));
  });

  test(
    'folder limits and unsafe inputs fail before sending without splitting',
    () async {
      await expectLater(
        analyze(List.generate(1001, (index) => 'episode$index.mkv')),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'limit',
            contains('1000'),
          ),
        ),
      );
      await expectLater(
        analyze(List.generate(300, (index) => '${'x' * 1000}$index.mkv')),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'limit',
            contains('256 KiB'),
          ),
        ),
      );
      await expectLater(
        analyze(['episode1.mkv', 'https://secret.test/episode2.mkv']),
        throwsA(isA<AppFailure>()),
      );
      expect(await analyze([]), isEmpty);
      expect(transport.bodies, isEmpty);
    },
  );

  test(
    'the supported 1000-file limit still sends exactly one request',
    () async {
      final parsed = await analyze(
        List.generate(1000, (index) => 'episode$index.mkv'),
      );
      expect(parsed, hasLength(1000));
      expect(transport.bodies, hasLength(1));
      expect(transport.names(0), hasLength(1000));
    },
  );

  test(
    'missing, duplicate, invented and invalid identities reject the whole batch',
    () async {
      final corruptions = <void Function(List<dynamic>)>[
        (rows) => rows.removeLast(),
        (rows) => rows.last['id'] = rows.first['id'],
        (rows) => rows.last['id'] = '999',
        (rows) => rows.last['id'] = '00',
        (rows) => rows.last['identity']['episode'] = 'private-path',
        (rows) => rows.add({'id': '3', 'identity': _identity(3)}),
      ];
      for (final corrupt in corruptions) {
        transport.reply = (input) {
          final response = _response(input);
          corrupt(response['items'] as List);
          return jsonEncode(response);
        };
        await expectLater(
          analyze(['episode1.mkv', 'episode2.mkv']),
          throwsA(isA<AppFailure>()),
        );
        expect(store.localEntries('media-ai-folder-v1:'), isEmpty);
        expect(store.localEntries('media-ai-filename:'), isEmpty);
      }
      expect(transport.bodies, hasLength(corruptions.length));
    },
  );

  test(
    'cancelled responses cannot cache results and retry sends the entire folder',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      transport.reply = (input) async {
        started.complete();
        await gate.future;
        return jsonEncode(_response(input));
      };
      final names = ['episode1.mkv', 'episode2.mkv'];
      final cancel = CancelToken();
      final pending = analyze(names, cancel: cancel);
      final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
      await started.future;
      cancel.cancel();
      gate.complete();
      await assertion;
      await Future<void>.delayed(Duration.zero);
      expect(store.localEntries('media-ai-folder-v1:'), isEmpty);
      transport.reply = (input) => jsonEncode(_response(input));
      expect(await analyze(names), hasLength(2));
      expect(transport.bodies, hasLength(2));
      expect(transport.names(1), names);
    },
  );

  test('shared folder callers deduplicate and cancel independently', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    transport.reply = (input) async {
      started.complete();
      await gate.future;
      return jsonEncode(_response(input));
    };
    final cancel = CancelToken();
    final first = analyze(['episode1.mkv', 'episode2.mkv'], cancel: cancel);
    final assertion = expectLater(first, throwsA(isA<Cancelled>()));
    final second = analyze(['episode2.mkv', 'episode1.mkv']);
    await started.future;
    cancel.cancel();
    await assertion;
    gate.complete();
    expect(await second, hasLength(2));
    expect(transport.bodies, hasLength(1));
    expect(store.localEntries('media-ai-folder-v1:'), hasLength(1));
  });

  test(
    'folder request queue is bounded and cancellation releases it',
    () async {
      final gate = Completer<void>();
      transport.reply = (input) async {
        await gate.future;
        return jsonEncode(_response(input));
      };
      final tokens = List.generate(34, (_) => CancelToken());
      final pending = [
        for (var i = 0; i < tokens.length; i++)
          expectLater(
            analyze(['episode$i.mkv'], cancel: tokens[i]),
            throwsA(isA<Cancelled>()),
          ),
      ];
      await expectLater(
        analyze(['episode100.mkv']),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('繁忙'),
          ),
        ),
      );
      expect(transport.bodies, hasLength(2));
      for (final token in tokens) {
        token.cancel();
      }
      gate.complete();
      await Future.wait(pending);
      await Future<void>.delayed(Duration.zero);
      expect(store.localEntries('media-ai-folder-v1:'), isEmpty);
      expect(await analyze(['episode200.mkv']), hasLength(1));
      expect(transport.bodies, hasLength(3));
    },
  );

  test(
    'large mixed folder keeps episode identities and strongest evidence',
    () async {
      final identities = [
        for (var i = 0; i < 100; i++)
          AiMediaIdentity(
            fileName: 'episode$i.mkv',
            name: i < 60 ? 'First series' : 'Second series',
            season: i < 30 ? '1' : '2',
            episode: '$i',
            confidence: i / 100,
          ),
        const AiMediaIdentity(fileName: 'movie.mkv', name: 'First series'),
      ];
      final groups = await groupAiCatalogIdentities(identities);
      expect(groups, hasLength(4));
      expect(groups.map((group) => group.length), [30, 30, 40, 1]);
      expect(groups.map((group) => group.first.fileName), [
        'episode29.mkv',
        'episode59.mkv',
        'episode99.mkv',
        'movie.mkv',
      ]);
      final byFile = {
        for (final identity in groups.expand((group) => group))
          identity.fileName: identity,
      };
      expect(byFile, hasLength(101));
      for (final identity in identities) {
        expect(byFile[identity.fileName]!.episode, identity.episode);
        expect(byFile[identity.fileName]!.season, identity.season);
      }
    },
  );

  test('cache invalidation rejects late complete folder responses', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    transport.reply = (input) async {
      started.complete();
      await gate.future;
      return jsonEncode(_response(input));
    };
    final pending = analyze(['episode1.mkv']);
    final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
    await started.future;
    service.invalidate();
    gate.complete();
    await assertion;
    expect(store.localEntries('media-ai-folder-v1:'), isEmpty);
  });

  test(
    'invalidation cancels delegated worker work and rejects late snapshots',
    () async {
      final gate = Completer<Map<String, AiMediaIdentity>>();
      CancelToken? workerCancel;
      service = MediaAiRecognition(
        store,
        folderAnalyzer: (names, {required config, required cancel}) {
          workerCancel = cancel;
          return gate.future;
        },
      );
      final pending = analyze(['episode1.mkv']);
      final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
      expect(workerCancel, isNotNull);
      service.invalidate();
      expect(workerCancel!.cancelled, isTrue);
      gate.complete({'episode1.mkv': const AiMediaIdentity(name: 'Late')});
      await assertion;
    },
  );

  test(
    'caller cancellation reaches the delegated worker without a frame',
    () async {
      final gate = Completer<Map<String, AiMediaIdentity>>();
      CancelToken? workerCancel;
      service = MediaAiRecognition(
        store,
        folderAnalyzer: (names, {required config, required cancel}) {
          workerCancel = cancel;
          return gate.future;
        },
      );
      final cancel = CancelToken();
      final pending = analyze(['episode1.mkv'], cancel: cancel);
      final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
      cancel.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(workerCancel!.cancelled, isTrue);
      gate.complete({});
      await assertion;
    },
  );
}
