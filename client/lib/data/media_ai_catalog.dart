import 'dart:isolate';

import '../core/network.dart';
import '../subtitles/ai.dart';
import 'library_catalog.dart';
import 'media_ai_recognition.dart';

class MediaAiCatalogMatch {
  final AiMediaIdentity identity;
  final List<Map<String, dynamic>> candidates;
  final Map<String, dynamic>? subject;
  const MediaAiCatalogMatch(this.identity, this.candidates, this.subject);
}

Future<List<List<AiMediaIdentity>>> groupAiCatalogIdentities(
  List<AiMediaIdentity> identities,
) async => identities.length < 64
    ? _groupIdentities(identities)
    : Isolate.run(() => _groupIdentities(identities));

List<List<AiMediaIdentity>> _groupIdentities(List<AiMediaIdentity> identities) {
  final groups = <Object, List<AiMediaIdentity>>{};
  for (final identity in identities) {
    final key = (
      normalizedSeries(identity.name),
      identity.kind,
      identity.season,
      identity.year,
      identity.episode.isNotEmpty,
    );
    final group = groups.putIfAbsent(key, () => []);
    group.add(identity);
    if (identity.confidence > group.first.confidence) {
      group[group.length - 1] = group.first;
      group[0] = identity;
    }
  }
  return groups.values.toList();
}

/// Shared by foreground tasks and the directory worker. AI may choose only
/// real catalogue candidates; provider details and season checks remain final.
Future<MediaAiCatalogMatch> searchAiCatalogIdentity(
  AiMediaIdentity identity, {
  required LibraryCatalog catalog,
  required MediaAiRecognition mediaAi,
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
  if (candidates.length > 80) {
    return MediaAiCatalogMatch(identity, candidates, null);
  }
  final selected = await mediaAi.confirm(
    identity,
    candidates,
    config: config,
    cancel: cancel,
  );
  cancel.check();
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
      return MediaAiCatalogMatch(identity, candidates, null);
    }
    cancel.check();
    checkReady?.call();
    if (subject['provider'] == 'bangumi' &&
        identity.season.isNotEmpty &&
        !identity.searchNames.any(
          (name) => subjectMatchesSeason(name, identity.season, subject!),
        )) {
      return MediaAiCatalogMatch(identity, candidates, null);
    }
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
  return MediaAiCatalogMatch(identity, candidates, subject);
}
