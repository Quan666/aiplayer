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
final _posterFileEpochs = Expando<_PosterEpoch>();
int _nextPosterFileRevision = 0;

int posterFileRevision(File file) => _posterFileRevisions[file] ?? 0;

class PosterCacheChange {
  final String url;
  final File? file;

  const PosterCacheChange(this.url, this.file);

  const PosterCacheChange.cleared() : url = '', file = null;

  bool get all => url.isEmpty;
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
  // A decoded image can outlive the small path-handle LRU. Keep only a weak
  // reference to that handle so revisiting it reuses the same content revision
  // instead of invalidating an unchanged, still-resident decoded image.
  final _retained = <String, _PosterFileHandle>{};
  static final _releaseHandle = Finalizer<_PosterFileHandle>((handle) {
    final cache = handle.cache.target;
    if (cache != null && identical(cache._retained[handle.url], handle)) {
      cache._retained.remove(handle.url);
    }
  });
  final _failedUntil = <String, DateTime>{};
  final _priority = <String>{};
  final _nearby = <String, _PosterNearbyRequest>{};
  final _capacity = ValueNotifier(0);
  final _changes = ValueNotifier<PosterCacheChange?>(null);
  final _work = <Future<void>>{};
  _PosterEpoch _epoch = _PosterEpoch();
  Future<void>? _clearing;
  int _nextTemporary = 0;
  HttpClient? _client;
  final _waiting = <_PosterWaiter>[];
  static const maxPending = 68;
  int _active = 0;
  bool _closed = false;
  Completer<void>? _resume;

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

  /// Suspend queued disk lookups and transfers while the app is hidden.
  /// Existing transfers may finish; their bounded slots are not refilled until
  /// foregrounded. Keeping the same futures avoids duplicate work on resume.
  void setActive(bool active) {
    if (_closed) return;
    if (!active) {
      _resume ??= Completer<void>();
      return;
    }
    final resume = _resume;
    if (resume == null) return;
    _resume = null;
    resume.complete();
    _dispatchWaiting();
  }

  void _dispatchWaiting() {
    if (_closed || _clearing != null || _resume != null) return;
    while (_active < 4 && _waiting.isNotEmpty) {
      _active++;
      _waiting.removeAt(0).ready.complete(true);
    }
  }

  bool _current(_PosterEpoch epoch) =>
      !_closed && _clearing == null && identical(_epoch, epoch);

  Future<void> _waitUntilActive(_PosterEpoch epoch) async {
    // A quick foreground/background pair must not let an earlier completed
    // gate admit new work into the newer suspended period.
    while (_current(epoch) && _resume != null) {
      await _resume!.future;
    }
  }

  /// Called after another isolate atomically replaces an artwork file.
  void fileChanged(String url) {
    if (_closed || _clearing != null) return;
    _forget(url);
    _failedUntil.remove(url);
    _changes.value = PosterCacheChange(url, null);
  }

