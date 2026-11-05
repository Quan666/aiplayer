import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as images;
import 'package:path/path.dart' as p;

import '../core/network.dart';
import '../core/system_proxy.dart';
import '../sources/configuration.dart';
import '../sources/media_kind.dart';
import '../sources/source.dart';
import '../ui/artwork_lifecycle.dart';
import 'album_catalog.dart' show AlbumFileMetadata;
import 'album_image_cache.dart';
import 'album_view_settings.dart';

/// A disk image prepared by the worker; never carries full-resolution pixels.
class AlbumImageResult {
  final String? path, error;
  final int width, height, metadataVersion;
  final bool previewOnly, deferred, cancelled, metadataIncomplete;

  /// Compressed source bytes shared by every display size. The UI still uses
  /// its bounded native decode queue; this never contains decoded pixels.
  final bool encodedSource;

  /// A previous encoded path may still have a correctly sized decoded frame.
  /// Consumers may reuse those pixels, but must never reload this optional path.
  final String? decodedFallbackPath;
  final AlbumFileMetadata? metadata;
  final String? sourcePath, captureTimeRaw;
  final int? orientation, captureOffsetMinutes;
  final Map<String, String> exif;

  /// A shallow folder listing can nominate one video without opening a
  /// decoder. Its screenshot is requested by the visible artwork component.
  final SourceEntry? singleVideo;
  const AlbumImageResult({
    this.path,
    this.error,
    this.width = 0,
    this.height = 0,
    this.metadataVersion = 3,
    this.previewOnly = false,
    this.deferred = false,
    this.cancelled = false,
    this.metadataIncomplete = false,
    this.encodedSource = false,
    this.decodedFallbackPath,
    this.metadata,
    this.sourcePath,
    this.orientation,
    this.captureTimeRaw,
    this.captureOffsetMinutes,
    this.exif = const {},
    this.singleVideo,
  });

  AlbumImageResult withSingleVideo(SourceEntry? video) => AlbumImageResult(
    path: path,
    error: error,
    width: width,
    height: height,
    metadataVersion: metadataVersion,
    previewOnly: previewOnly,
    deferred: deferred,
    cancelled: cancelled,
    metadataIncomplete: metadataIncomplete,
    encodedSource: encodedSource,
    decodedFallbackPath: decodedFallbackPath,
    metadata: metadata,
    sourcePath: sourcePath,
    orientation: orientation,
    captureTimeRaw: captureTimeRaw,
    captureOffsetMinutes: captureOffsetMinutes,
    exif: exif,
    singleVideo: video,
  );

  int? get capturedAt => metadata?.capturedAt;
  int? get sourceWidth => metadata?.width;
  int? get sourceHeight => metadata?.height;
}

class AlbumImageHandle {
  final Future<AlbumImageResult> future;
  final VoidCallback cancel;
  final ValueChanged<int>? updatePriority;
  const AlbumImageHandle(this.future, this.cancel, {this.updatePriority});
}

/// One persistent worker overlaps bounded source reads and owns hashing/cache
/// publication. Optional JPEG derivatives use a separate reusable isolate, so
/// conversion cannot delay visible source reads. Each lane owns its connection
/// and cancellation, including during pause.
class AlbumImageService extends ChangeNotifier {
  // Services own their source connections, but wall, viewer and source browser
  // share the same disk cache. Publish invalidations to those live owners once
  // per batch; no filesystem checks or per-cell polling run on the UI isolate.
  static final _cacheServices = <String, Set<AlbumImageService>>{};
  static final _ownerSession = DateTime.now().microsecondsSinceEpoch;
  static final _ownerRevisions = <String, int>{};
  static int _nextOwner = 0;
  String _cacheOwner = '$pid:$_ownerSession:${++_nextOwner}';
  final String cacheDirectory, sourceId;
  final String? documentsPath;
  final Map<String, dynamic> source;
  final String password;
  final int maxInputBytes, maxDecodePixels, maxCacheFiles, maxThumbnailFiles;
  int maxCacheBytes, maxThumbnailBytes, maxMetadataBytes;
  final bool preferOriginal;
  final bool observeLifecycle;
  final int maxConcurrentRequests;
  static const maxPending = 64;
  final _jobs = <String, _AlbumImageJob>{};
  final _queue = <_AlbumImageJob>[];
  final _resolved = <String, AlbumImageResult>{};
  final _resolvedEdges = <String, int>{};
  final _warm = <(String, int, int), AlbumImageResult>{};
  final _facts = <(String, int, int), AlbumImageResult>{};
  final _evicted = <String>{};
  final _repairs = <(String, int, int), String>{};
  final _pathFailures = <String, int>{};
  final _capacity = ValueNotifier<int>(0);
  final _pendingTouches = <String>{};
  List<SourceEntry>? _originalWindow;
  bool _maintenanceHeld = false;
  bool _windowMessageScheduled = false;

  bool _touchScheduled = false;
  int _derivativePendingCount = 0;
  int _derivativeActiveCount = 0;
  Isolate? _isolate;
  ReceivePort? _replies, _errors, _exit;
  SendPort? _commands;
  Completer<void>? _starting;
  final _current = <int, _AlbumImageJob>{};
  bool _enabled = true, _scrolling = false, _closed = false;
  int _nextId = 0, _revision = 0, _repairEpoch = 0;

  AlbumImageService({
    required this.cacheDirectory,
    required this.sourceId,
    this.documentsPath,
    required Map<String, dynamic> source,
    this.password = '',
    this.maxInputBytes = 64 * 1024 * 1024,
    this.maxDecodePixels = 32 * 1024 * 1024,
    this.maxCacheBytes = 1024 * 1024 * 1024,
    this.maxCacheFiles = 8192,
    this.maxThumbnailBytes = 512 * 1024 * 1024,
    this.maxMetadataBytes = 16 * 1024 * 1024,
    this.maxThumbnailFiles = 100000,
    this.preferOriginal = false,
    this.observeLifecycle = true,
    int maxConcurrentRequests = 3,
  }) : maxConcurrentRequests = maxConcurrentRequests.clamp(1, 3),
       source = Map.unmodifiable(source) {
    _cacheServices.putIfAbsent(p.normalize(cacheDirectory), () => {}).add(this);
    _membershipChanged(p.normalize(cacheDirectory));
    if (observeLifecycle) {
      ArtworkLifecycle.instance.addListener(_lifecycleChanged);
    }
  }

  static void _membershipChanged(String directory) {
    _ownerRevisions[directory] = (_ownerRevisions[directory] ?? 0) + 1;
    for (final service
        in _cacheServices[directory] ?? const <AlbumImageService>{}) {
      service._sendOwnerSnapshot();
    }
  }

  void _sendOwnerSnapshot() {
    if (_closed || _commands == null) return;
    final key = p.normalize(cacheDirectory);
    _commands!.send([
      'owners',
      _ownerSession,
      _ownerRevisions[key] ?? 0,
      [
        for (final service
            in _cacheServices[key] ?? const <AlbumImageService>{})
          service._cacheOwner,
      ],
    ]);
  }

  bool get active =>
      !_closed &&
      _enabled &&
      (!observeLifecycle || ArtworkLifecycle.instance.value);
  void updateCacheLimits({
    required int thumbnailBytes,
    required int originalBytes,
    int? metadataBytes,
  }) {
    if (_closed) return;
    final thumbnails = math.max(1, thumbnailBytes);
    final originals = math.max(1, originalBytes);
    final metadata = math.max(1, metadataBytes ?? maxMetadataBytes);
    if (maxThumbnailBytes == thumbnails &&
        maxCacheBytes == originals &&
        maxMetadataBytes == metadata) {
      return;
    }
    maxThumbnailBytes = thumbnails;
    maxCacheBytes = originals;
    maxMetadataBytes = metadata;
    _updateDiskLimits();
  }

  void setMaintenanceHeld(bool held) {
    if (_closed || _maintenanceHeld == held) return;
    _maintenanceHeld = held;
    _commands?.send(['holdMaintenance', held]);
  }

  @visibleForTesting
  bool get maintenanceHeld => _maintenanceHeld;

  /// Priority order is current, forward/backward near pages, then far pages.
  /// This publishes identities only; source reads remain explicit load jobs.
  void setOriginalWindow(List<SourceEntry> entries) {
    if (_closed) return;
    final unique = <(String, int, int)>{};
    final next = <SourceEntry>[];
    for (final entry in entries) {
      if (entry.directory ||
          !unique.add((entry.path, entry.size, entry.modified))) {
        continue;
      }
      next.add(entry);
      if (next.length == 9) break;
    }
    final previous = _originalWindow;
    if (previous != null &&
        previous.length == next.length &&
        List.generate(
          next.length,
          (i) =>
              (next[i].path, next[i].size, next[i].modified) ==
              (previous[i].path, previous[i].size, previous[i].modified),
        ).every((same) => same)) {
      return;
    }
    _originalWindow = List.unmodifiable(next);
    _sendOriginalWindow();
  }

  List<String> get originalWindowPaths => List.unmodifiable(
    (_originalWindow ?? const <SourceEntry>[]).map((entry) => entry.path),
  );

  void _sendOriginalWindow({bool immediately = false}) {
    if (_closed || !active || _commands == null || _originalWindow == null) {
      return;
    }
    if (immediately) {
      _windowMessageScheduled = false;
      _commands!.send(['window', _originalWindow]);
      return;
    }
    if (_windowMessageScheduled) return;
    _windowMessageScheduled = true;
    scheduleMicrotask(() {
      if (!_windowMessageScheduled) return;
      _windowMessageScheduled = false;
      if (_closed || !active || _commands == null || _originalWindow == null) {
        return;
      }
      _commands!.send(['window', _originalWindow]);
    });
  }

  void _updateDiskLimits() {
    if (!active || _scrolling || _commands == null) return;
    final limits = (maxThumbnailBytes, maxCacheBytes);
    // A resume also revives an interrupted bounded maintenance batch.
    _commands!.send(['holdMaintenance', _maintenanceHeld]);
    _sendOriginalWindow(immediately: true);
    _commands!.send(['limits', limits.$1, limits.$2, maxMetadataBytes]);
  }

  int get pendingCount => _jobs.length;
  int get activeCount => _current.length;

  /// Disk thumbnail preparation is optional idle work, separate from the first
  /// paint/source queue. Observing it never drives a widget rebuild or a timer.
  int get derivativePendingCount => _derivativePendingCount;
  int get derivativeActiveCount => _derivativeActiveCount;

  /// A ready thumbnail can paint immediately while the viewer loads its larger
  /// version. Identity includes the listing revision; callers never get pixels.
  AlbumImageResult? peek(SourceEntry entry) {
    final result = _warm[(entry.path, entry.size, entry.modified)];
    _touch(result);
    return result;
  }

  /// Reuses a completed demand before a recycled wall cell's first frame.
  /// Folder/filter identities must match exactly; a generic file peek would
  /// otherwise expose a cover hidden by the current folder filters.
  AlbumImageResult? peekPrepared(
    SourceEntry entry, {
    int targetEdge = 512,
    bool folder = false,
    Set<String> extensions = const {},
    Set<String> excludedExtensions = const {},
    bool hideHidden = true,
    SourceEntry? cover,
  }) {
    final result =
        _resolved[_imageKey(
          entry,
          targetEdge: targetEdge,
          folder: folder,
          extensions: extensions,
          excludedExtensions: excludedExtensions,
          hideHidden: hideHidden,
          metadataOnly: false,
          cover: cover,
        )];
    _touch(result);
    return result;
  }

