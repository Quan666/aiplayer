import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/network.dart';
import '../core/system_proxy.dart';
import '../sources/configuration.dart';
import '../sources/source.dart';
import 'store.dart';
import 'directory_metadata_worker.dart' show prepareOfflineMediaBindings;

part 'offline_download_worker.dart';
part 'offline_download_folders.dart';

enum OfflineDownloadStatus { queued, downloading, paused, completed, failed }

/// A device-local download. Remote identity and metadata remain in the library.
@immutable
class OfflineDownload {
  final String mediaId, sourceId, remotePath, localPath, name, error;
  final String bindingRevision;
  final bool userPaused, isDirectory;
  final int discoveredFiles, scannedFolders;
  final OfflineDownloadStatus status;
  final int received, total;

  const OfflineDownload({
    required this.mediaId,
    required this.sourceId,
    required this.remotePath,
    required this.localPath,
    required this.name,
    required this.status,
    this.received = 0,
    this.total = 0,
    this.error = '',
    this.bindingRevision = '',
    this.userPaused = false,
    this.isDirectory = false,
    this.discoveredFiles = 0,
    this.scannedFolders = 0,
  });

  bool get isComplete =>
      status == OfflineDownloadStatus.completed && !isDirectory;
  bool get isBusy =>
      status == OfflineDownloadStatus.queued ||
      status == OfflineDownloadStatus.downloading ||
      status == OfflineDownloadStatus.paused;

  factory OfflineDownload._fromMap(Map map) => OfflineDownload(
    mediaId: map['mediaId'] as String,
    sourceId: map['sourceId'] as String,
    remotePath: map['remotePath'] as String,
    localPath: map['localPath'] as String? ?? '',
    name: map['name'] as String,
    status: OfflineDownloadStatus.values.byName(map['status'] as String),
    received: map['received'] as int? ?? 0,
    total: map['total'] as int? ?? 0,
    error: map['error'] as String? ?? '',
    bindingRevision: map['bindingRevision'] as String? ?? '',
    userPaused: map['userPaused'] == true,
    isDirectory: map['isDirectory'] == true,
    discoveredFiles: map['discoveredFiles'] as int? ?? 0,
    scannedFolders: map['scannedFolders'] as int? ?? 0,
  );
}

/// One long-lived worker owns network streams, files, hashing and SQLite.
/// The UI receives only changed task summaries, at most twice a second/task.
class OfflineDownloads extends ChangeNotifier {
  final Directory directory;
  final String storePath;
  final Future<Map<String, dynamic>?> Function(String sourceId)
  sourceConfiguration;
  final _entries = <String, OfflineDownload>{};
  late final Map<String, OfflineDownload> entries = UnmodifiableMapView(
    _entries,
  );
  final _taskIds = <String>[];
  late final List<String> taskIds = UnmodifiableListView(_taskIds);
  int tasksRevision = 0;
  int _activeCount = 0, _pausedCount = 0, _failedCount = 0, _completedCount = 0;
  int get activeCount => _activeCount;
  int get pausedCount => _pausedCount;
  int get failedCount => _failedCount;
  int get completedCount => _completedCount;

  final _completedLocations = <String, Map<String, dynamic>>{};
  late final Map<String, Map<String, dynamic>> completedLocations =
      UnmodifiableMapView(_completedLocations);
  final _pending = <int, Completer<dynamic>>{};
  ReceivePort? _messages;
  SendPort? _commands;
  Future<void>? _initialization;
  Completer<void>? _ready;
  Completer<void>? _stopped;
  bool _active, _closing = false, _disposed = false;
  int _serial = 0;
  int completedRevision = 0;
  int libraryRevision = 0;

  OfflineDownloads({
    required this.directory,
    required this.storePath,
    required this.sourceConfiguration,
    bool active = true,
  }) : _active = active;

  bool get initialized => _commands != null && _ready?.isCompleted == true;

  OfflineDownload? entryFor(String mediaId) => _entries[mediaId];

  Future<void> initialize() {
    if (_closing) return Future.error(const Cancelled());
    return _initialization ??= _start();
  }

