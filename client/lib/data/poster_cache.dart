import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

// Weak file handles carry the content generation into Flutter's decoded cache.
// No file access or image retention is needed when a widget builds.
final _posterFileRevisions = Expando<int>();
int _nextPosterFileRevision = 0;

int posterFileRevision(File file) => _posterFileRevisions[file] ?? 0;

class PosterCacheChange {
  final String url;
  final File? file;

  const PosterCacheChange(this.url, this.file);
}

/// Persistent, device-local artwork. A URL is downloaded once and shared by
/// library cards, folders and details, including after restarting the app.
class PosterCache {
  final Directory directory;
  // Kept for source compatibility; successful artwork is never size-evicted.
  final int maxBytes, maxFileBytes;
  final Duration timeout;
  final HttpClient Function() createClient;
  final _pending = <String, Future<File?>>{};
  final _invalidating = <String, Future<void>>{};
  final _resolved = <String, File>{};
  final _failedUntil = <String, DateTime>{};
  final _priority = <String>{};
  final _capacity = ValueNotifier(0);
  final _changes = ValueNotifier<PosterCacheChange?>(null);
  HttpClient? _client;
  final _waiting = <_PosterWaiter>[];
  static const maxPending = 68;
  int _active = 0;
  bool _closed = false;

  PosterCache({
    required this.directory,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxFileBytes = 12 * 1024 * 1024,
    this.timeout = const Duration(seconds: 15),
    HttpClient Function()? createClient,
  }) : createClient = createClient ?? HttpClient.new;

  /// A single notification wakes visible covers deferred by a full queue.
  Listenable get capacity => _capacity;

  /// Content changes invalidate mounted covers; normal cache hits stay silent.
  ValueListenable<PosterCacheChange?> get changes => _changes;

  /// Called after another isolate atomically replaces an artwork file.
  void fileChanged(String url) {
    if (_closed) return;
    _resolved.remove(url);
    _failedUntil.remove(url);
    _changes.value = PosterCacheChange(url, null);
  }

  /// Visible artwork takes the next free download slot ahead of prefetches.
  /// Null means admission was deferred, rather than that a download failed.
  Future<File?>? loadVisible(String url) {
    if (_closed || url.isEmpty || _resolved.containsKey(url)) return load(url);
    if (!_pending.containsKey(url) && _pending.length >= maxPending) {
      final index = _waiting.indexWhere(
        (waiter) => !_priority.contains(waiter.url),
      );
      if (index < 0) return null;
      final displaced = _waiting.removeAt(index);
      _pending.remove(displaced.url);
      displaced.ready.complete(false);
    }
    _priority.add(url);
    final index = _waiting.indexWhere((waiter) => waiter.url == url);
    if (index >= 0) {
      final waiter = _waiting.removeAt(index);
      final firstBackground = _waiting.indexWhere(
        (entry) => !_priority.contains(entry.url),
      );
      _waiting.insert(
        firstBackground < 0 ? _waiting.length : firstBackground,
        waiter,
      );
    }
    return load(url);
  }

  File _file(String url) =>
      File('${directory.path}/${sha256.convert(utf8.encode(url))}.image');

  /// Read without fetching: synchronization only shares artwork already held.
  File cachedFile(String url) => _file(url);

  File? resolvedFile(String url) {
    final file = _resolved.remove(url);
    if (file != null) _resolved[url] = file;
    return file;
  }

  void _remember(String url, File file) {
    _posterFileRevisions[file] ??= ++_nextPosterFileRevision;
    _resolved.remove(url);
    _resolved[url] = file;
    // Only path handles are evicted; successful files remain on disk.
    while (_resolved.length > 512) {
      _resolved.remove(_resolved.keys.first);
    }
  }

  void _failed(String url) {
    _failedUntil.remove(url);
    _failedUntil[url] = DateTime.now().add(const Duration(minutes: 2));
    while (_failedUntil.length > 256) {
      _failedUntil.remove(_failedUntil.keys.first);
    }
  }

  Future<void> restore(
    String url,
    Uint8List bytes, {
    bool replace = false,
  }) async {
    if (_closed) return;
    final file = _file(url);
    if (!replace && await file.exists() && await file.length() > 0) return;
    await _validate(bytes);
    if (_closed) return;
    await directory.create(recursive: true);
    final temporary = File('${file.path}.sync-part');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    if (_closed) return;
    _failedUntil.remove(url);
    _remember(url, file);
    _changes.value = PosterCacheChange(url, file);
  }

  Future<File?> load(String url) {
    if (_closed || url.isEmpty) return Future.value();
    final cached = resolvedFile(url);
    if (cached != null) return SynchronousFuture(cached);
    final pending = _pending[url];
    if (pending != null) return pending;
    // Keep four admissions for visible covers, including their disk lookup;
    // a full metadata-prefetch queue must not delay an offline detail poster.
    final limit = _priority.contains(url) ? maxPending : maxPending - 4;
    if (_pending.length >= limit) return Future.value();
    late final Future<File?> result;
    result = _load(url)
        .then((file) {
          if (file != null &&
              !_closed &&
              identical(_pending[url], result) &&
              !_resolved.containsKey(url)) {
            _remember(url, file);
          }
          return file;
        })
        .whenComplete(() {
          if (identical(_pending[url], result)) {
            _pending.remove(url);
            _priority.remove(url);
          }
          if (!_closed) _capacity.value++;
        });
    _pending[url] = result;
    return result;
  }