  void _touch(AlbumImageResult? result) {
    final path = result?.path;
    if (_closed || path == null || _evicted.contains(path)) return;
    _pendingTouches.remove(path);
    _pendingTouches.add(path);
    if (_pendingTouches.length > 128) {
      _pendingTouches.remove(_pendingTouches.first);
    }
    _scheduleTouches();
  }

  void _scheduleTouches() {
    if (_touchScheduled ||
        !active ||
        _scrolling ||
        _commands == null ||
        _pendingTouches.isEmpty) {
      return;
    }
    _touchScheduled = true;
    // Only coalesce the small path message here. The cache worker performs
    // bounded access bookkeeping; scheduling a microtask is not background IO.
    scheduleMicrotask(() {
      _touchScheduled = false;
      if (!active || _scrolling || _commands == null) return;
      if (_pendingTouches.isEmpty) return;
      final paths = _pendingTouches.toList(growable: false);
      _pendingTouches.clear();
      _commands!.send(['touch', paths]);
    });
  }

  void _cacheEvicted(List<String> paths) {
    final removed = paths.toSet();
    final owners = _cacheServices[p.normalize(cacheDirectory)];
    if (owners == null) return;
    for (final owner in owners.toList(growable: false)) {
      if (owner._closed) continue;
      // One bounded sweep and one notification regardless of victim count.
      owner._resolved.removeWhere((key, value) {
        final forget = removed.contains(value.path);
        if (forget) owner._resolvedEdges.remove(key);
        return forget;
      });
      owner._warm.removeWhere((_, value) => removed.contains(value.path));
      owner._pendingTouches.removeWhere(removed.contains);
      owner._evicted.addAll(removed);
      // An in-flight worker lookup can finish after another owner evicted the
      // path. Reuse the bounded repair epoch to recheck that late result rather
      // than publishing it over this newer invalidation.
      final epoch = ++owner._repairEpoch;
      for (final path in removed) {
        owner._pathFailures.remove(path);
        owner._pathFailures[path] = epoch;
      }
      while (owner._pathFailures.length > 1024) {
        owner._pathFailures.remove(owner._pathFailures.keys.first);
      }
      while (owner._evicted.length > 1024) {
        owner._evicted.remove(owner._evicted.first);
      }
      owner._available();
    }
  }

  String _imageKey(
    SourceEntry entry, {
    required int targetEdge,
    required bool folder,
    required Set<String> extensions,
    required Set<String> excludedExtensions,
    required bool hideHidden,
    required bool metadataOnly,
    required SourceEntry? cover,
  }) {
    final include = extensions.map(_extension).toList()..sort();
    final exclude = excludedExtensions.map(_extension).toList()..sort();
    return jsonEncode([
      entry.path,
      entry.size,
      entry.modified,
      ((targetEdge.clamp(64, 4096) + 63) ~/ 64) * 64,
      folder || entry.directory,
      include,
      exclude,
      hideHidden,
      _revision,
      metadataOnly,
      cover?.path,
      cover?.size,
      cover?.modified,
    ]);
  }

  int get revision => _revision;
  bool wasEvicted(String path) => _evicted.contains(path);
  ValueListenable<int> get capacity => _capacity;

  void _available() {
    if (!active) return;
    _capacity.value++;
    notifyListeners();
  }

  void setActive(bool value) {
    if (_enabled == value || _closed) return;
    _enabled = value;
    _lifecycleChanged();
    if (!active) notifyListeners();
  }

  void setScrolling(bool value) {
    if (_scrolling == value || _closed) return;
    _scrolling = value;
    if (value) {
      _commands?.send(['pauseCache']);
      for (final job in _jobs.values) {
        job.cacheMiss = false;
      }
      _pauseCurrent(imagesOnly: true);
      _dispatch();
    } else {
      _updateDiskLimits();
      _scheduleTouches();
      _dispatch();
      _available();
    }
  }

  void _lifecycleChanged() {
    if (_closed) return;
    if (!active) {
      _commands?.send(['pauseCache']);
      _pauseCurrent();
      for (final job in _queue.where((job) => job.listing).toList()) {
        _cancelJob(job);
      }
    } else {
      _updateDiskLimits();
      _scheduleTouches();
      _dispatch();
      _available();
    }
  }

  void _pauseCurrent({bool imagesOnly = false}) {
    for (final job in _current.values) {
      if (imagesOnly && (job.listing || job.cacheOnly)) continue;
      job.interrupted = true;
      _commands?.send(['cancel', job.id]);
    }
  }

  /// Explicit refresh invalidates failed lookups and shallow folder covers.
  /// File cache identity still includes the actual file size and modification.
  void invalidate() {
    if (_closed) return;
    _commands?.send(['resetDerivatives']);
    _revision++;
    _pendingTouches.clear();
    _resolved.clear();
    _resolvedEdges.clear();
    _warm.clear();
    _facts.clear();
    _repairs.clear();
    _pathFailures.clear();
    for (final job in _jobs.values.toList(growable: false)) {
      _cancelJob(job);
    }
    _available();
  }

  /// Forget only the failed demand and disk path. The worker replaces that
  /// file atomically on the next visible/idle request; no filesystem work or
  /// whole-album revision change is needed on the UI isolate.
  void invalidatePrepared(
    SourceEntry entry, {
    String? failedPath,
    int targetEdge = 512,
    bool folder = false,
    Set<String> extensions = const {},
    Set<String> excludedExtensions = const {},
    bool hideHidden = true,
    SourceEntry? cover,
  }) {
    if (_closed) return;
    final key = _imageKey(
      entry,
      targetEdge: targetEdge,
      folder: folder,
      extensions: extensions,
      excludedExtensions: excludedExtensions,
      hideHidden: hideHidden,
      metadataOnly: false,
      cover: cover,
    );
    _resolved.remove(key);
    _resolvedEdges.remove(key);
    _warm.remove((entry.path, entry.size, entry.modified));
    if (failedPath == null) return;
    _forgetPreparedPath(failedPath, failed: true);
    _repairs[(entry.path, entry.size, entry.modified)] = failedPath;
    if (_repairs.length > 512) _repairs.remove(_repairs.keys.first);
    final pending = _jobs[key];
    if (pending != null) _cancelJob(pending);
  }

  void _forgetPreparedPath(String path, {bool failed = false}) {
    _pendingTouches.remove(path);
    _resolved.removeWhere((key, result) {
      final forget = result.path == path;
      if (forget) _resolvedEdges.remove(key);
      return forget;
    });
    _warm.removeWhere((_, result) => result.path == path);
    _evicted.add(path);
    if (_evicted.length > 1024) _evicted.remove(_evicted.first);
    if (failed) {
      _pathFailures[path] = ++_repairEpoch;
      if (_pathFailures.length > 1024) {
        _pathFailures.remove(_pathFailures.keys.first);
      }
    }
  }

  AlbumImageHandle load(
    SourceEntry entry, {
    int targetEdge = 512,
    bool folder = false,
    Set<String> extensions = const {},
    Set<String> excludedExtensions = const {},
    bool hideHidden = true,
    bool metadataOnly = false,
    SourceEntry? cover,
    int priority = 0,
  }) {
    priority = priority.clamp(0, 2);
    if (!_closed && !folder && !entry.directory && !metadataOnly) {
      final original = _warm[(entry.path, entry.size, entry.modified)];
      if (original?.encodedSource == true) {
        _touch(original);
        return AlbumImageHandle(SynchronousFuture(original!), () {});
      }
    }
    if (metadataOnly && !entry.directory) {
      final cached = _facts[(entry.path, entry.size, entry.modified)];
      if (cached != null) {
        return AlbumImageHandle(SynchronousFuture(cached), () {});
      }
    }
    // Small layout/DPR changes share a disk thumbnail instead of decoding the
    // original again for every one-pixel difference in a responsive grid.
    final edge = ((targetEdge.clamp(64, 4096) + 63) ~/ 64) * 64;
    final key = _imageKey(
      entry,
      targetEdge: targetEdge,
      folder: folder,
      extensions: extensions,
      excludedExtensions: excludedExtensions,
      hideHidden: hideHidden,
      metadataOnly: metadataOnly,
      cover: cover,
    );
    final cached = _resolved.remove(key);
    if (cached != null) {
      _resolved[key] = cached;
      _touch(cached);
      return AlbumImageHandle(SynchronousFuture(cached), () {});
    }
    if (_closed) {
      return AlbumImageHandle(
        SynchronousFuture(const AlbumImageResult(cancelled: true)),
        () {},
      );
    }
    var job = _jobs[key];
    if (job == null) {
      if (_jobs.length >= maxPending) {
        final displaced = _queue
            .where((job) => !job.listing && job.priority > priority)
            .lastOrNull;
        if (displaced == null) {
          return AlbumImageHandle(
            SynchronousFuture(const AlbumImageResult(deferred: true)),
            () {},
          );
        }
        _cancelJob(displaced);
      }
      final include = extensions.map(_extension).toList()..sort();
      final exclude = excludedExtensions.map(_extension).toList()..sort();
      job = _AlbumImageJob(
        ++_nextId,
        key,
        [
          'image',
          entry,
          edge,
          folder || entry.directory,
          include,
          exclude,
          hideHidden,
          _revision,
          metadataOnly,
          cover,
          metadataOnly
              ? null
              : _repairs[(entry.path, entry.size, entry.modified)],
        ],
        priority: priority,
        repairEpoch: _repairEpoch,
      );
      _jobs[key] = job;
      _queue.add(job);
    }
    final consumer = Completer<AlbumImageResult>();
    job.consumers.add(consumer);
    final subscription = job;
    if (priority < job.priority) job.priority = priority;
    _dispatch();
    return AlbumImageHandle(
      consumer.future,
      () {
        if (consumer.isCompleted) return;
        subscription.consumers.remove(consumer);
        consumer.complete(const AlbumImageResult(cancelled: true));
        if (subscription.consumers.isEmpty) _cancelJob(subscription);
      },
      updatePriority: (value) {
        if (consumer.isCompleted ||
            value < 0 ||
            value >= subscription.priority) {
          return;
        }
        subscription.priority = value;
        _dispatch();
      },
    );
  }

  /// Explicit metadata indexing uses the same bounded, cancellable worker.
  /// It reads headers/EXIF without allocating image pixels or generating JPEG.
  AlbumImageHandle loadMetadata(SourceEntry entry) =>
      load(entry, targetEdge: 64, metadataOnly: true, priority: 2);