  /// Visible artwork takes the next free download slot ahead of prefetches.
  /// Null means admission was deferred, rather than that a download failed.
  Future<File?>? loadVisible(String url) {
    if (_clearing != null) return null;
    if (_closed || url.isEmpty || resolvedFile(url) != null) return load(url);
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
    _nearby.remove(url)?.promoted = true;
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

  /// At most three speculative lookups/downloads leave a slot for visible work.
  /// Null means admission was deferred; [capacity] signals a later retry.
  Future<File?>? loadNearby(String url, {required bool Function() canStart}) {
    if (_clearing != null) return null;
    if (_closed || url.isEmpty || resolvedFile(url) != null) return load(url);
    final pending = _pending[url];
    if (pending != null) {
      // A newly mounted card can take over an existing nearby request. A
      // visible promotion has already removed its speculative classification.
      _nearby[url]?.canStart = canStart;
      return pending;
    }
    if (!canStart()) return Future.value();
    _dropStaleNearby();
    if (_nearby.length >= 3 || _pending.length >= maxPending - 4) return null;
    final nearby = _PosterNearbyRequest(canStart);
    _nearby[url] = nearby;
    final result = load(url);
    void completed() {
      // Base load() releases this with its normal capacity notification. This
      // also supports subclasses that override load() without using its queue.
      if (identical(_nearby[url], nearby)) {
        _nearby.remove(url);
        if (!_closed && _clearing == null) _capacity.value++;
      }
    }

    unawaited(
      result.then<void>(
        (_) => completed(),
        onError: (Object _, StackTrace _) {
          completed();
        },
      ),
    );
    return result;
  }

  void _dropStaleNearby() {
    // Never release an in-flight lookup or transfer early: it still counts
    // against the three speculative slots until the platform work completes.
    for (final entry in _nearby.entries.toList()) {
      if (entry.value.allowed) continue;
      final index = _waiting.indexWhere((waiter) => waiter.url == entry.key);
      if (index < 0) continue;
      final waiter = _waiting.removeAt(index);
      _nearby.remove(entry.key);
      _pending.remove(entry.key);
      waiter.ready.complete(false);
    }
  }

  File _file(String url) =>
      File('${directory.path}/${sha256.convert(utf8.encode(url))}.image');

  /// Read without fetching: synchronization only shares artwork already held.
  File cachedFile(String url) => _file(url);

  File? resolvedFile(String url) {
    final file = _resolved.remove(url) ?? _retained[url]?.file.target;
    if (file != null) {
      _resolved[url] = file;
      _trimResolved();
    }
    return file;
  }

  void _remember(String url, File file) {
    _posterFileRevisions[file] ??= ++_nextPosterFileRevision;
    _posterFileEpochs[file] = _epoch;
    final previous = _retained.remove(url);
    if (previous != null) _releaseHandle.detach(previous);
    final handle = _PosterFileHandle(this, url, file);
    _retained[url] = handle;
    _releaseHandle.attach(file, handle, detach: handle);
    _resolved.remove(url);
    _resolved[url] = file;
    _trimResolved();
  }

  void _forget(String url) {
    _resolved.remove(url);
    final handle = _retained.remove(url);
    if (handle != null) _releaseHandle.detach(handle);
  }

  void _trimResolved() {
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

  Future<void> restore(String url, Uint8List bytes, {bool replace = false}) {
    if (_closed || _clearing != null) return Future.value();
    return _track(_restore(url, bytes, replace, _epoch));
  }

  Future<void> _restore(
    String url,
    Uint8List bytes,
    bool replace,
    _PosterEpoch epoch,
  ) async {
    final file = _file(url);
    if (!replace && await file.exists() && await file.length() > 0) return;
    if (!_current(epoch)) return;
    await _validate(bytes);
    if (!_current(epoch)) return;
    await directory.create(recursive: true);
    if (!_current(epoch)) return;
    final temporary = File('${file.path}.${++_nextTemporary}.sync-part');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (!_current(epoch)) return;
      await temporary.rename(file.path);
    } finally {
      try {
        await temporary.delete();
      } on FileSystemException {
        // A successful atomic rename already removed the temporary file.
      }
    }
    if (!_current(epoch)) return;
    _failedUntil.remove(url);
    _remember(url, file);
    _changes.value = PosterCacheChange(url, file);
  }

  Future<File?> load(String url) {
    if (_closed || _clearing != null || url.isEmpty) return Future.value();
    final epoch = _epoch;
    final cached = resolvedFile(url);
    if (cached != null) return SynchronousFuture(cached);
    final pending = _pending[url];
    if (pending != null) return pending;
    // Keep four admissions for visible covers, including their disk lookup;
    // a full metadata-prefetch queue must not delay an offline detail poster.
    final limit = _priority.contains(url) ? maxPending : maxPending - 4;
    if (_pending.length >= limit) return Future.value();
    late final Future<File?> result;
    result = _load(url, epoch)
        .then((file) {
          if (!_current(epoch)) return null;
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
            _nearby.remove(url);
          }
          if (!_closed && _clearing == null) _capacity.value++;
        });
    _pending[url] = result;
    return _track(result);
  }