  Future<void> _start() async {
    final ready = _ready = Completer<void>();
    _stopped = Completer<void>();
    final messages = _messages = ReceivePort();
    messages.listen(_receive);
    try {
      await Isolate.spawn(
        _offlineWorkerMain,
        [
          directory.path,
          storePath,
          _active,
          messages.sendPort,
          SystemProxyWorkerConfiguration.capture(),
        ],
        onError: messages.sendPort,
        onExit: messages.sendPort,
      );
      await ready.future;
    } catch (_) {
      _stop(const AppFailure('无法打开离线下载，请重试。'));
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (message == null || message is! List || message.first is! String) {
      _stop(const AppFailure('离线下载服务已停止，请重新打开应用。'));
      return;
    }
    final row = message;
    switch (row[0]) {
      case 'ready':
        _commands = row[1] as SendPort;
        for (final entry in row[2] as List) {
          final item = OfflineDownload._fromMap(entry as Map);
          _updateEntry(item);
        }
        if (_completedCount > 0) completedRevision++;
        _commands!.send(['active', 0, _active && !_closing]);
        if (_closing) _commands!.send(['close', 0]);
        if (!_ready!.isCompleted) _ready!.complete();
        if (!_disposed && !_closing) notifyListeners();
      case 'changed':
        final next = OfflineDownload._fromMap(row[1] as Map);
        final previous = _entries[next.mediaId];
        if ((previous?.isComplete ?? false) != next.isComplete ||
            (next.isComplete && previous?.localPath != next.localPath)) {
          completedRevision++;
        }
        _updateEntry(next);
        if (!_disposed && !_closing) notifyListeners();
      case 'removed':
        _removeEntry(row[1] as String);
        if (!_disposed && !_closing) notifyListeners();
      case 'admitted':
        for (final value in row[2] as List) {
          _updateEntry(OfflineDownload._fromMap(value as Map));
        }
        _removeEntry(row[1] as String);
        // Folder admission registered media bindings on the worker connection.
        // Publish one catalogue refresh before the first file completes.
        libraryRevision++;
        if (!_disposed && !_closing) notifyListeners();
      case 'configuration':
        unawaited(_provideConfiguration(row[1] as int, row[2] as String));
      case 'result':
        _pending.remove(row[1])?.complete(row[2]);
      case 'error':
        _pending.remove(row[1])?.completeError(AppFailure(row[2] as String));
      case 'closed':
        _stop(const Cancelled());
      default:
        _stop(const AppFailure('无法打开离线下载，请重试。'));
    }
  }

  void _removeEntry(String id) {
    final removed = _entries.remove(id);
    if (removed != null) {
      _count(removed.status, -1);
      _taskIds.remove(id);
      tasksRevision++;
      if (removed.isComplete) completedRevision++;
    }
    _completedLocations.remove(id);
  }

  void _count(OfflineDownloadStatus status, int delta) {
    switch (status) {
      case OfflineDownloadStatus.queued:
      case OfflineDownloadStatus.downloading:
        _activeCount += delta;
      case OfflineDownloadStatus.paused:
        _pausedCount += delta;
      case OfflineDownloadStatus.failed:
        _failedCount += delta;
      case OfflineDownloadStatus.completed:
        _completedCount += delta;
    }
  }

  void _updateEntry(OfflineDownload entry) {
    final previous = _entries[entry.mediaId];
    if (previous == null) {
      _taskIds.add(entry.mediaId);
      tasksRevision++;
    } else {
      _count(previous.status, -1);
    }
    _count(entry.status, 1);
    _entries[entry.mediaId] = entry;
    _updateCompletedLocation(entry);
  }

  void _updateCompletedLocation(OfflineDownload entry) {
    if (entry.isComplete) {
      _completedLocations[entry.mediaId] = Map<String, dynamic>.unmodifiable({
        'id': entry.mediaId,
        'source': 'local',
        'path': entry.localPath,
        'size': entry.total,
        'offline': true,
        'remoteRevision': entry.bindingRevision,
        'remoteSource': entry.sourceId,
        'remotePath': entry.remotePath,
      });
    } else {
      _completedLocations.remove(entry.mediaId);
    }
  }

  Future<void> _provideConfiguration(int request, String sourceId) async {
    Map<String, dynamic>? value;
    try {
      if (!_closing && _active) value = await sourceConfiguration(sourceId);
    } catch (_) {
      // Do not expose platform credential errors or connection strings.
    }
    if (_closing || !_active) value = null;
    _commands?.send(['configuration', request, value]);
  }

  void _stop(Object error) {
    _commands = null;
    _messages?.close();
    _messages = null;
    if (_ready != null && !_ready!.isCompleted) _ready!.completeError(error);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    if (_stopped != null && !_stopped!.isCompleted) _stopped!.complete();
  }

  Future<dynamic> _call(String operation, [dynamic payload]) async {
    await initialize();
    if (_closing || _commands == null) throw const Cancelled();
    if (_pending.length >= 256) {
      throw const AppFailure('下载任务繁忙，请稍后重试。');
    }
    final id = ++_serial;
    final result = Completer<dynamic>();
    _pending[id] = result;
    _commands!.send([operation, id, payload]);
    return result.future;
  }

  Future<void> enqueue({
    required SyncRecord media,
    required Map<String, dynamic> location,
  }) async {
    if (location['source'] == 'local') {
      throw const AppFailure('此视频已在本地。');
    }
    await _call('enqueue', {
      'mediaId': media.id,
      'sourceId': location['source'],
      'remotePath': location['path'],
      'bindingRevision': location['previewRevision'] as String? ?? '',
      'name': media.data['fileName'] ?? media.data['title'] ?? 'video.mp4',
      'total': location['size'] ?? media.data['size'] ?? 0,
    });
  }

  /// Recursively discover a bounded folder before admitting its video files.
  /// Cancelling this scan leaves no newly queued child downloads behind.
  Future<void> enqueueFolder({
    required String sourceId,
    required SourceEntry entry,
  }) async {
    if (sourceId == 'local' || !entry.directory) {
      throw const AppFailure('请选择远程文件夹下载。');
    }
    await _call('enqueueFolder', {
      'sourceId': sourceId,
      'remotePath': entry.path,
      'name': entry.name,
    });
  }

  /// Cancelling removes this attempt and its partial file. Completed downloads
  /// are only removed through delete, avoiding accidental data loss.
  Future<void> cancel(String mediaId) async => _call('cancel', mediaId);
  Future<void> pause(String mediaId) async => _call('pause', mediaId);
  Future<void> resume(String mediaId) async => _call('resume', mediaId);
  Future<void> pauseAll() async => _call('pauseAll');

  /// Failed downloads remain failed until retry is explicitly requested.
  Future<void> resumeAll() async => _call('resumeAll');
  Future<void> retry(String mediaId) async => _call('retry', mediaId);
  Future<void> delete(String mediaId) async => _call('delete', mediaId);
  Future<String?> localPath(String mediaId) async =>
      await _call('localPath', mediaId) as String?;

  void setActive(bool active) {
    if (_closing || _active == active) return;
    _active = active;
    _commands?.send(['active', 0, active]);
  }

  Future<void> close() async {
    if (_closing) {
      await _stopped?.future;
      return;
    }
    _closing = true;
    if (_initialization == null) return;
    _commands?.send(['close', 0]);
    await _stopped?.future;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