  Future<List<SourceEntry>> listDirectory(
    String path, {
    CancelToken? cancel,
    int maxEntries = 20000,
  }) {
    if (_closed || !active || cancel?.cancelled == true) {
      return Future.error(const Cancelled());
    }
    if (_jobs.length >= maxPending) {
      return Future.error(const AppFailure('相册任务繁忙，请稍后重试。'));
    }
    final id = ++_nextId;
    final job = _AlbumImageJob(id, 'listing:$id', [
      'list',
      path,
      maxEntries.clamp(1, 50000),
    ], listing: true);
    _jobs[job.key] = job;
    _queue.insert(0, job);
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (!job.result.isCompleted) _cancelJob(job);
        }),
      );
    }
    _dispatch();
    return job.result.future.then((value) => value as List<SourceEntry>);
  }

  void _cancelJob(_AlbumImageJob job) {
    if (!_jobs.containsKey(job.key)) return;
    _jobs.remove(job.key);
    _queue.remove(job);
    job.cancelled = true;
    if (_current[job.id] == job) _commands?.send(['cancel', job.id]);
    _finish(job, const AlbumImageResult(cancelled: true));
  }

  void _finish(_AlbumImageJob job, Object value) {
    if (job.listing) {
      if (!job.result.isCompleted) {
        if (value is List<SourceEntry>) {
          job.result.complete(value);
        } else {
          final result = value as AlbumImageResult;
          job.result.completeError(
            result.cancelled
                ? const Cancelled()
                : AppFailure(result.error ?? '读取相册失败。'),
          );
        }
      }
    } else {
      for (final consumer in job.consumers) {
        if (!consumer.isCompleted) consumer.complete(value as AlbumImageResult);
      }
      job.consumers.clear();
    }
  }

  Future<void> _start() async {
    if (_commands != null) return;
    if (_starting != null) return _starting!.future;
    final ready = _starting = Completer<void>();
    _replies = ReceivePort();
    _errors = ReceivePort();
    _exit = ReceivePort();
    _replies!.listen((message) {
      if (message is SendPort) {
        _commands = message;
        _sendOwnerSnapshot();
        _updateDiskLimits();
        _scheduleTouches();
        if (!ready.isCompleted) ready.complete();
        return;
      }
      final response = message as List<dynamic>;
      if (response[0] == 'derivativePending') {
        if (!_closed) {
          _derivativePendingCount = response[1] as int;
          _derivativeActiveCount = response.length > 2 ? response[2] as int : 0;
        }
        return;
      }
      if (response[0] == 'derived') {
        if (_closed || preferOriginal) return;
        final original = response[1] as String;
        final result = response[2] as AlbumImageResult;
        final edge = response[3] as int;
        if (result.path == null) return;
        if (_evicted.contains(result.path)) {
          // Do not let a late publication erase a peer's newer eviction. Drop
          // only prepared pointers, silently: mounted cells keep their image,
          // and a future request validates the regenerated small file in the worker.
          _resolved.removeWhere((key, previous) {
            final matches =
                previous.path == original &&
                (_resolvedEdges[key] ?? 4097) <= edge;
            if (matches) _resolvedEdges.remove(key);
            return matches;
          });
          _warm.removeWhere((_, previous) => previous.path == original);
          return;
        }
        _resolved.updateAll(
          (key, previous) =>
              previous.path == original && (_resolvedEdges[key] ?? 4097) <= edge
              ? result
              : previous,
        );
        _warm.updateAll(
          (_, previous) => previous.path == original ? result : previous,
        );
        // Mounted cells already own their frame. New/recycled cells reuse the
        // durable small path without replacing the original underneath them.
        return;
      }
      if (response[0] == 'evicted') {
        final paths = response[1];
        _cacheEvicted(
          paths is String ? [paths] : List<String>.from(paths as List),
        );
        return;
      }
      final job = _current.remove(response[0]);
      if (job == null) return;
      if (!job.cancelled && job.interrupted) {
        job.interrupted = false;
        if (job.listing) {
          _jobs.remove(job.key);
          _finish(job, const AlbumImageResult(cancelled: true));
        } else {
          _queue.insert(0, job);
        }
      } else if (!job.cancelled) {
        final value = response[1] as Object;
        if (value is AlbumImageResult &&
            value.path != null &&
            job.repairEpoch < (_pathFailures[value.path] ?? 0)) {
          // A different-size consumer may have resolved the bad path just
          // before its native failure was reported. Do not republish that late
          // result over the targeted invalidation or a newer repaired result.
          job.arguments[10] = value.path;
          job.repairEpoch = _repairEpoch;
          _queue.add(job);
        } else if (job.cacheOnly &&
            value is AlbumImageResult &&
            value.deferred) {
          // Remember this miss for the gesture. Keep the same bounded demand
          // for idle recovery without rechecking disk on every scroll event.
          job.cacheMiss = true;
          _queue.add(job);
        } else {
          _jobs.remove(job.key);
          if (value is AlbumImageResult &&
              !value.cancelled &&
              !value.deferred &&
              !value.metadataIncomplete) {
            if (value.path != null) _evicted.remove(value.path);
            if (value.path != null && job.arguments[10] != null) {
              final entry = job.arguments[1] as SourceEntry;
              final identity = (entry.path, entry.size, entry.modified);
              if (_repairs[identity] == job.arguments[10]) {
                _repairs.remove(identity);
              }
            }
            _resolved[job.key] = value;
            _resolvedEdges[job.key] = job.arguments[2] as int;
            if (value.metadata != null &&
                value.metadataVersion >= 3 &&
                job.arguments[1] is SourceEntry) {
              final entry = job.arguments[1] as SourceEntry;
              _facts[(
                entry.path,
                entry.size,
                entry.modified,
              )] = AlbumImageResult(
                sourcePath: value.sourcePath,
                metadata: value.metadata,
                orientation: value.orientation,
                captureTimeRaw: value.captureTimeRaw,
                captureOffsetMinutes: value.captureOffsetMinutes,
                exif: value.exif,
              );
              if (_facts.length > 512) _facts.remove(_facts.keys.first);
            }
            if (value.path != null && job.arguments[1] is SourceEntry) {
              final entry = job.arguments[1] as SourceEntry;
              final identity = (entry.path, entry.size, entry.modified);
              final previous = _warm[identity];
              if (previous == null || value.width >= previous.width) {
                _warm.remove(identity);
                _warm[identity] = value;
              }
              if (_warm.length > 512) _warm.remove(_warm.keys.first);
            }
            if (_resolved.length > 512) {
              final oldest = _resolved.keys.first;
              _resolved.remove(oldest);
              _resolvedEdges.remove(oldest);
            }
          }
          _finish(job, value);
        }
      }
      if (!_closed) {
        _dispatch();
        _available();
      }
    });
    void stopped() {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      if (!ready.isCompleted) ready.completeError(const Cancelled());
      for (final job in _jobs.values.toList(growable: false)) {
        _finish(job, const AlbumImageResult(error: '相册后台任务已停止。'));
      }
      _jobs.clear();
      _queue.clear();
      _current.clear();
      _derivativePendingCount = _derivativeActiveCount = 0;
      _commands = null;
      if (!_closed) {
        _cacheOwner = '$pid:$_ownerSession:${++_nextOwner}';
        _membershipChanged(p.normalize(cacheDirectory));
      }
      _starting = null;
      _replies?.close();
      _errors?.close();
      _exit?.close();
    }

    _errors!.listen((_) => stopped());
    _exit!.listen((_) => stopped());
    try {
      final isolate = await Isolate.spawn(
        _albumImagesMain,
        [
          _replies!.sendPort,
          cacheDirectory,
          sourceId,
          source,
          password,
          maxInputBytes,
          maxDecodePixels,
          SystemProxyWorkerConfiguration.capture(),
          documentsPath,
          maxCacheBytes,
          maxCacheFiles,
          maxThumbnailBytes,
          maxThumbnailFiles,
          preferOriginal,
          maxMetadataBytes,
          _cacheOwner,
        ],
        onError: _errors!.sendPort,
        onExit: _exit!.sendPort,
      );
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        stopped();
      } else {
        _isolate = isolate;
      }
    } catch (_) {
      stopped();
    }
    return ready.future;
  }

  void _dispatch() {
    if (!active || _current.length >= maxConcurrentRequests || _queue.isEmpty) {
      return;
    }
    var index = -1;
    for (var i = 0; i < _queue.length; i++) {
      final job = _queue[i];
      if (_scrolling && !job.listing && job.cacheMiss) continue;
      if (index < 0 || job.listing || job.priority < _queue[index].priority) {
        index = i;
      }
      if (job.listing) break;
    }
    if (index < 0) return;
    final job = _queue.removeAt(index);
    _current[job.id] = job;
    unawaited(() async {
      try {
        await _start();
        if (_closed) return;
        if (job.cancelled || !active) {
          _current.remove(job.id);
          if (!job.cancelled) {
            job.interrupted = false;
            _queue.insert(0, job);
          }
          _dispatch();
          return;
        }
        job.cacheOnly = _scrolling && !job.listing;
        _commands!.send(['run', job.id, job.arguments, job.cacheOnly]);
        _dispatch();
      } catch (_) {
        _current.remove(job.id);
        _jobs.remove(job.key);
        _finish(job, const AlbumImageResult(error: '无法启动相册后台任务。'));
      }
    }());
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    final identity = p.normalize(cacheDirectory);
    final owners = _cacheServices[identity];
    owners?.remove(this);
    if (owners?.isEmpty == true) _cacheServices.remove(identity);
    _membershipChanged(identity);
    _pendingTouches.clear();
    notifyListeners();
    if (observeLifecycle) {
      ArtworkLifecycle.instance.removeListener(_lifecycleChanged);
    }
    for (final job in _jobs.values.toList(growable: false)) {
      _cancelJob(job);
    }
    // Give the worker a chance to close its independently owned SMB connection.
    _commands?.send(['close']);
    _resolved.clear();
    _resolvedEdges.clear();
    _derivativePendingCount = 0;
    _derivativeActiveCount = 0;
    _warm.clear();
    _facts.clear();
    _evicted.clear();
    _repairs.clear();
    _pathFailures.clear();
    _capacity.dispose();
    super.dispose();
  }
}

class _AlbumImageJob {
  final int id;
  final String key;
  final List<dynamic> arguments;
  final bool listing;
  final consumers = <Completer<AlbumImageResult>>{};
  final result = Completer<Object>();
  bool interrupted = false, cancelled = false;
  bool cacheOnly = false, cacheMiss = false;
  int priority;
  int repairEpoch;
  _AlbumImageJob(
    this.id,
    this.key,
    this.arguments, {
    this.listing = false,
    this.priority = 0,
    this.repairEpoch = 0,
  });
}

String _extension(String value) =>
    value.startsWith('.') ? value.toLowerCase() : '.${value.toLowerCase()}';

void _albumImagesMain(List<dynamic> startup) {
  initializeSystemProxyWorker(startup[7] as SystemProxyWorkerConfiguration);
  final worker = _AlbumImageWorker(
    startup[0] as SendPort,
    startup[1] as String,
    startup[2] as String,
    Map<String, dynamic>.from(startup[3] as Map),
    startup[4] as String,
    startup[5] as int,
    startup[6] as int,
    startup[8] as String?,
    startup[9] as int,
    startup[10] as int,
    startup[11] as int,
    startup[12] as int,
    startup[13] as bool,
    startup[14] as int,
    startup[15] as String,
  );
  worker.listen();
}

class _AlbumSourceLane {
  SourceAdapter? source;
  CancelToken? cancel;
  int? id;
}

class _AlbumImageWorker {
  final SendPort replies;
  final String cacheDirectory, sourceId, password;
  final String? documentsPath;
  final Map<String, dynamic> configuration;
  final int maxInputBytes, maxDecodePixels, maxCacheBytes, maxCacheFiles;
  final int maxThumbnailBytes, maxThumbnailFiles, maxMetadataBytes;
  final bool preferOriginal;
  final String ownerId;
  List<SourceEntry> _originalWindow = const [];
  final _preparedOriginals = <(String, int, int), String>{};
  // At most one queued/running transaction plus the latest snapshot for each
  // of three roles. A busy peer must not accumulate one Future per swipe.
  final _pendingPinUpdates = <String, Future<void> Function()>{};
  final _pinWaiters = <(int, Completer<void>)>[];
  int _pinRevision = 0, _appliedPinRevision = 0;
  bool _pinUpdatesRunning = false;
  final commands = ReceivePort();
  final _lanes = List.generate(3, (_) => _AlbumSourceLane());
  bool _closed = false, _closingWorker = false;
  bool _maintenancePending = false, _maintenanceRunning = false;
  bool _cacheActive = true, _maintenanceHeld = false;
  int _maintenanceRevision = 0;
  CancelToken _maintenanceCancel = CancelToken();
  CancelToken _cacheTouchCancel = CancelToken();
  final _pendingCacheTouches = <String>{};
  bool _cacheTouchRunning = false;
  final _derivatives = <String, _AlbumDerivativeTask>{};
  Timer? _derivativeDelay;
  Isolate? _derivativeIsolate;
  ReceivePort? _derivativeReplies;
  SendPort? _derivativeCommands;
  Completer<SendPort>? _derivativeReady;
  Completer<List<dynamic>>? _derivativeResult;
  bool _derivativeRunning = false;
  bool _derivativeImmediatePending = false;
  String? _activeDerivativePath;
  CancelToken? _derivativePublicationCancel;
  int _derivativeEpoch = 0, _derivativeSerial = 0;

