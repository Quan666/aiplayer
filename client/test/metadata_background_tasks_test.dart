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
  Completer<void>? gate;

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
    if (!started.isCompleted) started.complete();
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
  Completer<void>? searchGate;
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

  test('automatic tasks wait for foreground and playback without blocking manual work', () async {
    model.setForeground(false);
    final automatic = model.startMetadataTask([add('automatic')], manual: false);
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
  });

  test('cancelling a suspended task keeps it from restarting on resume', () async {
    model.setForeground(false);
    final task = model.startMetadataTask([add('cancelled')], manual: false);
    await Future<void>.delayed(Duration.zero);
    model.cancelMetadataTask(task);
    await task.done;
    model.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(task.cancelled, true);
    expect(model.fakeCatalog.normalQueries, isEmpty);
  });

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
