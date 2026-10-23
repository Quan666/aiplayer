import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Persistent, device-local artwork. A URL is downloaded once and shared by
/// library cards, folders and details, including after restarting the app.
class PosterCache {
  final Directory directory;
  // Kept for source compatibility; successful artwork is never size-evicted.
  final int maxBytes, maxFileBytes;
  final Duration timeout;
  final HttpClient Function() createClient;
  final _pending = <String, Future<File?>>{};
  final _resolved = <String, File>{};
  final _failedUntil = <String, DateTime>{};
  HttpClient? _client;
  final _waiting = <Completer<void>>[];
  int _active = 0;
  bool _closed = false;

  PosterCache({
    required this.directory,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxFileBytes = 12 * 1024 * 1024,
    this.timeout = const Duration(seconds: 15),
    HttpClient Function()? createClient,
  }) : createClient = createClient ?? HttpClient.new;

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
    await directory.create(recursive: true);
    final temporary = File('${file.path}.sync-part');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    _failedUntil.remove(url);
    _remember(url, file);
  }

  Future<File?> load(String url) {
    if (_closed || url.isEmpty) return Future.value();
    final cached = resolvedFile(url);
    if (cached != null) return SynchronousFuture(cached);
    return _pending.putIfAbsent(
      url,
      () => _load(url)
          .then((file) {
            if (file != null && !_closed) _remember(url, file);
            return file;
          })
          .whenComplete(() {
            _pending.remove(url);
          }),
    );
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
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
      if ((_failedUntil[url]?.isAfter(DateTime.now()) ?? false) || _closed) {
        return null;
      }
      if (_active >= 4) {
        final waiting = Completer<void>();
        _waiting.add(waiting);
        await waiting.future;
      } else {
        _active++;
      }
      if (_closed) return null;
      HttpClientRequest? request;
      StreamIterator<List<int>>? chunks;
      var expired = false;
      try {
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
            _waiting.removeAt(0).complete();
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
      codec = await descriptor.instantiateCodec(targetWidth: 32);
      image = (await codec.getNextFrame()).image;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> invalidate(String url) async {
    _resolved.remove(url);
    _failed(url);
    try {
      await _file(url).delete();
    } on FileSystemException {
      // Already removed or unavailable.
    }
  }

  void close() {
    _closed = true;
    _resolved.clear();
    _failedUntil.clear();
    _client?.close(force: true);
    _client = null;
    for (final waiting in _waiting) {
      waiting.complete();
    }
    _waiting.clear();
  }
}