  final int _session = DateTime.now().microsecondsSinceEpoch;
  late final List<Object?> _sourceCacheIdentity = () {
    final value = sourceFormValues(configuration);
    // Source IDs survive configuration edits. Keep server/share/account changes
    // out of another source's cache, while a display-label edit stays reusable.
    return [
      for (final key in [
        'kind',
        'url',
        'host',
        'port',
        'share',
        'domain',
        'user',
        'smbSecurity',
      ])
        value[key],
    ];
  }();
  _AlbumImageWorker(
    this.replies,
    this.cacheDirectory,
    this.sourceId,
    this.configuration,
    this.password,
    this.maxInputBytes,
    this.maxDecodePixels,
    this.documentsPath,
    this.maxCacheBytes,
    this.maxCacheFiles,
    this.maxThumbnailBytes,
    this.maxThumbnailFiles,
    this.preferOriginal,
    this.maxMetadataBytes,
    this.ownerId,
  );

  late final _disk = AlbumImageDiskCache(
    directory: cacheDirectory,
    ownerId: ownerId,
    adaptiveOriginals: true,
    originalBytes: maxCacheBytes,
    originalFiles: maxCacheFiles,
    thumbnailBytes: maxThumbnailBytes,
    thumbnailFiles: maxThumbnailFiles,
    metadataBytes: maxMetadataBytes,
    publish: (file, bytes, cancel) =>
        publishAlbumCacheFile(file, bytes, cancel),
    onEvicted: (paths) => replies.send(['evicted', paths]),
  );

  void listen() {
    replies.send(commands.sendPort);
    commands.listen((message) {
      final command = message as List<dynamic>;
      switch (command[0]) {
        case 'owners':
          final session = command[1] as int, revision = command[2] as int;
          final owners = (command[3] as List).cast<String>();
          _queuePinUpdate(
            'owners',
            () => _disk.updateOwners(session, revision, owners, CancelToken()),
          );
        case 'window':
          _originalWindow = List<SourceEntry>.from(command[1] as List);
          _maintenanceCancel.cancel();
          _syncWindow();
        case 'holdMaintenance':
          _maintenanceHeld = command[1] as bool;
          if (_maintenanceHeld) {
            _maintenanceCancel.cancel();
            _cancelDerivative();
          } else {
            _scheduleMaintenance();
            _scheduleDerivative();
          }
        case 'limits':
          _cacheActive = true;
          _maintenanceRevision++;
          _maintenanceCancel.cancel();
          if (_cacheTouchCancel.cancelled) _cacheTouchCancel = CancelToken();
          _disk.updateLimits(
            command[1] as int,
            command[2] as int,
            metadata: command.length > 3 ? command[3] as int : null,
          );
          _maintenancePending = true;
          _scheduleMaintenance();
          _scheduleDerivative();
        case 'resetDerivatives':
          _cancelDerivative();
          _derivatives.clear();
          _syncDerivativePins();
          _reportDerivatives();
        case 'pauseCache':
          _cacheActive = false;
          _cancelDerivative();
          _maintenanceRevision++;
          _maintenanceCancel.cancel();
          _cacheTouchCancel.cancel();
          _pendingCacheTouches.clear();
        case 'touch':
          final paths = (command[1] as List).cast<String>();
          if (!_closed) _touchDisk(paths);
        case 'run':
          unawaited(
            _run(
              command[1] as int,
              command[2] as List<dynamic>,
              cacheOnly: command[3] as bool,
            ),
          );
        case 'cancel':
          for (final lane in _lanes) {
            if (lane.id != command[1]) continue;
            lane.cancel?.cancel();
            unawaited(_closeSource(lane));
          }
        case 'close':
          _closed = true;
          _cancelDerivative();
          _derivatives.clear();
          _maintenanceCancel.cancel();
          _cacheTouchCancel.cancel();
          _pendingCacheTouches.clear();
          for (final lane in _lanes) {
            lane.cancel?.cancel();
          }
          unawaited(
            Future.wait(_lanes.map(_closeSource)).whenComplete(() {
              if (_lanes.every((lane) => lane.id == null)) _closeWorker();
            }),
          );
      }
    });
  }

  void _closeWorker() {
    if (_closingWorker) return;
    _closingWorker = true;
    unawaited(
      _diskWork.whenComplete(() async {
        await _disk.close();
        commands.close();
      }),
    );
  }

  void _touchDisk(List<String> paths) {
    if (_closed || !_cacheActive || _cacheTouchCancel.cancelled) return;
    for (final path in paths) {
      _pendingCacheTouches.remove(path);
      _pendingCacheTouches.add(path);
      if (_pendingCacheTouches.length > 128) {
        _pendingCacheTouches.remove(_pendingCacheTouches.first);
      }
    }
    _flushCacheTouches();
  }

  void _flushCacheTouches() {
    if (_closed ||
        !_cacheActive ||
        _cacheTouchRunning ||
        _cacheTouchCancel.cancelled ||
        _pendingCacheTouches.isEmpty) {
      return;
    }
    _cacheTouchRunning = true;
    final cancel = _cacheTouchCancel;
    final paths = _pendingCacheTouches.toList(growable: false);
    _pendingCacheTouches.clear();
    // Keep one queued/running batch and one bounded latest batch. A busy peer
    // cannot turn repeated warm hits into an unbounded chain before new images.
    // Appending the next batch only after this one settles also yields to any
    // visible publication already waiting on the serialized disk writer.
    unawaited(
      _publish(() => _disk.touch(paths, cancel))
          .catchError((Object _) {})
          .whenComplete(() {
            _cacheTouchRunning = false;
            _flushCacheTouches();
          }),
    );
  }

  void _scheduleMaintenance() {
    if (_closed ||
        !_cacheActive ||
        _maintenanceHeld ||
        _pinUpdatesRunning ||
        _pendingPinUpdates.isNotEmpty ||
        !_maintenancePending ||
        _maintenanceRunning ||
        _lanes.any((lane) => lane.id != null)) {
      return;
    }
    _maintenanceRunning = true;
    final revision = _maintenanceRevision;
    final cancel = _maintenanceCancel = CancelToken();
    unawaited(
      _publish(() async {
        try {
          while (!_closed &&
              _cacheActive &&
              !_maintenanceHeld &&
              revision == _maintenanceRevision &&
              !cancel.cancelled &&
              _lanes.every((lane) => lane.id == null)) {
            final more = await _disk.maintain(cancel);
            if (!more) {
              if (!cancel.cancelled && revision == _maintenanceRevision) {
                _maintenancePending = false;
              }
              break;
            }
            await Future<void>.delayed(Duration.zero);
          }
        } on Cancelled {
          // Resume retries an interrupted batch; no polling while hidden.
        } catch (_) {
          // A failed optional cleanup never prevents loading a visible photo.
        } finally {
          _maintenanceRunning = false;
          if (_cacheActive && !_closed && cancel.cancelled) {
            _scheduleMaintenance();
          }
        }
      }),
    );
  }

  Future<void> _closeSource(_AlbumSourceLane lane) async {
    final value = lane.source;
    lane.source = null;
    try {
      await value?.close();
    } catch (_) {}
  }

  Future<SourceAdapter> _open(_AlbumSourceLane lane, CancelToken cancel) async {
    cancel.check();
    if (lane.source != null) return lane.source!;
    final value = configuration['kind'] == 'local'
        ? LocalSource()
        : await connectSource(
            configuration,
            password: password,
            maxListingBytes: 8 * 1024 * 1024,
            maxListingEntries: 20000,
          );
    if (cancel.cancelled || _closed) {
      await value.close();
      throw const Cancelled();
    }
    return lane.source = value;
  }

  Future<void> _run(
    int id,
    List<dynamic> args, {
    required bool cacheOnly,
  }) async {
    final lane = _lanes.where((lane) => lane.id == null).firstOrNull;
    if (_closed || lane == null) {
      replies.send([id, const AlbumImageResult(cancelled: true)]);
      return;
    }
    _maintenanceCancel.cancel();
    if (cacheOnly) _cacheActive = false;
    _cancelDerivative(keepIdleWorker: true);
    final cancel = lane.cancel = CancelToken();
    lane.id = id;
    var timedOut = false;
    final deadline = Timer(const Duration(seconds: 35), () {
      timedOut = true;
      cancel.cancel();
      unawaited(_closeSource(lane));
    });
    try {
      Object result;
      if (args[0] == 'list') {
        result = await _list(lane, args[1] as String, args[2] as int, cancel);
      } else {
        final entry = args[1] as SourceEntry;
        final edge = args[2] as int;
        final folder = args[3] as bool;
        if (cacheOnly &&
            (folder ||
                args[8] == true ||
                (args[7] as int) > 0 ||
                args[10] != null)) {
          // Resolving folder covers and refreshing revisions may stat/list a
          // remote source. Those jobs must remain idle-only on a cache miss.
          result = const AlbumImageResult(deferred: true);
        } else if (folder) {
          var image = const AlbumImageResult();
          final candidates = await _folderCandidates(lane, entry, args, cancel);
          for (final candidate in candidates.images.take(3)) {
            try {
              image = await _image(
                lane,
                candidate,
                edge,
                cancel,
                revision: args[7] as int,
                metadataOnly: false,
                failedPath: args[10] as String?,
              );
              break;
            } on Cancelled {
              rethrow;
            } on AppFailure catch (error) {
              image = AlbumImageResult(error: error.message);
            }
          }
          result = image.withSingleVideo(candidates.singleVideo);
        } else {
          result = await _image(
            lane,
            entry,
            edge,
            cancel,
            revision: args[7] as int,
            metadataOnly: args[8] as bool,
            cacheOnly: cacheOnly,
            failedPath: args[10] as String?,
          );
        }
      }
      // Receive cancellation queued while the pure Dart decoder was running.
      await Future<void>.delayed(Duration.zero);
      cancel.check();
      // Window/derivative protection must be published before releasing this
      // read's temporary pin. Wait outside the serialized writer to avoid a
      // dependency cycle, and before replying so its lane is not reused early.
      await _waitForPinUpdates();
      cancel.check();
      replies.send([id, result]);
    } catch (error) {
      await _waitForPinUpdates();
      replies.send([
        id,
        AlbumImageResult(
          cancelled: !timedOut && (error is Cancelled || cancel.cancelled),
          error: timedOut
              ? '读取图片超时，请重试。'
              : error is AppFailure && error is! Cancelled
              ? error.message
              : cancel.cancelled
              ? null
              : '无法读取此图片或相册。',
        ),
      ]);
    } finally {
      deadline.cancel();
      unawaited(
        _publish(() => _disk.releaseOriginals('read:$id'))
            .catchError((Object _) {}),
      );
      _maintenancePending = true;
      lane.cancel = null;
      lane.id = null;
      if (!_closed) {
        _scheduleMaintenance();
        _scheduleDerivative();
      }
      if (_closed) {
        await _closeSource(lane);
        if (_lanes.every((lane) => lane.id == null)) _closeWorker();
      }
    }
  }

