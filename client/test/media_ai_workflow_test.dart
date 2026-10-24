import 'dart:async';
import 'dart:io';
import 'package:aiplayer/core/network.dart';
import 'package:aiplayer/data/app_model.dart';
import 'package:aiplayer/data/library_catalog.dart';
import 'package:aiplayer/data/media_ai_recognition.dart';
import 'package:aiplayer/data/store.dart';
import 'package:aiplayer/subtitles/ai.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _subject({int id = 7, String name = 'Example'}) => {
  'id': id,
  'provider': 'bangumi',
  'mediaType': 'tv',
  'type': 2,
  'name': name,
  'summary': 'Official synopsis',
  'images': {'large': 'https://official.example/poster.jpg'},
};

class _Ai extends MediaAiRecognition {
  _Ai(super.store);
  final filenames = <String>[];
  final configs = <SubtitleAiConfig>[];
  final confirmations = <List<Map<String, dynamic>>>[];
  bool accept = true, acceptDetails = true;
  String season = '1';
  Map<String, String> titles = {};
  Completer<void>? analysisGate;
  final analysisStarted = Completer<void>();

  @override
  Future<Map<String, AiMediaIdentity>> analyzeFilenames(
    List<String> fileNames, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async => {
    for (final name in fileNames)
      MediaAiRecognition.filenameOnly(name): await analyzeFilename(
        name,
        config: config,
        cancel: cancel,
      ),
  };

  @override
  Future<Map<String, AiMediaIdentity>> analyzeFolderFilenames(
    List<String> fileNames, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) => analyzeFilenames(fileNames, config: config, cancel: cancel);

  @override
  Future<AiMediaIdentity> analyzeFilename(
    String fileName, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async {
    filenames.add(fileName);
    configs.add(config);
    if (!analysisStarted.isCompleted) analysisStarted.complete();
    await analysisGate?.future;
    final episode = RegExp(r'E(\d+)').firstMatch(fileName)?[1] ?? '1';
    return AiMediaIdentity(
      fileName: MediaAiRecognition.filenameOnly(fileName),
      name: 'Example',
      titles: titles,
      kind: 'anime',
      season: season,
      episode: '${int.parse(episode)}',
      confidence: .99,
    );
  }

  @override
  Future<Map<String, dynamic>?> confirm(
    AiMediaIdentity identity,
    List<Map<String, dynamic>> candidates, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async {
    cancel.check();
    confirmations.add(candidates);
    if (!accept || (!acceptDetails && confirmations.length > 1)) return null;
    return candidates.firstOrNull;
  }
}

class _Catalog extends LibraryCatalog {
  _Catalog(super.store);
  Map<String, dynamic>? normalSubject;
  List<Map<String, dynamic>> candidates = [_subject()];
  Map<String, dynamic> fullSubject = _subject();
  final queries = <String>[];
  int normalCalls = 0, detailsCalls = 0;
  Completer<void>? detailGate, episodeGate;
  final detailsStarted = Completer<void>();
  final episodesStarted = Completer<void>();

  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    cancel?.check();
    normalCalls++;
    return normalSubject;
  }

  @override
  Future<List<Map<String, dynamic>>> search(
    String title, {
    String? source,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    queries.add(title);
    return candidates;
  }

  @override
  Future<Map<String, dynamic>> details(
    Map<String, dynamic> subject, {
    String season = '',
    CancelToken? cancel,
  }) async {
    detailsCalls++;
    if (!detailsStarted.isCompleted) detailsStarted.complete();
    await detailGate?.future;
    cancel?.check();
    return fullSubject;
  }

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async {
    if (!episodesStarted.isCompleted) episodesStarted.complete();
    await episodeGate?.future;
    cancel?.check();
    return {'1': 'Official episode one', '2': 'Official episode two'};
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents)
    : ai = _Ai(store),
      fakeCatalog = _Catalog(store);
  final _Ai ai;
  final _Catalog fakeCatalog;
  @override
  MediaAiRecognition get mediaAi => ai;
  @override
  LibraryCatalog get catalog => fakeCatalog;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppStore store;
  late _Model model;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'aiSubtitleToken': 'test-token',
    });
    directory = Directory.systemTemp.createTempSync('aiplayer-ai-workflow-');
    store = AppStore(':memory:')
      ..setLocal('settings', {
        'metadataStrategy': 'conservative',
        'aiSubtitleOrigin': 'https://ai.example/v1',
        'aiSubtitleModel': 'configured-model',
        'aiSubtitlePrompt': 'Subtitle-only custom instructions',
      });
    model = _Model(store, directory);
  });
  tearDown(() {
    model.dispose();
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  SyncRecord add(String id, {int episode = 1}) {
    final name = 'Example S01E${episode.toString().padLeft(2, '0')}.mkv';
    store.save('media', id, {
      'title': name,
      'fileName': name,
      'series': 'Unrecognized release',
      'season': '',
      'episode': '',
      'size': 123,
    });
    return store.get('media', id)!;
  }

  test('automatic AI stays disabled unless opted in', () async {
    final record = add('one');
    await model.refreshMetadata();
    expect(model.fakeCatalog.normalCalls, 1);
    expect(model.ai.filenames, isEmpty);
    expect(store.get('media', record.id)!.revision, record.revision);
  });

  test('successful ordinary identification never calls AI', () async {
    await model.updatePreferences({'aiMetadataEnabled': true});
    model.fakeCatalog.normalSubject = _subject();
    final record = add('one');
    await model.refreshMetadata();
    expect(store.get('media', record.id)!.data['bangumiId'], '7');
    expect(model.ai.filenames, isEmpty);
  });

  test('metadata strategy off suppresses automatic AI as well', () async {
    await model.updatePreferences({
      'aiMetadataEnabled': true,
      'metadataStrategy': 'off',
    });
    final record = add('one');
    await model.refreshMetadata();
    expect(model.fakeCatalog.normalCalls, 0);
    expect(model.ai.filenames, isEmpty);
    expect(store.get('media', record.id)!.revision, record.revision);
  });

  test('automatic fallback uses configured AI and official metadata', () async {
    await model.updatePreferences({'aiMetadataEnabled': true});
    final record = add('one');
    await model.refreshMetadata();
    final data = store.get('media', record.id)!.data;
    expect(model.ai.filenames, [record.data['fileName']]);
    expect(model.ai.configs.single.origin, Uri.parse('https://ai.example/v1'));
    expect(model.ai.configs.single.model, 'configured-model');
    expect(model.ai.configs.single.token, 'test-token');
    expect(model.ai.configs.single.prompt, isEmpty);
    expect(data['bangumiId'], '7');
    expect(data['series'], 'Example');
    expect(data['season'], '1');
    expect(data['episode'], '1');
    expect(data['summary'], 'Official synopsis');
    expect(data['poster'], 'https://official.example/poster.jpg');
    expect(store.local('episodeTitle:${record.id}'), 'Official episode one');
    expect(store.local('manualMetadata:${record.id}'), isNot(true));
  });

  test(
    'manual fallback recognizes each selected filename independently',
    () async {
      await model.updatePreferences({'aiMetadataEnabled': true});
      final first = add('one');
      final second = add('two', episode: 2);
      expect(await model.identifyMediaRecords([first, second]), isTrue);
      expect(model.ai.filenames, [
        first.data['fileName'],
        second.data['fileName'],
      ]);
      expect(store.get('media', first.id)!.data['episode'], '1');
      expect(store.get('media', second.id)!.data['episode'], '2');
      expect(store.local('episodeTitle:${first.id}'), 'Official episode one');
      expect(store.local('episodeTitle:${second.id}'), 'Official episode two');
    },
  );

  test(
    'reusing a first-file match cannot copy its episode to another file',
    () async {
      final first = add('one');
      final second = add('two', episode: 2);
      final cancel = CancelToken();
      final match = await model.searchMetadataWithAi(
        model.metadataFileName(first),
        cancel: cancel,
      );
      expect(
        await model.identifyMediaWithAi(first, match: match, cancel: cancel),
        isTrue,
      );
      expect(
        await model.identifyMediaWithAi(second, match: match, cancel: cancel),
        isTrue,
      );
      expect(model.ai.filenames, [
        first.data['fileName'],
        second.data['fileName'],
      ]);
      expect(store.get('media', second.id)!.data['episode'], '2');
    },
  );

  for (final rejectDetails in [false, true]) {
    test(
      'unconfirmed ${rejectDetails ? 'details' : 'candidates'} never modify a record',
      () async {
        model.ai.accept = rejectDetails;
        model.ai.acceptDetails = false;
        final record = add('one');
        expect(
          await model.identifyMediaWithAi(record, cancel: CancelToken()),
          isFalse,
        );
        expect(store.get('media', record.id)!.revision, record.revision);
        expect(store.get('media', record.id)!.data, record.data);
        expect(store.local('manualMetadata:${record.id}'), isNull);
        expect(store.local('episodeTitle:${record.id}'), isNull);
        expect(model.fakeCatalog.detailsCalls, rejectDetails ? 1 : 0);
      },
    );
  }

  for (final change in ['manual', 'edit', 'disable', 'credentials']) {
    test('late automatic AI does not overwrite a $change change', () async {
      await model.updatePreferences({'aiMetadataEnabled': true});
      final record = add('one');
      model.fakeCatalog.detailGate = Completer<void>();
      final pending = model.identifyMediaWithAi(
        record,
        cancel: CancelToken(),
        manual: false,
      );
      await model.fakeCatalog.detailsStarted.future;
      switch (change) {
        case 'manual':
          store.setLocal('manualMetadata:${record.id}', true);
        case 'edit':
          store.save('media', record.id, {
            ...record.data,
            'series': 'User edit',
          });
        case 'disable':
          await model.updatePreferences({'aiMetadataEnabled': false});
        case 'credentials':
          store.setLocal('metadataCredentialsRevision', 123);
      }
      final current = store.get('media', record.id)!;
      model.fakeCatalog.detailGate!.complete();
      expect(await pending, isFalse);
      expect(store.get('media', record.id)!.revision, current.revision);
      expect(store.get('media', record.id)!.data, current.data);
      expect(store.local('episodeTitle:${record.id}'), isNull);
    });
  }

  test('Bangumi season one cannot satisfy an AI season two identity', () async {
    model.ai.season = '2';
    final record = add('one');
    expect(
      await model.identifyMediaWithAi(record, cancel: CancelToken()),
      isFalse,
    );
    expect(model.fakeCatalog.detailsCalls, 1);
    expect(store.get('media', record.id)!.revision, record.revision);
  });

  test(
    'multilingual search preserves provider and media-type candidate identities',
    () async {
      model.ai.titles = {'zh': '示例作品', 'ja': '作品例'};
      model.fakeCatalog.candidates = [
        _subject(),
        {..._subject(), 'provider': 'tmdb'},
        {..._subject(), 'provider': 'tmdb', 'mediaType': 'movie'},
      ];
      final match = await model.searchMetadataWithAi(
        'Example.mkv',
        cancel: CancelToken(),
      );
      expect(model.fakeCatalog.queries, ['Example', '示例作品', '作品例']);
      expect(match.candidates, hasLength(3));
    },
  );

  test(
    'folder progress leaves parsing while shared catalogue work is pending',
    () async {
      final names = [for (var i = 1; i <= 13; i++) 'Example S01E$i.mkv'];
      model.fakeCatalog.detailGate = Completer<void>();
      final progress = <String>[];
      final pending = model.searchMetadataBatchWithAi(
        names,
        cancel: CancelToken(),
        wholeFolder: true,
        onProgress: progress.add,
      );
      await model.fakeCatalog.detailsStarted.future;
      expect(progress, ['正在搜索并核对作品 0/1…']);
      expect(model.fakeCatalog.queries, ['Example']);
      expect(model.fakeCatalog.detailsCalls, 1);
      model.fakeCatalog.detailGate!.complete();
      final matches = await pending;
      expect(matches, hasLength(13));
      expect(matches.values.map((match) => match.identity.episode).toSet(), {
        for (var i = 1; i <= 13; i++) '$i',
      });
      expect(progress, ['正在搜索并核对作品 0/1…', '正在搜索并核对作品 1/1…']);
      expect(model.ai.confirmations, hasLength(2));
    },
  );

  test(
    'cancellation during filename analysis prevents searches and writes',
    () async {
      final record = add('one');
      model.ai.analysisGate = Completer<void>();
      final cancel = CancelToken();
      final pending = model.identifyMediaWithAi(record, cancel: cancel);
      final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
      await model.ai.analysisStarted.future;
      cancel.cancel();
      model.ai.analysisGate!.complete();
      await assertion;
      expect(model.fakeCatalog.queries, isEmpty);
      expect(store.get('media', record.id)!.revision, record.revision);
    },
  );

  test(
    'cancellation during official details propagates without writes',
    () async {
      final record = add('one');
      model.fakeCatalog.detailGate = Completer<void>();
      final cancel = CancelToken();
      final pending = model.identifyMediaWithAi(record, cancel: cancel);
      final assertion = expectLater(pending, throwsA(isA<Cancelled>()));
      await model.fakeCatalog.detailsStarted.future;
      cancel.cancel();
      model.fakeCatalog.detailGate!.complete();
      await assertion;
      expect(store.get('media', record.id)!.revision, record.revision);
    },
  );

  test(
    'late optional AI episode names cannot overwrite a new manual match',
    () async {
      await model.updatePreferences({'aiMetadataEnabled': true});
      final record = add('one');
      model.fakeCatalog.episodeGate = Completer<void>();
      final pending = model.identifyMediaWithAi(
        record,
        cancel: CancelToken(),
        manual: false,
      );
      await model.fakeCatalog.episodesStarted.future;
      expect(store.get('media', record.id)!.data['bangumiId'], '7');
      model.applyBangumi('Example', _subject(id: 99), mediaIds: {record.id});
      store.setLocal('episodeTitle:${record.id}', 'Manually selected episode');
      model.fakeCatalog.episodeGate!.complete();
      await pending;
      expect(store.get('media', record.id)!.data['bangumiId'], '99');
      expect(
        store.local('episodeTitle:${record.id}'),
        'Manually selected episode',
      );
    },
  );
}
