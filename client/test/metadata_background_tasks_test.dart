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

Future<void> _waitFor(Completer<void>? gate, CancelToken? cancel) async {
  if (gate == null) return;
  await Future.any([
    gate.future,
    if (cancel != null)
      cancel.whenCancelled.then<void>((_) => throw const Cancelled()),
  ]);
}

Map<String, dynamic> _subject(String name, {String type = 'tv'}) => {
  'provider': 'bangumi',
  'mediaType': type,
  'type': 2,
  'id': name.codeUnits.fold<int>(1, (sum, code) => sum + code),
  'name': name,
  'summary': 'Official $name synopsis',
};

class _BatchAi extends MediaAiRecognition {
  _BatchAi(super.store);
  final batches = <List<String>>[];
  final singles = <String>[];
  final confirmations = <AiMediaIdentity>[];
  final overrides = <String, AiMediaIdentity>{};
  final failNames = <String>{};
  final started = Completer<void>();
  final attemptTokens = <CancelToken>[];
  Completer<void>? gate;
  bool ignoreCancellation = false;

  AiMediaIdentity identity(String fileName) {
    final name = MediaAiRecognition.filenameOnly(fileName);
    if (failNames.contains(name)) throw const AppFailure('AI fixture failed');
    if (overrides[name] != null) return overrides[name]!;
    final parts = RegExp(r'^(.*) E(\d+)\.mkv$').firstMatch(name)!;
    return AiMediaIdentity(
      fileName: name,
      name: parts[1]!,
      kind: 'anime',
      season: '1',
      episode: '${int.parse(parts[2]!)}',
      confidence: .99,
    );
  }

  Future<void> _start(CancelToken cancel) async {
    attemptTokens.add(cancel);
    if (!started.isCompleted) started.complete();
    if (ignoreCancellation) {
      await gate?.future;
      return;
    }
    await _waitFor(gate, cancel);
    cancel.check();
  }

  @override
  Future<AiMediaIdentity> analyzeFilename(
    String fileName, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async {
    singles.add(fileName);
    await _start(cancel);
    return identity(fileName);
  }

  @override
  Future<Map<String, AiMediaIdentity>> analyzeFilenames(
    List<String> fileNames, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async {
    batches.add(fileNames.toList());
    await _start(cancel);
    return {for (final name in fileNames) name: identity(name)};
  }

  @override
  Future<Map<String, dynamic>?> confirm(
    AiMediaIdentity identity,
    List<Map<String, dynamic>> candidates, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
  }) async {
    cancel.check();
    confirmations.add(identity);
    return candidates.where((candidate) {
      final episodic =
          identity.episode.isNotEmpty || identity.season.isNotEmpty;
      return candidate['mediaType'] == (episodic ? 'tv' : 'movie');
    }).firstOrNull;
  }
}

class _Catalog extends LibraryCatalog {
  _Catalog(super.store);
  final normalSubjects = <String, Map<String, dynamic>>{};
  final normalFailures = <String>{};
  final queries = <String>[], normalQueries = <String>[];
  final overrides = <String, List<Map<String, dynamic>>>{};
  int detailsCalls = 0, episodeCalls = 0, active = 0, maximum = 0;
  Completer<void>? searchGate, normalGate, episodeGate;
  final normalStarted = Completer<void>();
  final episodeStarted = Completer<void>();
  final firstSearch = Completer<void>(), thirdSearch = Completer<void>();

  @override
  Future<Map<String, dynamic>?> resolve(
    String title,
    String season, {
    CancelToken? cancel,
    bool force = false,
  }) async {
    cancel?.check();
    normalQueries.add(title);
    if (!normalStarted.isCompleted) normalStarted.complete();
    await _waitFor(normalGate, cancel);
    if (normalFailures.contains(title)) {
      throw const AppFailure('Catalogue offline');
    }
    return normalSubjects[title];
  }