  Future<({List<SourceEntry> images, SourceEntry? singleVideo})>
  _folderCandidates(
    _AlbumSourceLane lane,
    SourceEntry folder,
    List<dynamic> args,
    CancelToken cancel,
  ) async {
    final includes = (args[4] as List).cast<String>().toSet();
    final excludes = (args[5] as List).cast<String>().toSet();
    bool allowed(SourceEntry item) {
      final ext = mediaExtension(item.name);
      return !item.directory &&
          (!(args[6] as bool) ||
              (!item.hidden && !item.name.startsWith('.'))) &&
          (includes.isEmpty || includes.contains(ext)) &&
          !excludes.contains(ext);
    }

    SourceEntry? cover = args[9] as SourceEntry?;
    if (documentsPath != null) {
      try {
        final settings = File(
          albumSettingsPath(documentsPath!, sourceId, folder.path),
        );
        if (await settings.exists() && await settings.length() <= 64 * 1024) {
          final json = jsonDecode(await settings.readAsString());
          // Hiding a folder cover also disables automatic photo/video
          // fallbacks, before opening or inspecting the media source.
          if (json is Map && json['hideCover'] == true) {
            return (images: <SourceEntry>[], singleVideo: null);
          }
          final value = json is Map ? json['cover'] : null;
          if (cover == null &&
              value is Map &&
              value['path'] is String &&
              value['name'] is String) {
            cover = SourceEntry(
              name: value['name'] as String,
              path: value['path'] as String,
            );
          }
        }
      } catch (_) {
        /* Malformed local display preferences use automatic cover. */
      }
    }
    final candidates = <SourceEntry>[];
    if (cover != null && isImageFile(cover.name) && allowed(cover)) {
      try {
        final source = await _open(lane, cancel);
        final current = await source.stat(cover.path);
        cancel.check();
        if (isImageFile(current.name) && allowed(current)) {
          candidates.add(current);
        }
      } on Cancelled {
        rethrow;
      } catch (_) {
        /* Deleted covers use a fallback. */
      }
    }
    final entries = await _list(lane, folder.path, 2000, cancel);
    SourceEntry? singleVideo;
    var videos = 0;
    for (final entry in entries) {
      if (mediaKindOf(entry.name) == MediaKind.video && allowed(entry)) {
        singleVideo = ++videos == 1 ? entry : null;
      }
    }
    final automatic =
        entries
            .where((entry) => isImageFile(entry.name) && allowed(entry))
            .toList()
          ..sort((a, b) {
            int priority(SourceEntry value) => switch (mediaExtension(
              value.name,
            )) {
              '.jpg' || '.jpeg' => 0,
              '.png' || '.webp' || '.gif' || '.bmp' || '.tif' || '.tiff' => 1,
              _ => isRawImageFile(value.name) ? 2 : 3,
            };
            final order = priority(a).compareTo(priority(b));
            return order == 0 ? a.name.compareTo(b.name) : order;
          });
    return (
      images: candidates.isEmpty ? automatic : candidates,
      singleVideo: videos == 1 ? singleVideo : null,
    );
  }

  Future<List<SourceEntry>> _list(
    _AlbumSourceLane lane,
    String path,
    int maxEntries,
    CancelToken cancel,
  ) async {
    final source = await _open(lane, cancel);
    if (source is LocalSource) {
      final entries = <SourceEntry>[];
      await for (final file in Directory(path).list(followLinks: false)) {
        cancel.check();
        if (file is Link) continue;
        try {
          entries.add(await source.stat(file.path));
        } on FileSystemException {
          continue;
        }
        if (entries.length > maxEntries) {
          throw AppFailure('此目录超过 $maxEntries 项，请选择更小的文件夹。');
        }
      }
      return entries;
    }
    final entries = source is HttpSource
        ? await source.listWithLimits(
            path,
            maxBytes: maxEntries <= 2000 ? 1024 * 1024 : 8 * 1024 * 1024,
            maxEntries: maxEntries,
          )
        : await source.list(path);
    cancel.check();
    if (entries.length > maxEntries) {
      throw AppFailure('此目录超过 $maxEntries 项，请选择更小的文件夹。');
    }
    return entries;
  }

  Future<Uint8List> _read(
    _AlbumSourceLane lane,
    SourceEntry entry,
    CancelToken cancel, {
    bool allowPrefix = false,
    int? byteLimit,
  }) async {
    final source = await _open(lane, cancel);
    final actual = entry.size > 0 ? entry : await source.stat(entry.path);
    cancel.check();
    if (actual.size <= 0 || (!allowPrefix && actual.size > maxInputBytes)) {
      throw const AppFailure('图片文件超出当前读取预算。');
    }
    final bytes = BytesBuilder(copy: false);
    final stream = source
        .read(
          entry.path,
          0,
          math.min(actual.size, byteLimit ?? maxInputBytes) - 1,
        )
        .timeout(const Duration(seconds: 20));
    await for (final chunk in stream) {
      cancel.check();
      if (bytes.length + chunk.length > maxInputBytes) {
        throw const AppFailure('图片文件超出当前读取预算。');
      }
      bytes.add(chunk);
    }
    cancel.check();
    return bytes.takeBytes();
  }