  Future<File?> _load(String url, _PosterEpoch epoch) async {
    final nearby = _nearby[url];
    if (nearby?.allowed == false) return null;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final file = _file(url);
    try {
      await _waitUntilActive(epoch);
      await _invalidating[url];
      if (nearby?.allowed == false || !_current(epoch)) return null;
      if (await file.exists() && await file.length() > 0) {
        return nearby?.allowed == false || !_current(epoch) ? null : file;
      }
      if ((_failedUntil[url]?.isAfter(DateTime.now()) ?? false) ||
          !_current(epoch) ||
          nearby?.allowed == false) {
        return null;
      }
      await _waitUntilActive(epoch);
      if (!_current(epoch) || nearby?.allowed == false) return null;
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
        await _waitUntilActive(epoch);
        if (!_current(epoch) || nearby?.allowed == false) return null;
        // One pool reuses HTTP/TLS connections across covers. Cancellation
        // belongs to each request, never to other downloads sharing the pool.
        final client = _client ??= createClient()
          ..connectionTimeout = timeout
          ..idleTimeout = const Duration(seconds: 15)
          ..maxConnectionsPerHost = 4;
        Future<File?> work() async {
          final opened = request = await client.getUrl(uri);
          if (!_current(epoch) || expired) {
            opened.abort();
            return null;
          }
          opened.maxRedirects = 3;
          final response = await opened.close();
          final reader = chunks = StreamIterator(response);
          if (!_current(epoch) || expired) return null;
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
          if (!_current(epoch) || expired) return null;
          await directory.create(recursive: true);
          if (!_current(epoch) || expired) return null;
          final temporary = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
          );
          try {
            await temporary.writeAsBytes(data, flush: true);
            if (!_current(epoch) || expired) return null;
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

        // A timeout can finish load() while native decode or file I/O is still
        // settling. Clearing waits for that underlying work before deleting.
        return await _track(work()).timeout(
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
          _active--;
          _dispatchWaiting();
        }
      }
    } catch (_) {
      // Rebuilds or several cards for the same offline host must not retry
      // indefinitely. A later visit may try again without losing other covers.
      if (_current(epoch)) _failed(url);
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
    if (_closed) return Future.value();
    final clearing = _clearing;
    if (clearing != null) return clearing;
    // A mounted image can report an old decode failure after a full clear.
    // That handle must never remove a file or impose backoff in the new cache.
    final failedEpoch = failedFile == null
        ? null
        : _posterFileEpochs[failedFile];
    if (failedEpoch != null && !identical(failedEpoch, _epoch)) {
      return Future.value();
    }
    final invalidating = _invalidating[url];
    if (invalidating != null) return invalidating;
    // Another visible card may already have replaced this failed file. Do not
    // delete its successful repair when an older Image reports its error late.
    final current = _resolved[url] ?? _retained[url]?.file.target;
    if (failedFile != null &&
        current != null &&
        !identical(current, failedFile)) {
      return Future.value();
    }
    if (failedFile != null && current == null && _pending.containsKey(url)) {
      return _pending[url]!.then<void>((_) {});
    }
    _forget(url);
    if (retryImmediately) {
      _failedUntil.remove(url);
    } else {
      _failed(url);
    }
    late final Future<void> result;
    result = _delete(url).whenComplete(() {
      if (identical(_invalidating[url], result)) _invalidating.remove(url);
    });
    _invalidating[url] = result;
    _track(result);
    _changes.value = PosterCacheChange(url, null);
    return result;
  }

  Future<void> _delete(String url) async {
    try {
      await _file(url).delete();
    } on FileSystemException {
      // Already removed or unavailable.
    }
  }

  Future<T> _track<T>(Future<T> work) {
    late final Future<void> settled;
    settled = work
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _work.remove(settled));
    _work.add(settled);
    return work;
  }

  /// Remove all cached artwork without replacing this shared cache instance.
  /// New admissions are deferred until [capacity] and [changes] announce the
  /// completed clear. The foreground/background state remains unchanged.
  Future<void> clear() {
    final clearing = _clearing;
    if (clearing != null) return clearing;
    if (_closed) return Future.value();
    final completed = Completer<void>();
    _clearing = completed.future;
    _epoch = _PosterEpoch();
    final resume = _resume;
    if (resume != null) {
      // Wake old waiters so they can observe the new epoch, while keeping all
      // subsequent requests suspended until the real lifecycle resumes.
      _resume = Completer<void>();
      resume.complete();
    }
    _client?.close(force: true);
    _client = null;
    for (final waiting in _waiting) {
      waiting.ready.complete(false);
    }
    _waiting.clear();
    _resolved.clear();
    _retained.clear();
    _failedUntil.clear();
    _priority.clear();
    _nearby.clear();
    unawaited(_clear(completed));
    return completed.future;
  }

  Future<void> _clear(Completer<void> completed) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      // Also wait for old restore/invalidate calls and for download work whose
      // timeout returned before its native image validation or rename settled.
      while (_work.isNotEmpty) {
        await Future.wait(_work.toList(growable: false));
      }
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      _clearing = null;
      if (!_closed) {
        _changes.value = PosterCacheChange.cleared();
        _capacity.value++;
      }
    }
    if (failure == null) {
      completed.complete();
    } else {
      completed.completeError(failure, failureStack);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _resume?.complete();
    _resume = null;
    _resolved.clear();
    _retained.clear();
    _failedUntil.clear();
    _priority.clear();
    _nearby.clear();
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

class _PosterEpoch {}

class _PosterNearbyRequest {
  bool Function() canStart;
  bool promoted = false;

  _PosterNearbyRequest(this.canStart);

  bool get allowed => promoted || canStart();
}

class _PosterFileHandle {
  final WeakReference<PosterCache> cache;
  final String url;
  final WeakReference<File> file;

  _PosterFileHandle(PosterCache cache, this.url, File file)
    : cache = WeakReference(cache),
      file = WeakReference(file);
}

class _PosterWaiter {
  final String url;
  final ready = Completer<bool>();

  _PosterWaiter(this.url);
}