  @override
  Future<List<Map<String, dynamic>>> search(
    String title, {
    String? source,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    queries.add(title);
    active++;
    if (active > maximum) maximum = active;
    if (!firstSearch.isCompleted) firstSearch.complete();
    if (active == 3 && !thirdSearch.isCompleted) thirdSearch.complete();
    try {
      await _waitFor(searchGate, cancel);
      cancel?.check();
      return overrides[title] ?? [_subject(title)];
    } finally {
      active--;
    }
  }

  @override
  Future<Map<String, dynamic>> details(
    Map<String, dynamic> subject, {
    String season = '',
    CancelToken? cancel,
  }) async {
    cancel?.check();
    detailsCalls++;
    return subject;
  }

  @override
  Future<Map<String, String>> episodeNames(
    String subjectId, {
    Map<String, dynamic>? subject,
    CancelToken? cancel,
  }) async {
    cancel?.check();
    episodeCalls++;
    if (!episodeStarted.isCompleted) episodeStarted.complete();
    await _waitFor(episodeGate, cancel);
    return {for (var i = 1; i <= 20; i++) '$i': 'Official episode $i'};
  }
}

class _Model extends AppModel {
  _Model(super.store, super.documents)
    : ai = _BatchAi(store),
      fakeCatalog = _Catalog(store);
  final _BatchAi ai;
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
    directory = Directory.systemTemp.createTempSync('aiplayer-metadata-tasks-');
    store = AppStore('${directory.path}/test.db')
      ..setLocal('settings', {
        'metadataStrategy': 'conservative',
        'aiMetadataEnabled': true,
        'aiSubtitleModel': 'configured-model',
      });
    model = _Model(store, directory);
  });
  tearDown(() async {
    model.dispose();
    await Future<void>.delayed(Duration.zero);
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  SyncRecord add(String id, {String work = 'Example', int episode = 1}) {
    final fileName = '$work E${episode.toString().padLeft(2, '0')}.mkv';
    store.save('media', id, {
      'title': fileName,
      'fileName': fileName,
      'series': work,
      'season': '1',
      'episode': '$episode',
      'size': 123,
    });
    return store.get('media', id)!;
  }

  test(
    'automatic tasks wait for foreground and playback without blocking manual work',
    () async {
      model.setForeground(false);
      final automatic = model.startMetadataTask([
        add('automatic'),
      ], manual: false);
      final manual = model.startMetadataTask([add('manual', work: 'Manual')]);
      await manual.done;
      expect(manual.matched, 1);
      expect(automatic.running, true);
      expect(model.fakeCatalog.normalQueries, ['Manual']);
      model.activePlaybackMediaId = 'playing';
      model.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(model.fakeCatalog.normalQueries, ['Manual']);
      model.activePlaybackMediaId = null;
      await automatic.done;
      expect(automatic.matched, 1);
      expect(model.fakeCatalog.normalQueries, ['Manual', 'Example']);
    },
  );

  test(
    'cancelling a suspended task keeps it from restarting on resume',
    () async {
      model.setForeground(false);
      final task = model.startMetadataTask([add('cancelled')], manual: false);
      await Future<void>.delayed(Duration.zero);
      model.cancelMetadataTask(task);
      await task.done;
      model.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(task.cancelled, true);
      expect(model.fakeCatalog.normalQueries, isEmpty);
    },
  );

  for (final rapidResume in [false, true]) {
    test(
      'automatic batch requests cancel on background and resume ($rapidResume)',
      () async {
        model.ai.gate = Completer<void>();
        final task = model.startMetadataTask(
          List.generate(41, (i) => add('$i', episode: i + 1)),
          ai: true,
          manual: false,
        );
        await model.ai.started.future;
        final firstToken = model.ai.attemptTokens.single;
        model.setForeground(false);
        expect(firstToken.cancelled, true);
        if (rapidResume) model.setForeground(true);
        await Future<void>.delayed(Duration.zero);
        expect(task.running, true);
        expect(task.cancelled, false);
        expect(task.matched, 0);
        expect(model.fakeCatalog.queries, isEmpty);
        if (!rapidResume) {
          expect(model.ai.attemptTokens, hasLength(1));
          model.setForeground(true);
          await Future<void>.delayed(Duration.zero);
        }
        expect(model.ai.attemptTokens, hasLength(2));
        expect(model.ai.attemptTokens.last.cancelled, false);
        model.ai.gate!.complete();
        await task.done;
        expect(task.cancelled, false);
        expect(task.matched, 41);
      },
    );
  }

  test(
    'playback suspends an automatic request without cancelling its task',
    () async {
      model.ai.gate = Completer<void>();
      final task = model.startMetadataTask(
        [add('playing')],
        ai: true,
        manual: false,
      );
      await model.ai.started.future;
      model.activePlaybackMediaId = 'active-video';
      expect(model.ai.attemptTokens.single.cancelled, true);
      await Future<void>.delayed(Duration.zero);
      expect(task.running, true);
      expect(task.cancelled, false);
      model.ai.gate!.complete();
      model.activePlaybackMediaId = null;
      await task.done;
      expect(task.matched, 1);
    },
  );

  test(
    'manual AI requests continue when the app enters the background',
    () async {
      model.ai.gate = Completer<void>();
      final task = model.startMetadataTask([add('manual-active')], ai: true);
      await model.ai.started.future;
      model.setForeground(false);
      expect(model.ai.attemptTokens.single.cancelled, false);
      model.ai.gate!.complete();
      await task.done;
      expect(task.matched, 1);
      expect(task.cancelled, false);
    },
  );

  test(
    'user cancellation during background suspension never restarts the task',
    () async {
      model.ai
        ..gate = Completer<void>()
        ..ignoreCancellation = true;
      final task = model.startMetadataTask(
        [add('cancel-suspended')],
        ai: true,
        manual: false,
      );
      await model.ai.started.future;
      model.setForeground(false);
      expect(model.ai.attemptTokens.single.cancelled, true);
      model.cancelMetadataTask(task);
      model.setForeground(true);
      model.ai.gate!.complete();
      await task.done;
      await Future<void>.delayed(Duration.zero);
      expect(task.cancelled, true);
      expect(task.running, false);
      expect(task.matched, 0);
      expect(model.ai.attemptTokens, hasLength(1));
      expect(model.fakeCatalog.queries, isEmpty);
      expect(store.get('media', 'cancel-suspended')!.data['bangumiId'], isNull);
    },
  );

  test(
    'late automatic network results are discarded after backgrounding',
    () async {
      model.ai
        ..gate = Completer<void>()
        ..ignoreCancellation = true;
      final task = model.startMetadataTask(
        [add('late-background')],
        ai: true,
        manual: false,
      );
      await model.ai.started.future;
      model.setForeground(false);
      model.ai.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(task.running, true);
      expect(task.cancelled, false);
      expect(task.matched, 0);
      expect(model.fakeCatalog.queries, isEmpty);
      expect(store.get('media', 'late-background')!.data['bangumiId'], isNull);
      model.setForeground(true);
      await task.done;
      expect(task.matched, 1);
      expect(model.ai.attemptTokens, hasLength(2));
    },
  );

  test(
    'background cancellation preserves identities saved before optional episode lookup',
    () async {
      model.fakeCatalog.normalSubjects['Example'] = _subject('Example');
      model.fakeCatalog.episodeGate = Completer<void>();
      final task = model.startMetadataTask([
        add('identity-ready'),
      ], manual: false);
      await model.fakeCatalog.episodeStarted.future;
      model.setForeground(false);
      await Future<void>.delayed(Duration.zero);
      expect(task.running, true);
      expect(task.matched, 1);
      expect(
        store.get('media', 'identity-ready')!.data['bangumiId'],
        isNotNull,
      );
      expect(store.local('episodeTitle:identity-ready'), isNull);
      model.fakeCatalog.episodeGate!.complete();
      model.setForeground(true);
      await task.done;
      expect(task.matched, 1);
      expect(task.failed, 0);
      expect(task.cancelled, false);
      expect(model.fakeCatalog.normalQueries, ['Example']);
      expect(model.fakeCatalog.episodeCalls, 2);
      expect(store.local('episodeTitle:identity-ready'), 'Official episode 1');
      expect(store.local('metadata:pending-tasks'), isEmpty);
    },
  );

  for (final ai in [false, true]) {
    test(
      'restarting resumes pending episode names without repeating completed identification (AI $ai)',
      () async {
        model.fakeCatalog.normalSubjects['Example'] = {
          ..._subject('Example'),
          'episodes': List.filled(100, {'unused': 'large metadata field'}),
        };
        model.fakeCatalog.episodeGate = Completer<void>();
        final task = model.startMetadataTask(
          [add('pending-name'), add('pending-name-2', episode: 2)],
          manual: false,
          ai: ai,
        );
        await model.fakeCatalog.episodeStarted.future;
        model.setForeground(false);
        await Future<void>.delayed(Duration.zero);
        final saved = store.local('metadata:pending-tasks') as List;
        final groups = (saved.single as Map)['episodeNames'] as List;
        expect(groups, hasLength(1));
        expect((groups.single as Map)['records'], hasLength(2));
        expect((groups.single as Map)['subject'], {
          'provider': 'bangumi',
          'mediaType': 'tv',
          'id': _subject('Example')['id'],
        });
        final savedId = task.id;
        model.dispose();
        await Future<void>.delayed(Duration.zero);
        store.dispose();
        store = AppStore('${directory.path}/test.db');
        model = _Model(store, directory);
        await Future<void>.delayed(Duration.zero);
        final restored = model.metadataTasks.single;
        expect(restored.id, savedId);
        await restored.done;
        expect(restored.matched, 2);
        expect(restored.failed, 0);
        expect(model.fakeCatalog.normalQueries, isEmpty);
        expect(model.ai.batches, isEmpty);
        expect(model.fakeCatalog.episodeCalls, 1);
        expect(store.local('episodeTitle:pending-name'), 'Official episode 1');
        expect(
          store.local('episodeTitle:pending-name-2'),
          'Official episode 2',
        );
        expect(store.local('metadata:pending-tasks'), isEmpty);
      },
    );
  }

  test('pending episode names respect user changes while suspended', () async {
    model.fakeCatalog.normalSubjects['Example'] = _subject('Example');
    model.fakeCatalog.episodeGate = Completer<void>();
    final task = model.startMetadataTask([add('edited-name')], manual: false);
    await model.fakeCatalog.episodeStarted.future;
    model.setForeground(false);
    await Future<void>.delayed(Duration.zero);
    final record = store.get('media', 'edited-name')!;
    store.save('media', record.id, {
      ...record.data,
      'episodeTitle': 'User chosen title',
    });
    model.fakeCatalog.episodeGate!.complete();
    model.setForeground(true);
    await task.done;
    expect(model.fakeCatalog.normalQueries, ['Example']);
    expect(model.fakeCatalog.episodeCalls, 1);
    expect(
      store.get('media', record.id)!.data['episodeTitle'],
      'User chosen title',
    );
    expect(store.local('episodeTitle:edited-name'), isNull);
  });

  test(
    'pending episode names skip deleted records and retain siblings',
    () async {
      model.fakeCatalog.normalSubjects['Example'] = _subject('Example');
      model.fakeCatalog.episodeGate = Completer<void>();
      final task = model.startMetadataTask([
        add('deleted-name'),
        add('retained-name', episode: 2),
      ], manual: false);
      await model.fakeCatalog.episodeStarted.future;
      model.setForeground(false);
      await Future<void>.delayed(Duration.zero);
      final record = store.get('media', 'deleted-name')!;
      store.save('media', record.id, record.data, deleted: true);
      model.fakeCatalog.episodeGate!.complete();
      model.setForeground(true);
      await task.done;
      expect(model.fakeCatalog.normalQueries, ['Example']);
      expect(model.fakeCatalog.episodeCalls, 2);
      expect(store.get('media', record.id)!.deleted, true);
      expect(store.local('episodeTitle:deleted-name'), isNull);
      expect(store.local('episodeTitle:retained-name'), 'Official episode 2');
      expect(store.local('metadata:pending-tasks'), isEmpty);
    },
  );

  test(
    'an automatic lookup returning while hidden defers follow-up work',
    () async {
      model.fakeCatalog.normalSubjects['Example'] = _subject('Example');
      model.fakeCatalog.normalGate = Completer<void>();
      final task = model.startMetadataTask([add('hidden')], manual: false);
      await model.fakeCatalog.normalStarted.future;
      model.setForeground(false);
      model.fakeCatalog.normalGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(task.running, true);
      expect(task.matched, 0);
      expect(model.fakeCatalog.episodeCalls, 0);
      expect(store.get('media', 'hidden')!.data['bangumiId'], isNull);

      model.setForeground(true);
      await task.done;
      expect(task.matched, 1);
      expect(model.fakeCatalog.episodeCalls, 1);
      expect(store.get('media', 'hidden')!.data['bangumiId'], isNotNull);
    },
  );

  test(
    'one batched parse and one work lookup preserve every episode',
    () async {
      final records = List.generate(12, (i) => add('$i', episode: i + 1));
      final task = model.startMetadataTask(records, ai: true);
      await task.done;
      expect(task.running, isFalse);
      expect(task.matched, 12);
      expect(task.failed, 0);
      expect(task.error, isEmpty);
      expect(model.ai.batches, hasLength(1));
      expect(model.ai.batches.single, hasLength(12));
      expect(model.ai.singles, isEmpty);
      expect(model.fakeCatalog.queries, ['Example']);
      expect(model.fakeCatalog.detailsCalls, 1);
      expect(
        model.ai.confirmations,
        hasLength(2),
        reason: 'one candidate check and one official-detail check per work',
      );
      expect(model.fakeCatalog.episodeCalls, 1);
      for (var i = 0; i < records.length; i++) {
        expect(store.get('media', records[i].id)!.data['episode'], '${i + 1}');
        expect(
          store.local('episodeTitle:${records[i].id}'),
          'Official episode ${i + 1}',
        );
      }
      expect(store.local('metadata:pending-tasks'), isEmpty);
    },
  );

  test('different works use at most three concurrent lookups', () async {
    model.fakeCatalog.searchGate = Completer<void>();
    final records = List.generate(
      7,
      (i) => add('$i', work: 'Work ${String.fromCharCode(65 + i)}'),
    );
    final task = model.startMetadataTask(records, ai: true);
    await model.fakeCatalog.thirdSearch.future;
    expect(model.fakeCatalog.active, 3);
    expect(model.fakeCatalog.queries, hasLength(3));
    model.fakeCatalog.searchGate!.complete();
    await task.done;
    expect(model.fakeCatalog.maximum, 3);
    expect(model.fakeCatalog.queries, hasLength(7));
    expect(task.matched, 7);
  });

  test(
    'hidden automatic AI tasks stop before follow-up catalogue requests',
    () async {
      model.ai.gate = Completer<void>();
      final task = model.startMetadataTask(
        [add('automatic-ai')],
        ai: true,
        manual: false,
      );
      await model.ai.started.future;
      model.setForeground(false);
      model.ai.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(task.running, true);
      expect(task.matched, 0);
      expect(model.fakeCatalog.queries, isEmpty);
      model.setForeground(true);
      await task.done;
      expect(task.matched, 1);
      expect(model.fakeCatalog.queries, ['Example']);
    },
  );

  test('backgrounding an AI lookup stops confirmation until visible', () async {
    model.fakeCatalog.searchGate = Completer<void>();
    final task = model.startMetadataTask(
      [add('automatic-confirm')],
      ai: true,
      manual: false,
    );
    await model.fakeCatalog.firstSearch.future;
    model.setForeground(false);
    model.fakeCatalog.searchGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(task.running, true);
    expect(task.matched, 0);
    expect(model.ai.confirmations, isEmpty);
    expect(model.fakeCatalog.detailsCalls, 0);
    model.setForeground(true);
    await task.done;
    expect(task.matched, 1);
    expect(model.ai.confirmations, hasLength(2));
  });

  test(
    'same-name episodic and non-episodic identities do not share movie confirmation',
    () async {
      model.ai.overrides['Example E01.mkv'] = const AiMediaIdentity(
        fileName: 'Example E01.mkv',
        name: 'Example',
        kind: 'anime',
        confidence: .99,
      );
      model.ai.overrides['Example E02.mkv'] = const AiMediaIdentity(
        fileName: 'Example E02.mkv',
        name: 'Example',
        kind: 'anime',
        episode: '2',
        confidence: .98,
      );
      model.fakeCatalog.overrides['Example'] = [
        _subject('Example', type: 'movie'),
        _subject('Example'),
      ];
      final first = add('first'), second = add('second', episode: 2);
      final task = model.startMetadataTask([first, second], ai: true);
      await task.done;
      expect(store.get('media', first.id)!.data['metadataType'], 'movie');
      expect(store.get('media', second.id)!.data['metadataType'], 'tv');
      expect(store.get('media', second.id)!.data['episode'], '2');
    },
  );

  test(
    'explicit cancellation releases the task queue without saving late results',
    () async {
      model.ai.gate = Completer<void>();
      final record = add('cancelled');
      final task = model.startMetadataTask([record], ai: true);
      await model.ai.started.future;
      model.cancelMetadataTask(task);
      await task.done;
      expect(task.cancelled, isTrue);
      expect(task.running, isFalse);
      expect(store.get('media', record.id)!.revision, record.revision);
      expect(store.local('metadata:pending-tasks'), isEmpty);
      model.ai.gate = null;
      final next = add('next', work: 'Next');
      final following = model.startMetadataTask([next], ai: true);
      await following.done.timeout(const Duration(seconds: 2));
      expect(following.matched, 1);
      expect(store.get('media', record.id)!.revision, record.revision);
    },
  );

  test(
    'late batch results preserve changed revisions and unchanged siblings still apply',
    () async {
      model.fakeCatalog.searchGate = Completer<void>();
      final first = add('first'), second = add('second', episode: 2);
      final task = model.startMetadataTask([first, second], ai: true);
      await model.fakeCatalog.firstSearch.future;
      store.save('media', first.id, {...first.data, 'series': 'User edit'});
      final edited = store.get('media', first.id)!;
      model.fakeCatalog.searchGate!.complete();
      await task.done;
      expect(task.matched, 1);
      expect(task.failed, 1);
      expect(store.get('media', first.id)!.data, edited.data);
      expect(store.get('media', first.id)!.revision, edited.revision);
      expect(store.local('episodeTitle:${first.id}'), isNull);
      expect(store.get('media', second.id)!.data['bangumiId'], isNotNull);
    },
  );

  test(
    'restarting resumes only unfinished records with the saved revision',
    () async {
      model.ai.gate = Completer<void>();
      final first = add('first'), second = add('second', episode: 2);
      final task = model.startMetadataTask([first, second], ai: true);
      await model.ai.started.future;
      final savedId = task.id;
      store.save('media', second.id, {
        ...second.data,
        'series': 'New user edit',
      });
      model.dispose();
      await Future<void>.delayed(Duration.zero);
      store.dispose();
      store = AppStore('${directory.path}/test.db');
      model = _Model(store, directory);
      await Future<void>.delayed(Duration.zero);
      final restored = model.metadataTasks.single;
      expect(restored.id, savedId);
      await restored.done;
      expect(restored.total, 1);
      expect(restored.matched, 1);
      expect(store.get('media', first.id)!.data['bangumiId'], isNotNull);
      expect(store.get('media', second.id)!.data['series'], 'New user edit');
      expect(store.get('media', second.id)!.data['bangumiId'], isNull);
      expect(store.local('metadata:pending-tasks'), isEmpty);
    },
  );

  test(
    'ordinary matches skip AI and only unresolved groups use batch fallback',
    () async {
      final known = add('known', work: 'Known');
      final first = add('first'), second = add('second', episode: 2);
      model.fakeCatalog.normalSubjects['Known'] = _subject('Known');
      final task = model.startMetadataTask([
        known,
        first,
        second,
      ], manual: false);
      await task.done;
      expect(task.matched, 3);
      expect(model.fakeCatalog.normalQueries.toSet(), {'Known', 'Example'});
      expect(model.ai.batches.single, [
        first.data['fileName'],
        second.data['fileName'],
      ]);
      expect(model.fakeCatalog.queries, ['Example']);
      expect(store.local('manualMetadata:${first.id}'), isNot(true));
    },
  );

  test(
    'AI recovery of ordinary lookup errors finishes as a successful task',
    () async {
      model.fakeCatalog.normalFailures.add('Example');
      final task = model.startMetadataTask([
        add('first'),
        add('second', episode: 2),
      ], manual: false);
      await task.done;
      expect(task.matched, 2);
      expect(model.ai.batches, hasLength(1));
      expect(task.error, isEmpty);
      expect(task.status, '已匹配 2 个视频');
    },
  );

  test('failed tasks do not block following tasks', () async {
    final first = add('first', work: 'Failure');
    final second = add('second', work: 'Success');
    model.ai.failNames.add('${first.data['fileName']}');
    final failed = model.startMetadataTask([first], ai: true);
    final following = model.startMetadataTask([second], ai: true);
    await following.done.timeout(const Duration(seconds: 2));
    expect(failed.running, isFalse);
    expect(failed.error, isNotEmpty);
    expect(following.matched, 1);
    expect(store.get('media', first.id)!.revision, first.revision);
    expect(store.get('media', second.id)!.data['bangumiId'], isNotNull);
    expect(store.local('metadata:pending-tasks'), isEmpty);
  });

  test(
    'repeated starts share one running task and observer removal does not cancel it',
    () async {
      model.ai.gate = Completer<void>();
      final records = [add('first'), add('second', episode: 2)];
      final task = model.startMetadataTask(records, ai: true);
      expect(model.startMetadataTask(records, ai: true), same(task));
      void listener() {}
      task.addListener(listener);
      await model.ai.started.future;
      task.removeListener(listener);
      expect(task.running, isTrue);
      model.ai.gate!.complete();
      await task.done;
      expect(task.cancelled, isFalse);
      expect(task.matched, 2);
      expect(model.ai.batches, hasLength(1));
    },
  );
}