  Future<AlbumImageResult> _image(
    _AlbumSourceLane lane,
    SourceEntry entry,
    int edge,
    CancelToken cancel, {
    required int revision,
    required bool metadataOnly,
    bool cacheOnly = false,
    String? failedPath,
  }) async {
    final requestedEntry = entry;
    if (revision > 0 || entry.size <= 0 || failedPath != null) {
      // Explicit retries can outlive their directory snapshot. Refresh both
      // the byte range and cache identity after a file is repaired/replaced.
      final source = await _open(lane, cancel);
      entry = await source.stat(entry.path);
      cancel.check();
    }
    if (!preferOriginal) {
      edge = edge <= 512
          ? 512
          : edge <= 1024
          ? 1024
          : edge <= 2048
          ? 2048
          : 4096;
    }
    final ext = p.extension(entry.name).toLowerCase();
    final raw = rawFileExtensions.contains(ext);
    final cacheKey = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              raw
                  ? 4
                  : 3, // Only RAW previews need orientation cache migration.
              sourceId,
              _sourceCacheIdentity,
              entry.path,
              entry.size,
              entry.modified,
              edge,
              if (entry.modified <= 0) [_session, revision],
            ]),
          ),
        )
        .toString();
    final factsKey = _factsKey(entry, revision);
    final originals = Directory(p.join(cacheDirectory, 'album-images-v2'));
    final thumbnails = Directory(p.join(cacheDirectory, 'album-thumbnails-v1'));
    final original = File(p.join(originals.path, '$factsKey-original-v1.jpg'));
    final originalSidecar = File('${original.path}.json');
    final sharedFacts = File(
      p.join(cacheDirectory, 'album-metadata-v3', '$factsKey.json'),
    );
    Future<_AlbumImageFacts?> readFacts(File sidecar) async {
      try {
        if (await sidecar.exists() && await sidecar.length() <= 64 * 1024) {
          return _AlbumImageFacts.fromJson(
            jsonDecode(await sidecar.readAsString()),
          );
        }
      } catch (_) {
        // Missing, corrupt and half-written old cache pairs are repaired lazily.
      }
      return null;
    }

    if (metadataOnly) {
      final facts = await readFacts(sharedFacts);
      if (facts != null && facts.version >= 3) {
        return facts.result(sourcePath: entry.path, previewOnly: raw);
      }
    }
    final file = File(
      p.join(
        preferOriginal ? originals.path : thumbnails.path,
        '$cacheKey.jpg',
      ),
    );
    final sidecar = File('${file.path}.json');
    if (!metadataOnly) {
      await _pinRead(
        lane,
        [original.path, if (preferOriginal) file.path],
        cancel,
        priority: _originalPriority(requestedEntry),
      );
    }

    // A grid only reads its durable small tier; a long detail session cannot
    // substitute or delete these paths. Legacy full JPEGs remain usable below.
    if (failedPath != file.path && (metadataOnly || await file.exists())) {
      final facts = await readFacts(sidecar);
      if (facts != null && (!metadataOnly || facts.version >= 3)) {
        if (!cacheOnly) _touchDisk([file.path]);
        if (preferOriginal && !metadataOnly) {
          _rememberOriginal(requestedEntry, file.path);
        }
        return facts.result(
          path: metadataOnly ? null : file.path,
          sourcePath: entry.path,
          previewOnly: raw,
          decodedFallbackPath:
              !preferOriginal &&
                  !metadataOnly &&
                  !raw &&
                  failedPath != original.path
              ? original.path
              : null,
        );
      }
    }
    _AlbumImageFacts? originalFacts;
    if (!raw && failedPath != original.path && await original.exists()) {
      originalFacts = await readFacts(originalSidecar);
      if (originalFacts != null &&
          (!metadataOnly || originalFacts.version >= 3)) {
        if (!metadataOnly) _rememberOriginal(requestedEntry, original.path);
        if (!preferOriginal && !metadataOnly) {
          await _queueDerivative(
            _AlbumDerivativeTask(
              original: original,
              file: file,
              sidecar: sidecar,
              sharedFacts: sharedFacts,
              facts: originalFacts,
              sourcePath: entry.path,
              edge: edge,
            ),
            cancel,
          );
        }
        if (!cacheOnly) {
          _touchDisk([original.path]);
        }
        return originalFacts.result(
          path: metadataOnly ? null : original.path,
          sourcePath: entry.path,
          previewOnly: false,
          encodedSource: !metadataOnly,
        );
      }
    }
    if (cacheOnly) return const AlbumImageResult(deferred: true);
    if (metadataOnly) {
      final prefix = await _read(
        lane,
        entry,
        cancel,
        allowPrefix: true,
        byteLimit: math.min(maxInputBytes, raw ? 256 * 1024 : 128 * 1024),
      );
      cancel.check();
      final facts = _albumHeaderFacts(
        prefix,
        maxPixels: maxDecodePixels,
        raw: raw,
      );
      final complete =
          prefix.length >= entry.size || _completeJpegHeader(prefix);
      if (complete || facts.capturedAt != null) {
        final json = utf8.encode(jsonEncode(facts.toJson()));
        await _publish(
          () => _disk.write('metadata', {sharedFacts: json}, cancel),
        );
      }
      return facts.result(
        sourcePath: entry.path,
        previewOnly: raw,
        metadataIncomplete: !complete && facts.capturedAt == null,
      );
    }
    final incomingPriority = _originalPriority(requestedEntry);
    if (preferOriginal &&
        incomingPriority > 0 &&
        incomingPriority < 400 &&
        !await _disk.canAdmitOriginal(
          entry.size + 4096,
          incomingPriority,
          cancel,
        )) {
      return const AlbumImageResult(deferred: true);
    }
    Uint8List? fromDisk;
    if (originalFacts != null) {
      try {
        if (await original.length() <= maxInputBytes) {
          fromDisk = await original.readAsBytes();
          _touchDisk([original.path]);
        }
      } on FileSystemException {
        // A different worker may evict this bounded original before the read.
      }
    }
    var data = fromDisk ?? await _read(lane, entry, cancel, allowPrefix: raw);
    cancel.check();
    int? rawOrientation;
    if (raw) {
      final embedded = extractAlbumRawJpeg(data, maxPixels: maxDecodePixels);
      if (embedded == null) {
        throw const AppFailure('此 RAW 没有可读取的 JPEG 预览；尚未提供完整 RAW 解码。');
      }
      rawOrientation = readAlbumRawOrientation(
        data,
        previewOffset: embedded.offsetInBytes - data.offsetInBytes,
      );
      data = embedded;
    }
    final facts = _albumImageFacts(
      data,
      raw: raw,
      maxPixels: maxDecodePixels,
      fallbackOrientation: rawOrientation,
    );
    final jpeg =
        !raw &&
        data.length > 2 &&
        data[0] == 0xff &&
        data[1] == 0xd8 &&
        facts.sourceWidth != null &&
        facts.sourceHeight != null &&
        _jpegEnd(data, 0) != null;
    if (jpeg && data.length < _disk.originalBytes) {
      final saved = facts.withThumbnail(
        facts.sourceWidth!,
        facts.sourceHeight!,
      );
      final metadataBytes = utf8.encode(jsonEncode(saved.toJson()));
      if (data.length + metadataBytes.length <= _disk.originalBytes) {
        var originalStored = fromDisk != null;
        if (fromDisk == null) {
          await _publish(() async {
            originalStored = await _disk.write(
              'original',
              {original: data, originalSidecar: metadataBytes},
              cancel,
              admissionPriority: incomingPriority,
            );
          });
        }
        if (!originalStored && preferOriginal) {
          // Another viewer can reserve a higher-priority frame after the
          // preflight. Do not let a converted fallback evade that decision.
          return const AlbumImageResult(deferred: true);
        }
        final needsDerivative =
            !preferOriginal &&
            (data.length > 512 * 1024 ||
                math.max(facts.sourceWidth!, facts.sourceHeight!) > edge);
        if (originalStored && (preferOriginal || needsDerivative)) {
          _rememberOriginal(requestedEntry, original.path);
          if (needsDerivative) {
            await _queueDerivative(
              _AlbumDerivativeTask(
                original: original,
                file: file,
                sidecar: sidecar,
                sharedFacts: sharedFacts,
                facts: saved,
                sourcePath: entry.path,
                edge: edge,
              ),
              cancel,
            );
          }
          // Full-screen JPEG remains a compressed-byte/native-decode fast path.
          // It never waits for a Dart thumbnail conversion or speculative work.
          await _publish(
            () => _disk.write('metadata', {sharedFacts: metadataBytes}, cancel),
          );
          return saved.result(
            path: original.path,
            sourcePath: entry.path,
            previewOnly: false,
            encodedSource: true,
          );
        }
      }
    }
    // A genuinely small JPEG needs no extra decode or lossy recompression.
    final smallJpeg =
        jpeg &&
        data.length <= 512 * 1024 &&
        math.max(facts.sourceWidth!, facts.sourceHeight!) <= edge;
    final decoded = smallJpeg
        ? null
        : decodeAlbumImage(
            data,
            edge: edge,
            maxPixels: maxDecodePixels,
            fallbackOrientation: rawOrientation,
          );
    if (!smallJpeg && decoded == null) {
      throw const AppFailure('当前解码器不支持此图片，或图片超过像素预算。');
    }
    await Future<void>.delayed(Duration.zero);
    cancel.check();
    final encoded = smallJpeg ? data : images.encodeJpg(decoded!, quality: 90);
    final saved = facts.withThumbnail(
      smallJpeg ? facts.sourceWidth! : decoded!.width,
      smallJpeg ? facts.sourceHeight! : decoded!.height,
    );
    final metadataBytes = utf8.encode(jsonEncode(saved.toJson()));
    var stored = false;
    await _publish(() async {
      stored = await _disk.write(
        preferOriginal ? 'original' : 'thumbnail',
        {file: encoded, sidecar: metadataBytes},
        cancel,
        admissionPriority: preferOriginal ? incomingPriority : null,
      );
      if (stored) {
        await _disk.write('metadata', {sharedFacts: metadataBytes}, cancel);
      }
    });
    if (!stored) return const AlbumImageResult(deferred: true);
    if (preferOriginal) _rememberOriginal(requestedEntry, file.path);
    return saved.result(
      path: file.path,
      sourcePath: entry.path,
      previewOnly: raw,
      encodedSource: smallJpeg,
    );
  }

  String _originalPath(SourceEntry entry, [int revision = 0]) {
    final key = _factsKey(entry, revision);
    return p.join(cacheDirectory, 'album-images-v2', '$key-original-v1.jpg');
  }

  String _factsKey(SourceEntry entry, int revision) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            3,
            sourceId,
            _sourceCacheIdentity,
            entry.path,
            entry.size,
            entry.modified,
            if (entry.modified <= 0) [_session, revision],
          ]),
        ),
      )
      .toString();

  void _syncWindow() {
    final paths = <String, int>{};
    for (var index = 0; index < _originalWindow.length; index++) {
      final entry = _originalWindow[index];
      final path =
          _preparedOriginals[(entry.path, entry.size, entry.modified)] ??
          _originalPath(entry);
      paths[path] = index == 0 ? 400 : 100 - index;
    }
    _queuePinUpdate(
      'window',
      () => _disk.pinOriginals('window', paths, CancelToken()),
    );
  }

  void _rememberOriginal(SourceEntry entry, String path) {
    final key = (entry.path, entry.size, entry.modified);
    if (_preparedOriginals[key] == path) return;
    _preparedOriginals.remove(key);
    _preparedOriginals[key] = path;
    while (_preparedOriginals.length > 128) {
      _preparedOriginals.remove(_preparedOriginals.keys.first);
    }
    if (_originalWindow.any(
      (value) => (value.path, value.size, value.modified) == key,
    )) {
      _syncWindow();
    }
  }

  int _originalPriority(SourceEntry entry) {
    final index = _originalWindow.indexWhere(
      (value) =>
          (value.path, value.size, value.modified) ==
          (entry.path, entry.size, entry.modified),
    );
    return index < 0
        ? 0
        : index == 0
        ? 400
        : 100 - index;
  }

  Future<void> _pinRead(
    _AlbumSourceLane lane,
    List<String> paths,
    CancelToken cancel, {
    int priority = 0,
  }) async {
    try {
      await _publish(
        () => _disk.pinOriginals('read:${lane.id}', {
          for (final path in paths) path: priority,
        }, cancel),
      );
    } on Cancelled {
      rethrow;
    } catch (_) {
      // A damaged optional index must not hide a valid prepared image. A cold
      // publication still requires its normal transactional accounting.
    }
  }

  void _syncDerivativePins() {
    final paths = <String, int>{
      for (final task in _derivatives.values) task.original.path: 50,
    };
    _queuePinUpdate(
      'derivative',
      () => _disk.pinOriginals('derivative', paths, CancelToken()),
    );
  }

  void _queuePinUpdate(String role, Future<void> Function() commit) {
    if (_closed) return;
    _pendingPinUpdates[role] = commit;
    _pinRevision++;
    _flushPinUpdates();
  }

  void _flushPinUpdates() {
    if (_pinUpdatesRunning || _closed || _pendingPinUpdates.isEmpty) return;
    _pinUpdatesRunning = true;
    unawaited(
      _publish(() async {
        // Read the latest snapshots when this writer slot actually starts.
        final revision = _pinRevision;
        final updates = _pendingPinUpdates.values.toList(growable: false);
        _pendingPinUpdates.clear();
        if (!_closed) {
          for (final update in updates) {
            try {
              await update();
            } catch (_) {
              // Optional cache bookkeeping must not strand a source lane.
              // The next snapshot/read retries owner registration in its txn.
            }
          }
        }
        _appliedPinRevision = revision;
        _completePinWaiters();
      }).whenComplete(() {
        _pinUpdatesRunning = false;
        if (_closed) {
          _pendingPinUpdates.clear();
          _completePinWaiters();
          return;
        }
        if (_pendingPinUpdates.isNotEmpty) {
          _flushPinUpdates();
        } else {
          _maintenancePending = true;
          _scheduleMaintenance();
          _scheduleDerivative();
        }
      }),
    );
  }

  Future<void> _waitForPinUpdates() {
    if (_closed || _appliedPinRevision >= _pinRevision) {
      return Future.value();
    }
    final ready = Completer<void>();
    // Only the three source lanes wait; UI window updates never add waiters.
    _pinWaiters.add((_pinRevision, ready));
    return ready.future;
  }

  void _completePinWaiters() {
    _pinWaiters.removeWhere((waiter) {
      if (!_closed && waiter.$1 > _appliedPinRevision) return false;
      waiter.$2.complete();
      return true;
    });
  }

  void _reportDerivatives() => replies.send([
    'derivativePending',
    _derivatives.length,
    _derivativeRunning ? 1 : 0,
  ]);

  Future<void> _queueDerivative(
    _AlbumDerivativeTask task,
    CancelToken cancel,
  ) async {
    if (_closed || preferOriginal) return;
    try {
      await _publish(
        () => _disk.retainOriginalUntilThumbnail(task.original.path, cancel),
      );
    } on Cancelled {
      rethrow;
    } catch (_) {
      // A broken disposable ledger must not hide an already prepared image.
      // Normal publication still requires successful disk accounting.
    }
    cancel.check();
    if (_closed) return;
    _derivatives.remove(task.file.path);
    _derivatives[task.file.path] = task;
    // One viewport and nearby pages, never an album-sized background backlog.
    while (_derivatives.length > 32) {
      final oldest = _derivatives.keys.firstWhere(
        (path) => path != _activeDerivativePath,
      );
      _derivatives.remove(oldest);
    }
    _syncDerivativePins();
    _reportDerivatives();
    _scheduleDerivative();
  }

  void _scheduleDerivative({bool immediate = false}) {
    _derivativeImmediatePending |= immediate;
    if (_closed ||
        !_cacheActive ||
        _maintenanceHeld ||
        _pinUpdatesRunning ||
        _pendingPinUpdates.isNotEmpty ||
        _derivativeRunning ||
        _derivatives.isEmpty ||
        _lanes.any((lane) => lane.id != null)) {
      return;
    }
    _derivativeDelay?.cancel();
    final startImmediately = _derivativeImmediatePending;
    _derivativeImmediatePending = false;
    // A single worker-owned idle delay protects the next visible decode batch.
    // New source work cancels this; no timers exist when the queue is empty.
    _derivativeDelay = Timer(
      startImmediately ? Duration.zero : const Duration(milliseconds: 500),
      () {
        _derivativeDelay = null;
        if (!_closed &&
            _cacheActive &&
            !_maintenanceHeld &&
            _lanes.every((lane) => lane.id == null)) {
          unawaited(_deriveNext());
        }
      },
    );
  }

  void _cancelDerivative({bool keepIdleWorker = false}) {
    _derivativeImmediatePending = false;
    _derivativeDelay?.cancel();
    _derivativeDelay = null;
    if (keepIdleWorker && !_derivativeRunning) return;
    _derivativeEpoch++;
    _derivativePublicationCancel?.cancel();
    _derivativeIsolate?.kill(priority: Isolate.immediate);
    _derivativeIsolate = null;
    _derivativeCommands = null;
    _derivativeReplies?.close();
    _derivativeReplies = null;
    final ready = _derivativeReady;
    _derivativeReady = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(const Cancelled());
    }
    final result = _derivativeResult;
    _derivativeResult = null;
    if (result != null && !result.isCompleted) {
      result.completeError(const Cancelled());
    }
  }

  Future<SendPort> _startDerivative(int epoch) async {
    if (_derivativeCommands case final port?) return port;
    final ready = _derivativeReady = Completer<SendPort>();
    // Cancellation can arrive during Isolate.spawn, before its caller reaches
    // ready.future; keep that expected error observed in both intervals.
    ready.future.ignore();
    final messages = _derivativeReplies = ReceivePort();
    messages.listen((message) {
      if (message is SendPort) {
        _derivativeCommands = message;
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is List &&
          message.length == 4 &&
          message[0] == _derivativeSerial) {
        final result = _derivativeResult;
        if (result != null && !result.isCompleted) {
          result.complete(List<dynamic>.from(message));
        }
      } else if (message == null || message is List && message.length == 2) {
        const failure = AppFailure('图片缩略图任务已停止。');
        final result = _derivativeResult;
        if (result != null && !result.isCompleted) {
          result.completeError(failure);
        }
        if (!ready.isCompleted) ready.completeError(failure);
        _derivativeIsolate?.kill(priority: Isolate.immediate);
        _derivativeIsolate = null;
        _derivativeCommands = null;
        messages.close();
      }
    });
    Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _albumDerivativeMain,
        messages.sendPort,
        onError: messages.sendPort,
        onExit: messages.sendPort,
      );
    } catch (_) {
      messages.close();
      _derivativeCommands = null;
      rethrow;
    }
    if (_closed || !_cacheActive || epoch != _derivativeEpoch) {
      isolate.kill(priority: Isolate.immediate);
      throw const Cancelled();
    }
    _derivativeIsolate = isolate;
    return ready.future;
  }

  Future<void> _deriveNext() async {
    if (_derivativeRunning ||
        _derivatives.isEmpty ||
        !_cacheActive ||
        _closed) {
      return;
    }
    _derivativeRunning = true;
    _reportDerivatives();
    final epoch = _derivativeEpoch;
    final task = _derivatives.values.first;
    _activeDerivativePath = task.file.path;
    final cancel = _derivativePublicationCancel = CancelToken();
    var completed = false;
    bool current() => !_closed && _cacheActive && epoch == _derivativeEpoch;
    try {
      final port = await _startDerivative(epoch);
      if (!current()) throw const Cancelled();
      final result = _derivativeResult = Completer<List<dynamic>>();
      final serial = ++_derivativeSerial;
      port.send([
        serial,
        task.original.path,
        task.edge,
        maxDecodePixels,
        maxInputBytes,
      ]);
      final output = await result.future;
      if (!current()) throw const Cancelled();
      final bytes = output[1] as Uint8List?;
      if (bytes == null) {
        _derivatives.remove(task.file.path);
        completed = true;
        return;
      }
      final saved = task.facts.withThumbnail(
        output[2] as int,
        output[3] as int,
      );
      final metadata = utf8.encode(jsonEncode(saved.toJson()));
      await _publish(() async {
        if (!current()) throw const Cancelled();
        // Publication is tiny and serialized with source writes. A new visible
        // request revokes the result before it can replace a newer identity.
        await _disk.write(
          'thumbnail',
          {task.file: bytes, task.sidecar: metadata},
          cancel,
          releasesOriginalFallback: task.original.path,
        );
      });
      if (!current()) throw const Cancelled();
      if (identical(_derivatives[task.file.path], task)) {
        _derivatives.remove(task.file.path);
      }
      completed = true;
      replies.send([
        'derived',
        task.original.path,
        saved.result(
          path: task.file.path,
          sourcePath: task.sourcePath,
          previewOnly: false,
          decodedFallbackPath: task.original.path,
        ),
        task.edge,
      ]);
    } on Cancelled {
      // The same bounded disk-source demand can resume after idle/foreground.
    } catch (_) {
      _derivatives.remove(task.file.path);
    } finally {
      cancel.cancel();
      _derivativeResult = null;
      _derivativeRunning = false;
      _activeDerivativePath = null;
      if (identical(_derivativePublicationCancel, cancel)) {
        _derivativePublicationCancel = null;
      }
      _syncDerivativePins();
      _reportDerivatives();
      _scheduleDerivative(immediate: completed);
    }
  }

  Future<void> _diskWork = Future.value();
  Future<void> _publish(Future<void> Function() commit) {
    final work = _diskWork.then((_) => commit());
    _diskWork = work.catchError((Object _) {});
    return work;
  }
}