  Future<File?> _load(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final file = _file(url);
    try {
      await _invalidating[url];
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
      if ((_failedUntil[url]?.isAfter(DateTime.now()) ?? false) || _closed) {
        return null;
      }
      if (_active >= 4) {
        final waiting = _PosterWaiter(url);
        final firstBackground = _priority.contains(url)
            ? _waiting.indexWhere((entry) => !_priority.contains(entry.url))
            : -1;
        _waiting.insert(
          firstBackground < 0 ? _waiting.length : firstBackground,
          waiting,
        );
        if (!await waiting.ready.future) return null;
      } else {
        _active++;
      }
      HttpClientRequest? request;
      StreamIterator<List<int>>? chunks;
      var expired = false;
      try {
        if (_closed) return null;
        // One pool reuses HTTP/TLS connections across covers. Cancellation
        // belongs to each request, never to other downloads sharing the pool.
        final client = _client ??= createClient()
          ..connectionTimeout = timeout
          ..idleTimeout = const Duration(seconds: 15)
          ..maxConnectionsPerHost = 4;
        Future<File?> work() async {
          final opened = request = await client.getUrl(uri);
          if (_closed || expired) {
            opened.abort();
            return null;
          }
          opened.maxRedirects = 3;
          final response = await opened.close();
          final reader = chunks = StreamIterator(response);
          if (_closed || expired) return null;
          if (response.statusCode != HttpStatus.ok ||
              response.contentLength > maxFileBytes) {
            throw const FormatException('Invalid artwork response');
          }
          final bytes = BytesBuilder(copy: false);
          while (await reader.moveNext()) {
            bytes.add(reader.current);
            if (bytes.length > maxFileBytes) {
              throw const FormatException('Artwork too large');
            }
          }
          final data = bytes.takeBytes();
          await _validate(data);
          if (_closed || expired) return null;
          await directory.create(recursive: true);
          if (_closed || expired) return null;
          final temporary = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
          );
          try {
            await temporary.writeAsBytes(data, flush: true);
            if (_closed || expired) return null;
            await temporary.rename(file.path);
          } finally {
            try {
              await temporary.delete();
            } on FileSystemException {
              // A successful atomic rename already removed the temporary file.
            }
          }
          return file;
        }

        return await work().timeout(
          timeout,
          onTimeout: () {
            expired = true;
            request?.abort();
            unawaited(chunks?.cancel());
            throw TimeoutException('Artwork download timed out');
          },
        );
      } finally {
        try {
          await chunks?.cancel();
        } finally {
          if (_waiting.isNotEmpty) {
            _waiting.removeAt(0).ready.complete(true);
          } else {
            _active--;
          }
        }
      }
    } catch (_) {
      // Rebuilds or several cards for the same offline host must not retry
      // indefinitely. A later visit may try again without losing other covers.
      if (!_closed) _failed(url);
      return null;
    }
  }

  Future<void> _validate(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width * descriptor.height > 64000000) {
        throw const FormatException('Invalid artwork dimensions');
      }
      // Validation only needs a tiny frame. Width alone can still decode a
      // very tall image into a huge pixel buffer.
      final scale = math.min(
        1.0,
        32 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> invalidate(
    String url, {
    File? failedFile,
    bool retryImmediately = false,
  }) {
    final invalidating = _invalidating[url];
    if (invalidating != null) return invalidating;
    // Another visible card may already have replaced this failed file. Do not
    // delete its successful repair when an older Image reports its error late.
    final current = _resolved[url];
    if (failedFile != null &&
        current != null &&
        !identical(current, failedFile)) {
      return Future.value();
    }
    if (failedFile != null && current == null && _pending.containsKey(url)) {
      return _pending[url]!.then<void>((_) {});
    }
    _resolved.remove(url);
    _changes.value = PosterCacheChange(url, null);
    if (retryImmediately) {
      _failedUntil.remove(url);
    } else {
      _failed(url);
    }
    final result = _delete(url).whenComplete(() {
      _invalidating.remove(url);
    });
    _invalidating[url] = result;
    return result;
  }

  Future<void> _delete(String url) async {
    try {
      await _file(url).delete();
    } on FileSystemException {
      // Already removed or unavailable.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _resolved.clear();
    _failedUntil.clear();
    _priority.clear();
    _client?.close(force: true);
    _client = null;
    for (final waiting in _waiting) {
      waiting.ready.complete(false);
    }
    _waiting.clear();
    _capacity.dispose();
    _changes.dispose();
  }
}

class _PosterWaiter {
  final String url;
  final ready = Completer<bool>();

  _PosterWaiter(this.url);
}
