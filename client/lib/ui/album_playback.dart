import 'package:flutter/material.dart';

import '../core/network.dart';
import '../core/logger.dart';
import '../data/app_model.dart';
import '../playback/session.dart';
import '../sources/media_kind.dart';
import '../sources/source.dart';
import 'artwork_lifecycle.dart';
import 'music_page.dart';
import 'player_page.dart';

/// A tap cannot survive backgrounding and later become an unsolicited open.
/// This guard starts before credential/database/disposal waits, earlier than
/// the playback session's own source and native-open revision guards.
class AlbumOpenAttempt {
  final CancelToken token = CancelToken();
  final bool Function() isCurrent;
  bool _disposed = false;
  AlbumOpenAttempt(this.isCurrent) {
    ArtworkLifecycle.instance.addListener(_lifecycle);
    _lifecycle();
  }

  void _lifecycle() {
    if (!ArtworkLifecycle.instance.value) token.cancel();
  }

  void check() {
    token.check();
    if (_disposed || !isCurrent() || !ArtworkLifecycle.instance.value) {
      token.cancel();
      throw const Cancelled();
    }
  }

  void cancel() => token.cancel();
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    token.cancel();
    ArtworkLifecycle.instance.removeListener(_lifecycle);
  }
}

Future<void> playAlbumMedia(
  BuildContext context,
  AppModel model,
  String sourceId,
  SourceEntry entry, {
  required AlbumOpenAttempt attempt,
  PlaybackSession? transferredSession,
  bool? play,
}) async {
  var transferred = false;
  try {
    attempt.check();
    if (isAudioFile(entry.name)) {
      await PlayerPage.waitForDisposals();
      attempt.check();
      await MusicPage.waitForDisposals();
      attempt.check();
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MusicPage(
            model: model,
            sourceId: sourceId,
            entries: [entry],
            initialIndex: 0,
          ),
        ),
      );
      return;
    }
    final media =
        transferredSession?.media ??
        await model.preparePersonalMediaForPlayback(
          sourceId,
          entry,
          cancel: attempt.token,
        );
    attempt.check();
    await PlayerPage.waitForDisposals();
    attempt.check();
    await MusicPage.waitForDisposals();
    attempt.check();
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) {
          transferred = true;
          return PlayerPage(
            model: model,
            media: media,
            initialSession: transferredSession,
            initialPlay: play,
          );
        },
      ),
    );
  } on Cancelled {
    // Cancellation is an expected navigation/lifecycle outcome.
  } catch (error) {
    if (context.mounted && !attempt.token.cancelled && attempt.isCurrent()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(safeFailure(error, action: '打开媒体失败').message)),
      );
    }
  } finally {
    if (!transferred) await transferredSession?.close();
  }
}