/// Worker-only publication. The OS allocates an exclusive staging directory
/// beside the target, so independent isolates/processes cannot share a .part
/// path even if their clocks and request IDs are identical. The final rename
/// remains on the same filesystem and readers only see a complete file.
@visibleForTesting
Future<void> publishAlbumCacheFile(
  File target,
  List<int> bytes,
  CancelToken cancel, {
  Future<void> Function()? beforeCommit,
}) async {
  cancel.check();
  final staging = await target.parent.createTemp('.album-write-');
  try {
    cancel.check();
    final temporary = File(p.join(staging.path, 'image.part'));
    await temporary.writeAsBytes(bytes, flush: true);
    if (beforeCommit != null) await beforeCommit();
    cancel.check();
    await temporary.rename(target.path);
  } finally {
    try {
      await staging.delete(recursive: true);
    } on FileSystemException {
      // A user cache-clear can remove staging while cancellation unwinds.
      // Do not hide other cleanup failures or replace a cancelled operation.
      if (await staging.exists()) rethrow;
    }
  }
}

class _AlbumDerivativeTask {
  final File original, file, sidecar, sharedFacts;
  final _AlbumImageFacts facts;
  final String sourcePath;
  final int edge;
  const _AlbumDerivativeTask({
    required this.original,
    required this.file,
    required this.sidecar,
    required this.sharedFacts,
    required this.facts,
    required this.sourcePath,
    required this.edge,
  });
}

void _albumDerivativeMain(SendPort replies) {
  final commands = ReceivePort();
  replies.send(commands.sendPort);
  commands.listen((message) async {
    final args = message as List;
    try {
      final file = File(args[1] as String);
      if (await file.length() > (args[4] as int)) {
        replies.send([args[0], null, 0, 0]);
        return;
      }
      final bytes = await file.readAsBytes();
      final decoded = decodeAlbumImage(
        bytes,
        edge: args[2] as int,
        maxPixels: args[3] as int,
      );
      if (decoded == null) {
        replies.send([args[0], null, 0, 0]);
      } else {
        replies.send([
          args[0],
          images.encodeJpg(decoded, quality: 90),
          decoded.width,
          decoded.height,
        ]);
      }
    } catch (_) {
      replies.send([args[0], null, 0, 0]);
    }
  });
}

class _AlbumImageFacts {
  final int? capturedAt, sourceWidth, sourceHeight, orientation, offsetMinutes;
  final String? captureTimeRaw;
  final int thumbnailWidth, thumbnailHeight, version;
  final Map<String, String> exif;
  const _AlbumImageFacts({
    this.capturedAt,
    this.sourceWidth,
    this.sourceHeight,
    this.orientation,
    this.offsetMinutes,
    this.captureTimeRaw,
    this.thumbnailWidth = 0,
    this.thumbnailHeight = 0,
    this.version = 3,
    this.exif = const {},
  });

  _AlbumImageFacts withThumbnail(int width, int height) => _AlbumImageFacts(
    capturedAt: capturedAt,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    orientation: orientation,
    offsetMinutes: offsetMinutes,
    captureTimeRaw: captureTimeRaw,
    thumbnailWidth: width,
    thumbnailHeight: height,
    exif: exif,
    version: version,
  );

  AlbumImageResult result({
    String? path,
    required String sourcePath,
    required bool previewOnly,
    String? decodedFallbackPath,
    bool metadataIncomplete = false,
    bool encodedSource = false,
  }) => AlbumImageResult(
    path: path,
    sourcePath: sourcePath,
    width: thumbnailWidth,
    height: thumbnailHeight,
    previewOnly: previewOnly,
    metadataIncomplete: metadataIncomplete,
    metadataVersion: version,
    encodedSource: encodedSource,
    decodedFallbackPath: decodedFallbackPath,
    metadata: AlbumFileMetadata(
      capturedAt: capturedAt,
      width: sourceWidth,
      height: sourceHeight,
    ),
    orientation: orientation,
    captureTimeRaw: captureTimeRaw,
    captureOffsetMinutes: offsetMinutes,
    exif: exif,
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'exif': exif,
    'capturedAt': capturedAt,
    'width': sourceWidth,
    'height': sourceHeight,
    'orientation': orientation,
    'offsetMinutes': offsetMinutes,
    'captureTimeRaw': captureTimeRaw,
    'thumbnailWidth': thumbnailWidth,
    'thumbnailHeight': thumbnailHeight,
  };

  static _AlbumImageFacts? fromJson(dynamic value) {
    if (value is! Map || ![2, 3].contains(value['version'])) return null;
    int? integer(String key) => value[key] is int ? value[key] as int : null;
    return _AlbumImageFacts(
      version: integer('version') ?? 2,
      exif: Map.unmodifiable({
        if (value['exif'] is Map)
          for (final item in (value['exif'] as Map).entries.take(96))
            if (item.key is String && item.value is String)
              item.key as String: item.value as String,
      }),
      capturedAt: integer('capturedAt'),
      sourceWidth: integer('width'),
      sourceHeight: integer('height'),
      orientation: integer('orientation'),
      offsetMinutes: integer('offsetMinutes'),
      captureTimeRaw: value['captureTimeRaw'] is String
          ? value['captureTimeRaw'] as String
          : null,
      thumbnailWidth: integer('thumbnailWidth') ?? 0,
      thumbnailHeight: integer('thumbnailHeight') ?? 0,
    );
  }
}

bool _completeJpegHeader(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) return false;
  var offset = 2;
  while (offset + 1 < bytes.length) {
    if (bytes[offset++] != 0xff) return false;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) return false;
    final marker = bytes[offset++];
    if (marker == 0xda || marker == 0xd9) return true;
    if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd7) continue;
    if (offset + 2 > bytes.length) return false;
    final size = (bytes[offset] << 8) | bytes[offset + 1];
    if (size < 2 || offset + size > bytes.length) return false;
    offset += size;
  }
  return false;
}

_AlbumImageFacts _albumHeaderFacts(
  Uint8List bytes, {
  required int maxPixels,
  required bool raw,
}) {
  images.ExifData? exif;
  final tiff =
      bytes.length >= 8 &&
      (bytes[0] == 0x49 && bytes[1] == 0x49 ||
          bytes[0] == 0x4d && bytes[1] == 0x4d);
  if (tiff) {
    try {
      exif = images.ExifData.fromInputBuffer(images.InputBuffer(bytes));
    } catch (_) {}
  }
  return _albumImageFacts(
    bytes,
    raw: raw,
    maxPixels: maxPixels,
    sourceExif: exif,
  );
}

_AlbumImageFacts _albumImageFacts(
  Uint8List bytes, {
  required bool raw,
  required int maxPixels,
  int? fallbackOrientation,
  images.ExifData? sourceExif,
}) {
  final decoder = images.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  final exif = sourceExif ?? images.decodeJpgExif(bytes);
  final orientation =
      _validOrientation(exif?.imageIfd.orientation) ?? fallbackOrientation;
  int? width = info?.width, height = info?.height;
  final jpeg = bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
  final sourceBudget = jpeg
      ? math.max(maxPixels, 256 * 1024 * 1024)
      : maxPixels;
  if (width == null ||
      height == null ||
      width <= 0 ||
      height <= 0 ||
      width * height > sourceBudget ||
      raw) {
    // A RAW's embedded JPEG dimensions are not its original sensor dimensions.
    width = null;
    height = null;
  } else if (orientation != null && orientation >= 5 && orientation <= 8) {
    final swap = width;
    width = height;
    height = swap;
  }
  final time = exif?.exifIfd['DateTimeOriginal']
      ?.toString()
      .replaceAll('\u0000', '')
      .trim();
  final offset = exif?.exifIfd['OffsetTimeOriginal']
      ?.toString()
      .replaceAll('\u0000', '')
      .trim();
  final parsed = parseAlbumCaptureTime(time, offset);
  return _AlbumImageFacts(
    capturedAt: parsed?.$1,
    sourceWidth: width,
    sourceHeight: height,
    orientation: orientation,
    captureTimeRaw: time,
    offsetMinutes: parsed?.$2,
    exif: _albumExifDetails(exif),
  );
}

