part of 'app_model.dart';

class AiMetadataMatch {
  final AiMediaIdentity identity;
  final List<Map<String, dynamic>> candidates;
  final Map<String, dynamic>? subject;
  const AiMetadataMatch(this.identity, this.candidates, this.subject);
}

extension MediaAiIdentification on AppModel {
  String get _metadataAiContext => jsonEncode([
    preferences.aiMetadataEnabled,
    settings['aiSubtitleOrigin'],
    settings['aiSubtitleModel'],
    store.local('metadataCredentialsRevision'),
  ]);

  Future<SubtitleAiConfig> _metadataAiConfig() async {
    final token = await secrets.read(key: 'aiSubtitleToken') ?? '';
    AppLog.instance.rememberSecret(token);
    return SubtitleAiConfig(
      origin: '${settings['aiSubtitleOrigin'] ?? 'https://api.openai.com/v1'}',
      token: token,
      model: '${settings['aiSubtitleModel'] ?? ''}',
      prompt: '',
    );
  }

  String metadataFileName(SyncRecord record) =>
      '${record.data['fileName'] ?? record.data['title'] ?? record.data['series'] ?? ''}';

  Future<AiMediaIdentity> analyzeMetadataFileName(
    String fileName, {
    required CancelToken cancel,
  }) async => mediaAi.analyzeFilename(
    fileName,
    config: await _metadataAiConfig(),
    cancel: cancel,
  );

  /// Search only catalogue names proposed from a basename; AI never supplies
  /// posters, descriptions, provider identifiers or playback locations.
  Future<AiMetadataMatch> searchMetadataWithAi(
    String fileName, {
    required CancelToken cancel,
  }) async {
    final config = await _metadataAiConfig();
    final identity = await mediaAi.analyzeFilename(
      fileName,
      config: config,
      cancel: cancel,
    );
    return _searchAiIdentity(identity, config: config, cancel: cancel);
  }

  Future<AiMetadataMatch> _searchAiIdentity(
    AiMediaIdentity identity, {
    required SubtitleAiConfig config,
    required CancelToken cancel,
    void Function()? checkReady,
  }) async {
    final found = <String, Map<String, dynamic>>{};
    Object? failure;
    final names = identity.searchNames.take(4).toList();
    var next = 0;
    Future<void> searchNames() async {
      while (next < names.length) {
        final name = names[next++];
        cancel.check();
        checkReady?.call();
        try {
          for (final candidate in await catalog.search(name, cancel: cancel)) {
            found['${candidate['provider']}:${candidate['mediaType']}:${candidate['id']}'] =
                candidate;
          }
        } on Cancelled {
          rethrow;
        } catch (error) {
          failure = error;
        }
      }
    }

    await Future.wait([searchNames(), searchNames()]);
    cancel.check();
    checkReady?.call();
    if (found.isEmpty && failure != null) throw failure!;
    final candidates = found.values.toList();
    // Do not truncate a broad result set then claim the remaining candidate
    // is unique. Keep the complete list available for manual selection.
    if (candidates.length > 80) {
      return AiMetadataMatch(identity, candidates, null);
    }
    final selected = await mediaAi.confirm(
      identity,
      candidates,
      config: config,
      cancel: cancel,
    );
    checkReady?.call();
    Map<String, dynamic>? subject;
    if (selected != null) {
      try {
        subject = await catalog.details(
          selected,
          season: identity.season,
          cancel: cancel,
        );
      } on Cancelled {
        rethrow;
      } on AppFailure {
        return AiMetadataMatch(identity, candidates, null);
      }
      checkReady?.call();
      if (subject['provider'] == 'bangumi' &&
          identity.season.isNotEmpty &&
          !identity.searchNames.any(
            (name) => subjectMatchesSeason(name, identity.season, subject!),
          )) {
        return AiMetadataMatch(identity, candidates, null);
      }
      // Details can expose a season/type contradiction absent from search.
      final confirmed = await mediaAi.confirm(
        identity,
        [subject],
        config: config,
        cancel: cancel,
      );
      if (confirmed == null) subject = null;
    }
    cancel.check();
    checkReady?.call();
    return AiMetadataMatch(identity, candidates, subject);
  }

  /// Parse filenames in batches, then search/confirm once per work and season.
  /// Each returned identity retains its own episode number.
  Future<Map<String, AiMetadataMatch>> searchMetadataBatchWithAi(
    List<String> fileNames, {
    required CancelToken cancel,
    void Function(String)? onProgress,
    void Function()? checkReady,
  }) async {
    if (fileNames.isEmpty) return {};
    final config = await _metadataAiConfig();
    checkReady?.call();
    final names = fileNames
        .map(MediaAiRecognition.filenameOnly)
        .toSet()
        .toList();
    final parsed = names.length == 1
        ? {
            names.single: await mediaAi.analyzeFilename(
              names.single,
              config: config,
              cancel: cancel,
            ),
          }
        : await mediaAi.analyzeFilenames(names, config: config, cancel: cancel);
    cancel.check();
    checkReady?.call();
    final groups = <String, List<AiMediaIdentity>>{};
    for (final identity in parsed.values) {
      final key = jsonEncode([
        normalizedSeries(identity.name),
        identity.kind,
        identity.season,
        identity.year,
        identity.episode.isNotEmpty,
      ]);
      (groups[key] ??= []).add(identity);
    }
    final results = <String, AiMetadataMatch>{};
    var complete = 0;
    Object? failure;
    await Future.wait(
      groups.values.map(
        (group) => _metadataLookups.run(cancel, () async {
          checkReady?.call();
          group.sort((a, b) => b.confidence.compareTo(a.confidence));
          AiMetadataMatch? match;
          try {
            match = await _searchAiIdentity(
              group.first,
              config: config,
              cancel: cancel,
              checkReady: checkReady,
            );
          } on Cancelled {
            rethrow;
          } on _MetadataPaused {
            rethrow;
          } catch (error) {
            failure = error;
          }
          cancel.check();
          checkReady?.call();
          for (final identity in group) {
            results[identity.fileName] = AiMetadataMatch(
              identity,
              match?.candidates ?? [],
              identity.confidence >= mediaAiAutomaticConfidence
                  ? match?.subject
                  : null,
            );
          }
          complete++;
          onProgress?.call('正在搜索并核对作品 $complete/${groups.length}…');
        }),
      ),
    );
    cancel.check();
    if (failure != null &&
        results.values.every((result) => result.candidates.isEmpty)) {
      throw failure!;
    }
    return results;
  }