/// Keep only bounded, readable tags. MakerNotes, thumbnails and structural
/// offsets are binary/implementation data and do not belong in photo details.
Map<String, String> _albumExifDetails(images.ExifData? exif) {
  if (exif == null) return const {};
  const labels = <String, String>{
    'Make': '相机厂商',
    'Model': '相机型号',
    'Software': '软件',
    'Artist': '作者',
    'Copyright': '版权',
    'ImageDescription': '描述',
    'DateTime': '修改时间',
    'DateTimeOriginal': '拍摄时间',
    'DateTimeDigitized': '数字化时间',
    'OffsetTimeOriginal': '拍摄时区',
    'ExposureTime': '曝光时间',
    'FNumber': '光圈',
    'PhotographicSensitivity': 'ISO',
    'ISOSpeedRatings': 'ISO',
    'FocalLength': '焦距',
    'FocalLengthIn35mmFilm': '35mm 等效焦距',
    'LensMake': '镜头厂商',
    'LensModel': '镜头型号',
    'ExposureProgram': '曝光程序',
    'ExposureMode': '曝光模式',
    'ExposureBiasValue': '曝光补偿',
    'MeteringMode': '测光模式',
    'Flash': '闪光灯',
    'WhiteBalance': '白平衡',
    'ColorSpace': '色彩空间',
    'Orientation': '方向',
    'PixelXDimension': '原始宽度',
    'PixelYDimension': '原始高度',
    'XResolution': '水平分辨率',
    'YResolution': '垂直分辨率',
    'ResolutionUnit': '分辨率单位',
    'SubSecTimeOriginal': '拍摄亚秒',
    'BodySerialNumber': '机身序列号',
    'LensSerialNumber': '镜头序列号',
    'GPSLatitudeRef': '纬度方向',
    'GPSLatitude': '纬度',
    'GPSLongitudeRef': '经度方向',
    'GPSLongitude': '经度',
    'GPSAltitudeRef': '海拔参考',
    'GPSAltitude': '海拔',
    'GPSTimeStamp': 'GPS 时间',
    'GPSDateStamp': 'GPS 日期',
  };
  const gpsNames = <int, String>{
    1: 'GPSLatitudeRef',
    2: 'GPSLatitude',
    3: 'GPSLongitudeRef',
    4: 'GPSLongitude',
    5: 'GPSAltitudeRef',
    6: 'GPSAltitude',
    7: 'GPSTimeStamp',
    29: 'GPSDateStamp',
  };
  const skipped = <int>{
    0x8769,
    0x8825,
    0xa005,
    0x927c,
    0x0201,
    0x0202,
    0x0111,
    0x0117,
    0x014a,
  };
  final result = <String, String>{};
  void read(images.IfdDirectory directory, {bool gps = false}) {
    for (final tag in directory.keys.take(96)) {
      if (result.length >= 96 || skipped.contains(tag)) continue;
      final value = directory[tag];
      if (value == null || value.dataSize > 1024) continue;
      final name = gps ? gpsNames[tag] : exif.getTagName(tag);
      if (name == null || name == '<unknown>') continue;
      final text = value
          .toString()
          .replaceAll(RegExp(r'[\x00-\x1f]'), '')
          .trim();
      if (text.isEmpty) continue;
      result[labels[name] ?? name] = text.length > 256
          ? '${text.substring(0, 256)}…'
          : text;
    }
  }

  read(exif.imageIfd);
  read(exif.exifIfd);
  read(exif.gpsIfd, gps: true);
  read(exif.interopIfd);
  return Map.unmodifiable(result);
}

/// Preserve the source wall time separately. An unknown EXIF offset remains
/// unknown; it is interpreted in this device's local zone for local date UI.
@visibleForTesting
(int, int?)? parseAlbumCaptureTime(String? raw, String? offset) {
  if (raw == null) return null;
  final match = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$')
      .firstMatch(raw);
  if (match == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
  final calendar = DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
  if (calendar.year != parts[0] ||
      calendar.month != parts[1] ||
      calendar.day != parts[2] ||
      calendar.hour != parts[3] ||
      calendar.minute != parts[4] ||
      calendar.second != parts[5]) {
    return null;
  }
  int? minutes;
  if (offset != null && offset.isNotEmpty) {
    final zone = RegExp(r'^([+-])(\d{2}):(\d{2})$').firstMatch(offset);
    if (zone != null) {
      final hours = int.parse(zone[2]!);
      final mins = int.parse(zone[3]!);
      if (hours <= 14 && mins < 60 && (hours < 14 || mins == 0)) {
        minutes = (hours * 60 + mins) * (zone[1] == '-' ? -1 : 1);
      }
    }
  }
  final instant = minutes == null
      ? DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
      : calendar.subtract(Duration(minutes: minutes));
  return (instant.millisecondsSinceEpoch, minutes);
}

/// Worker-only conversion. JPEG uses reduced DCT decoding before resizing.
/// Other formats are limited before allocating their full pixel buffer.
@visibleForTesting
images.Image? decodeAlbumImage(
  Uint8List bytes, {
  required int edge,
  required int maxPixels,
  int? fallbackOrientation,
}) {
  final jpeg = bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
  final initial = jpeg
      ? images.JpegDecoder()
      : images.findDecoderForData(bytes);
  if (initial == null) return null;
  final info = initial.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height >
          (jpeg ? math.max(maxPixels, 256 * 1024 * 1024) : maxPixels)) {
    return null;
  }
  var decoder = initial;
  if (jpeg) {
    var scale = 1;
    while (scale < 8 &&
        math.max(info.width, info.height) ~/ (scale * 2) >= edge) {
      scale *= 2;
    }
    // Scale 8 stores DC coefficients only, including progressive JPEG, so
    // very large originals cannot allocate a full coefficient/pixel buffer.
    if (info.width * info.height > maxPixels) scale = 8;
    if (((info.width + scale - 1) ~/ scale) *
            ((info.height + scale - 1) ~/ scale) >
        maxPixels) {
      return null;
    }
    decoder = images.JpegDecoder(
      maxPixels: math.max(maxPixels, info.width * info.height),
      scale: scale,
    )..startDecode(bytes);
  }
  final decoded = decoder.decodeFrame(0);
  if (decoded == null) return null;
  // JPEG's decoder already bakes its own EXIF orientation and clears the tag.
  // An explicit embedded value of 1 also wins over the enclosing RAW: that
  // preview may already contain rotated pixels. Never apply both transforms.
  if (jpeg &&
      _validOrientation(fallbackOrientation) != null &&
      _validOrientation(images.decodeJpgExif(bytes)?.imageIfd.orientation) ==
          null) {
    decoded.exif.imageIfd.orientation = fallbackOrientation;
  }
  final orientation = _validOrientation(decoded.exif.imageIfd.orientation);
  final oriented = orientation != null && orientation != 1
      ? images.bakeOrientation(decoded)
      : decoded;
  oriented.exif.imageIfd.orientation = null;
  final longest = math.max(oriented.width, oriented.height);
  if (longest <= edge) return oriented;
  return images.copyResize(
    oriented,
    width: math.max(1, (oriented.width * edge / longest).round()),
    height: math.max(1, (oriented.height * edge / longest).round()),
    interpolation: images.Interpolation.average,
  );
}

int? _validOrientation(int? value) =>
    value != null && value >= 1 && value <= 8 ? value : null;

/// Reads only classic TIFF directory structure, never RAW pixels or MakerNotes.
/// A matching preview IFD takes precedence over IFD0; unsupported containers,
/// invalid tags and offsets remain unknown. All walks and allocations are bound.
@visibleForTesting
int? readAlbumRawOrientation(Uint8List bytes, {required int previewOffset}) {
  if (bytes.length < 8) return null;
  final endian = bytes[0] == 0x49 && bytes[1] == 0x49
      ? Endian.little
      : bytes[0] == 0x4d && bytes[1] == 0x4d
      ? Endian.big
      : null;
  if (endian == null) return null;
  final data = ByteData.sublistView(bytes);
  int u16(int offset) => data.getUint16(offset, endian);
  int u32(int offset) => data.getUint32(offset, endian);
  if (u16(2) != 42) return null;
  final first = u32(4);
  final pending = <int>[first];
  final visited = <int>{};
  int? primary;
  while (pending.isNotEmpty && visited.length < 16) {
    final offset = pending.removeLast();
    if (offset < 8 || offset + 2 > bytes.length || !visited.add(offset)) {
      continue;
    }
    final count = u16(offset);
    if (count > 256 || offset + 2 + count * 12 + 4 > bytes.length) continue;
    int? orientation;
    var matchingPreview = false;
    for (var index = 0; index < count; index++) {
      final at = offset + 2 + index * 12;
      final tag = u16(at), type = u16(at + 2), length = u32(at + 4);
      if (tag == 0x112 && type == 3 && length == 1) {
        orientation = _validOrientation(u16(at + 8));
      } else if ((tag == 0x201 || tag == 0x111) &&
          type == 4 &&
          length == 1 &&
          u32(at + 8) == previewOffset) {
        matchingPreview = true;
      } else if (tag == 0x14a && type == 4 && length > 0 && length <= 16) {
        // SubIFDs can carry a preview-specific orientation (e.g. DNG).
        final base = length == 1 ? at + 8 : u32(at + 8);
        if (base < 8 || base + length * 4 > bytes.length) continue;
        for (var child = 0; child < length && pending.length < 16; child++) {
          pending.add(u32(base + child * 4));
        }
      }
    }
    if (matchingPreview && orientation != null) return orientation;
    if (offset == first) primary = orientation;
    final next = u32(offset + 2 + count * 12);
    if (next != 0 && pending.length < 16) pending.add(next);
  }
  return primary;
}

/// Best bounded embedded JPEG candidate. This does not interpret RAW pixels.
/// Scan only the already budgeted file and inspect at most 32 JPEG candidates.
@visibleForTesting
Uint8List? extractAlbumRawJpeg(Uint8List bytes, {required int maxPixels}) {
  Uint8List? best;
  var bestPixels = 0, candidates = 0;
  for (var i = 0; i + 3 < bytes.length && candidates < 32; i++) {
    if (bytes[i] != 0xff || bytes[i + 1] != 0xd8 || bytes[i + 2] != 0xff) {
      continue;
    }
    candidates++;
    final end = _jpegEnd(bytes, i);
    if (end == null) continue;
    final candidate = Uint8List.sublistView(bytes, i, end);
    final info = images.JpegDecoder().startDecode(candidate);
    if (info == null) continue;
    final pixels = info.width * info.height;
    if (pixels > bestPixels && pixels <= maxPixels) {
      best = candidate;
      bestPixels = pixels;
    }
    i = end - 1;
  }
  return best;
}

int? _jpegEnd(Uint8List data, int start) {
  var offset = start + 2;
  var entropy = false;
  while (offset + 1 < data.length) {
    if (data[offset] != 0xff) {
      if (!entropy) return null;
      offset++;
      continue;
    }
    while (offset < data.length && data[offset] == 0xff) {
      offset++;
    }
    if (offset >= data.length) return null;
    final marker = data[offset++];
    if (marker == 0xd9) return offset;
    if (marker == 0 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (marker == 0xd8 || offset + 1 >= data.length) return null;
    final length = (data[offset] << 8) | data[offset + 1];
    if (length < 2 || offset + length > data.length) return null;
    offset += length;
    entropy = marker == 0xda;
  }
  return null;
}