  bool _aiRecordCurrent(SyncRecord record, bool manual, String context) {
    if (_disposed) return false;
    final current = store.get('media', record.id);
    if (current == null ||
        current.deleted ||
        current.revision != record.revision) {
      return false;
    }
    return manual ||
        (preferences.aiMetadataEnabled &&
            preferences.metadataStrategy != 'off' &&
            _metadataAiContext == context &&
            store.local('manualMetadata:${record.id}') != true &&
            current.data['bangumiId'] == null &&
            current.data['tmdbId'] == null);
  }

  Future<bool> identifyMediaWithAi(
    SyncRecord record, {
    required CancelToken cancel,
    bool manual = true,
    AiMetadataMatch? match,
    bool fillNames = true,
    bool notify = true,
  }) async {
    final context = _metadataAiContext;
    if (!_aiRecordCurrent(record, manual, context)) return false;
    final result =
        match ??
        await searchMetadataWithAi(metadataFileName(record), cancel: cancel);
    final subject = result.subject;
    if (subject == null) return false;
    // A result is bound to one filename. Never copy episode 1 to every record
    // in a multi-file manual selection.
    if (result.identity.fileName !=
        MediaAiRecognition.filenameOnly(metadataFileName(record))) {
      return identifyMediaWithAi(record, cancel: cancel, manual: manual);
    }
    cancel.check();
    if (!_aiRecordCurrent(record, manual, context)) return false;
    final identity = result.identity;
    final movie = subject['mediaType'] == 'movie';
    final fields = subjectMediaFields(subject);
    final data = {...record.data}
      ..remove('bangumiId')
      ..remove('tmdbId')
      ..remove('episodeTitle');
    store.save('media', record.id, {
      ...data,
      ...fields,
      'series': identity.name,
      'season': movie ? '' : identity.season,
      'episode': movie ? '' : identity.episode,
    });
    _prefetchPoster('${fields['poster']}');
    store.removeLocal('episodeTitle:${record.id}');
    if (manual) store.setLocal('manualMetadata:${record.id}', true);
    if (notify) changed();
    if (!fillNames) return true;
    try {
      await _applyEpisodeNames(
        store.get('media', record.id)!,
        subject,
        cancel: cancel,
        mediaIds: {record.id},
      );
    } on Cancelled {
      rethrow;
    } catch (_) {
      // Official identity remains usable if the optional episode list is down.
    }
    return true;
  }

  /// Used only after normal directory identification fails. Every video must
  /// resolve to the same official work and season before replacing file browse.
  Future<DirectoryCollection?> _identifyDirectoryWithAi(
    String sourceId,
    String path,
    List<SourceEntry> entries,
    CancelToken? cancel,
  ) async {
    if (!preferences.aiMetadataEnabled ||
        preferences.metadataStrategy == 'off') {
      return null;
    }
    final context = _metadataAiContext;
    final token = cancel ?? _metadataCancel;
    final videos = entries
        .where((e) => !e.directory && isVideo(e.name))
        .toList();
    if (videos.isEmpty || videos.length > 1000) return null;
    AiMetadataMatch? first;
    final identities = <String, ReleaseName>{};
    final matches = await searchMetadataBatchWithAi(
      videos.map((video) => video.name).toList(),
      cancel: token,
    );
    for (final video in videos) {
      token.check();
      if (_disposed ||
          context != _metadataAiContext ||
          preferences.metadataStrategy == 'off') {
        return null;
      }
      final match = matches[MediaAiRecognition.filenameOnly(video.name)];
      if (match == null || match.subject == null) return null;
      first ??= match;
      final a = first.subject!, b = match.subject!;
      if (a['provider'] != b['provider'] ||
          '${a['id']}' != '${b['id']}' ||
          a['mediaType'] != b['mediaType'] ||
          first.identity.season != match.identity.season) {
        return null;
      }
      identities[video.path] = ReleaseName(
        first.identity.name,
        match.identity.season,
        match.identity.episode,
      );
    }
    token.check();
    if (_disposed ||
        context != _metadataAiContext ||
        preferences.metadataStrategy == 'off') {
      return null;
    }
    final subject = first!.subject!;
    Map<String, String> titles = {};
    try {
      titles = await catalog.episodeNames(
        '${subject['id']}',
        subject: subject,
        cancel: token,
      );
    } on Cancelled {
      rethrow;
    } catch (_) {
      /* optional episode names */
    }
    return DirectoryCollection(
      title: first.identity.name,
      season: first.identity.season,
      videos: videos,
      identities: identities,
      subject: subject,
      episodeTitles: titles,
    );
  }
}
