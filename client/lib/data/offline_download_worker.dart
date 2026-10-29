part of 'offline_downloads.dart';

const _downloadCapacity = 2000;
const _downloadConcurrency = 2;
const _downloadTimeout = Duration(seconds: 35);

void _offlineWorkerMain(List<Object?> startup) async {
  initializeSystemProxyWorker(startup[4] as SystemProxyWorkerConfiguration);
  final worker = _OfflineWorker(
    startup[0] as String,
    startup[1] as String,
    startup[2] as bool,
    startup[3] as SendPort,
  );
  await worker.start();
}

class _DownloadAttempt {
  final cancel = CancelToken();
  SourceAdapter? source;
  HttpClient? transferClient;
  Future<void>? done;

  void stop() {
    cancel.cancel();
    transferClient?.close(force: true);
    unawaited(source?.close().catchError((Object _) {}) ?? Future.value());
  }
}

class _DownloadTransfer {
  final int start, total;
  final Stream<List<int>> bytes;
  final String? validator, validatorKind;
  const _DownloadTransfer(
    this.start,
    this.total,
    this.bytes, {
    this.validator,
    this.validatorKind,
  });
}

class _OfflineWorker {
  final String root, storePath;
  final SendPort reply;
  final commands = ReceivePort();
  final rows = <String, Map<String, dynamic>>{};
  final running = <String, _DownloadAttempt>{};
  final configurations = <int, Completer<Map<String, dynamic>?>>{};
  final deleting = <String>{};
  final removalPlans = <String, _LocalRemovalPlan>{};
  final operations = <int, CancelToken>{};
  Database? db;
  AppStore? store;
  bool active, closing = false;
  int serial = 0, nextOrder = 0;
  Future<void> writes = Future.value();

  _OfflineWorker(this.root, this.storePath, this.active, this.reply);

  Future<void> start() async {
    // Initialization and restoring all task summaries occur only in this isolate.
    if (await FileSystemEntity.type(root, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const AppFailure('下载目录不可用。');
    }
    if (await File(p.join(root, 'downloads.sqlite')).exists()) {
      await _ensureDatabase();
    }
    final restored = [
      for (final row
          in db?.select('SELECT value FROM downloads ORDER BY rowid') ??
              const [])
        Map<String, dynamic>.from(jsonDecode(row['value'] as String)),
    ];
    for (final value in restored) {
      final order = value['createdOrder'] as int? ?? 0;
      if (order > nextOrder) nextOrder = order;
    }
    for (final value in restored) {
      if (value['createdOrder'] == null) {
        value['createdOrder'] = ++nextOrder;
        _save(value, notify: false);
      }
    }
    restored.sort(
      (a, b) => (a['createdOrder'] as int).compareTo(b['createdOrder'] as int),
    );
    for (final value in restored) {
      if (const ['downloading', 'queued', 'paused'].contains(value['status'])) {
        value['status'] = _readyStatus(value);
      }
      if (value['status'] == 'completed') {
        final path = value['localPath'] as String? ?? '';
        final valid =
            await _safeManagedPath(path) &&
            await File(path).length().then(
              (size) => size == value['total'],
              onError: (Object _) => false,
            );
        if (!valid) {
          value['status'] = 'failed';
          value['received'] = 0;
          value['error'] = '本地文件已丢失或不完整，可重新下载。';
          _save(value, notify: false);
        }
      }
      if (value['isDirectory'] == true) {
        final taskId = value['mediaId'] as String;
        value['discoveredFiles'] = _folderCount(
          'download_folder_files',
          taskId,
        );
        value['scannedFolders'] =
            _folderCount('download_folder_paths', taskId) -
            _folderCount('download_folder_paths', taskId, pending: true);
      }
      if (value['status'] != 'completed') {
        final checkpoint = await _partialOffset(value);
        value['checkpointBytes'] = checkpoint;
        value['received'] = checkpoint;
      }
      rows[value['mediaId'] as String] = value;
    }
    commands.listen((dynamic input) {
      final message = input as List;
      if (message[0] == 'configuration') {
        configurations
            .remove(message[1])
            ?.complete(
              message[2] == null ? null : Map<String, dynamic>.from(message[2]),
            );
      } else if (message[0] == 'active') {
        _setActive(message[2] as bool);
      } else if (message[0] == 'cancelOperation') {
        operations[message[1]]?.cancel();
      } else if (message[0] == 'close') {
        closing = true;
        for (final token in operations.values) {
          token.cancel();
        }
        removalPlans.clear();
        _setActive(false);
        unawaited(_close());
      } else {
        if (message[0] == 'prepareLocalDirectoryRemoval' ||
            message[0] == 'deleteLocalDirectory') {
          operations[message[1] as int] = CancelToken();
        }
        // User mutations are serialized; lifecycle signals bypass this queue.
        writes = writes.then((_) => _command(message));
      }
    });
    reply.send(['ready', commands.sendPort, rows.values.toList()]);
    _pump();
  }

  Future<void> _ensureDatabase() async {
    if (db != null) return;
    if (await FileSystemEntity.type(root, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const AppFailure('下载目录不可用。');
    }
    await Directory(root).create(recursive: true);
    final database = sqlite3.open(p.join(root, 'downloads.sqlite'));
    try {
      database.execute('PRAGMA journal_mode=WAL');
      database.execute(
        'CREATE TABLE IF NOT EXISTS downloads('
        'id TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      database.execute(
        'CREATE TABLE IF NOT EXISTS download_folder_paths('
        'task TEXT NOT NULL,path TEXT NOT NULL,scanned INTEGER NOT NULL DEFAULT 0,'
        'PRIMARY KEY(task,path))',
      );
      database.execute(
        'CREATE INDEX IF NOT EXISTS download_folder_pending '
        'ON download_folder_paths(task,scanned)',
      );
      database.execute(
        'CREATE TABLE IF NOT EXISTS download_folder_files('
        'task TEXT NOT NULL,path TEXT NOT NULL,name TEXT NOT NULL,size INTEGER NOT NULL,'
        'modified INTEGER NOT NULL,expected_id TEXT,expected_revision TEXT,'
        'expected_deleted INTEGER,expected_record_revision INTEGER,'
        'PRIMARY KEY(task,path))',
      );
      final folderColumns = database
          .select('PRAGMA table_info(download_folder_files)')
          .map((row) => row['name'])
          .toSet();
      var migratedFolderGuards = false;
      for (final column in const {
        'expected_id': 'TEXT',
        'expected_revision': 'TEXT',
        'expected_deleted': 'INTEGER',
        'expected_record_revision': 'INTEGER',
      }.entries) {
        if (!folderColumns.contains(column.key)) {
          database.execute(
            'ALTER TABLE download_folder_files ADD COLUMN ${column.key} ${column.value}',
          );
          migratedFolderGuards = true;
        }
      }
      if (migratedFolderGuards) {
        // Old scans lack the binding observed when each file was discovered.
        // Re-enumerate rather than assuming a later manual rebind was unchanged.
        database.execute('DELETE FROM download_folder_files');
        database.execute('UPDATE download_folder_paths SET scanned=0');
      }
      if (storePath != ':memory:') store = AppStore.openExisting(storePath);
      db = database;
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }

  void _save(Map<String, dynamic> row, {bool notify = true}) {
    db!.execute('INSERT OR REPLACE INTO downloads(id,value) VALUES(?,?)', [
      row['mediaId'],
      jsonEncode(row),
    ]);
    if (notify && !closing) reply.send(['changed', row]);
  }

  void _setActive(bool value) {
    active = value && !closing;
    if (!active) {
      for (final attempt in running.values) {
        attempt.stop();
      }
      for (final row in rows.values) {
        if (row['status'] == 'queued' || row['status'] == 'downloading') {
          row['status'] = 'paused';
          _save(row);
        }
      }
    } else {
      for (final row in rows.values) {
        if (row['status'] == 'paused' && row['userPaused'] != true) {
          row['status'] = 'queued';
          _save(row);
        }
      }
      _pump();
    }
  }

  Future<void> _command(List message) async {
    final request = message[1] as int;
    if (closing) {
      reply.send(['error', request, '离线下载服务已关闭。']);
      return;
    }
    try {
      dynamic result;
      final payload = message[2];
      switch (message[0]) {
        case 'prepareLocalDirectoryRemoval':
          result = await _prepareLocalDirectoryRemoval(
            payload[0] as String,
            payload[1] as String,
            operations[request]!,
          );
        case 'deleteLocalDirectory':
          result = await _deleteLocalDirectory(
            payload as String,
            operations[request]!,
          );
        case 'discardLocalDirectoryRemoval':
          removalPlans.remove(payload as String);
        case 'enqueueFolder':
          await _enqueueFolder(Map<String, dynamic>.from(payload as Map));
        case 'enqueue':
          final input = Map<String, dynamic>.from(payload as Map);
          final id = input['mediaId'] as String;
          final sourceId = input['sourceId'] as String;
          final path = input['remotePath'] as String;
          _checkedSegments(path); // Reject traversal before admitting a task.
          if (sourceId == 'local' || sourceId.isEmpty) {
            throw const AppFailure('请选择远程视频下载。');
          }
          await _ensureDatabase();
          final existing = rows[id];
          if (existing != null) {
            if (existing['sourceId'] != sourceId ||
                existing['remotePath'] != path ||
                (existing['bindingRevision'] ?? '') !=
                    (input['bindingRevision'] ?? '')) {
              throw const AppFailure('视频位置已改变，请删除旧下载后重试。');
            }
            if (existing['status'] == 'failed') {
              existing['userPaused'] = false;
              existing['status'] = _readyStatus(existing);
              existing['error'] = '';
              _save(existing);
            }
          } else {
            if (rows.values.where((e) => e['status'] != 'completed').length >=
                _downloadCapacity) {
              throw const AppFailure('下载队列已满，请等待部分任务完成。');
            }
            if (rows.values.any(
              (e) => e['sourceId'] == sourceId && e['remotePath'] == path,
            )) {
              throw const AppFailure('此文件已在下载列表中。');
            }
            final row = <String, dynamic>{
              ...input,
              'status': active ? 'queued' : 'paused',
              'received': 0,
              'checkpointBytes': 0,
              'createdOrder': ++nextOrder,
              'userPaused': false,
              'localPath': '',
              'error': '',
            };
            rows[id] = row;
            _save(row);
          }
          _pump();
        case 'pause':
          final row = rows[payload];
          if (row != null) await _pauseRows([row]);
        case 'pauseAll':
          await _pauseRows(rows.values);
        case 'resume':
          final row = rows[payload];
          if (row != null) _resumeRows([row]);
        case 'resumeAll':
          _resumeRows(rows.values);
        case 'cancel':
          final row = rows[payload];
          if (row != null && row['status'] != 'completed') {
            await _remove(payload);
          }
        case 'delete':
          await _remove(payload as String);
        case 'retry':
          final row = rows[payload];
          if (row != null && row['status'] == 'failed') {
            row['userPaused'] = false;
            row['status'] = _readyStatus(row);
            row['error'] = '';
            _save(row);
            _pump();
          }
        case 'localPath':
          final row = rows[payload];
          if (row != null &&
              row['status'] == 'completed' &&
              row['isDirectory'] != true) {
            final path = row['localPath'] as String;
            final valid =
                await _safeManagedPath(path) &&
                await File(path).length().then(
                  (size) => size == row['total'],
                  onError: (Object _) => false,
                );
            if (valid) {
              result = path;
            } else {
              row['status'] = 'failed';
              row['received'] = 0;
              row['error'] = '本地文件已丢失或不完整，可重新下载。';
              _save(row);
            }
          }
        default:
          throw const AppFailure('未知下载操作。');
      }
      reply.send(['result', request, result]);
    } catch (error) {
      reply.send(
        error is Cancelled
            ? ['cancelled', request]
            : ['error', request, _downloadError(error)],
      );
    } finally {
      operations.remove(request);
    }
  }

  String _readyStatus(Map<String, dynamic> row) =>
      active && !closing && row['userPaused'] != true ? 'queued' : 'paused';

  Future<void> _pauseRows(Iterable<Map<String, dynamic>> selected) async {
    final pending = <Future<void>>[];
    for (final row in selected) {
      if (!const ['queued', 'downloading', 'paused'].contains(row['status'])) {
        continue;
      }
      row['userPaused'] = true;
      row['status'] = 'paused';
      _save(row);
      final attempt = running[row['mediaId']];
      attempt?.stop();
      if (attempt?.done != null) pending.add(attempt!.done!);
    }
    // All selected rows are paused before yielding; freeing a slot cannot admit
    // another selected task while their sockets and files are closing.
    await Future.wait(pending);
  }

  void _resumeRows(Iterable<Map<String, dynamic>> selected) {
    for (final row in selected) {
      if (row['status'] != 'paused') continue;
      row['userPaused'] = false;
      row['status'] = _readyStatus(row);
      row['error'] = '';
      _save(row);
    }
    _pump();
  }

  Future<int> _partialOffset(Map<String, dynamic> row) async {
    final local = row['localPath'] as String? ?? '';
    if (local.isEmpty || !await _safeManagedPath('$local.part')) return 0;
    final file = File('$local.part');
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return 0;
    final recorded = row['checkpointBytes'] as int? ?? 0;
    // Only bytes flushed before a durable checkpoint are eligible for reuse.
    // Extra crash-time bytes are truncated when the next attempt opens the file.
    return recorded.clamp(0, stat.size);
  }

  void _pump() {
    if (!active || closing) return;
    for (final row in rows.values) {
      if (running.length >= _downloadConcurrency) break;
      final id = row['mediaId'] as String;
      if (row['status'] != 'queued' ||
          row['userPaused'] == true ||
          running.containsKey(id) ||
          deleting.contains(id)) {
        continue;
      }
      final attempt = _DownloadAttempt();
      running[id] = attempt;
      row['status'] = 'downloading';
      _save(row);
      final work = row['isDirectory'] == true
          ? _scanFolder(row, attempt)
          : _download(row, attempt);
      attempt.done = work.whenComplete(() {
        running.remove(id);
        _pump();
      });
    }
  }

  Future<T> _wait<T>(Future<T> future, _DownloadAttempt attempt) async {
    attempt.cancel.check();
    final subscription = attempt.cancel.whenCancelled.asStream();
    final cancelled = Completer<T>();
    final listener = subscription.listen((_) {
      if (!cancelled.isCompleted) cancelled.completeError(const Cancelled());
    });
    try {
      final value = await Future.any([
        future.timeout(_downloadTimeout),
        cancelled.future,
      ]);
      attempt.cancel.check();
      return value;
    } finally {
      await listener.cancel();
    }
  }

  Future<Map<String, dynamic>> _configuration(
    String sourceId,
    _DownloadAttempt attempt,
  ) async {
    final request = ++serial;
    final result = Completer<Map<String, dynamic>?>();
    configurations[request] = result;
    reply.send(['configuration', request, sourceId]);
    try {
      final value = await _wait(result.future, attempt);
      if (value == null) throw const AppFailure('来源不可用，请检查来源配置后重试。');
      return value;
    } finally {
      configurations.remove(request);
    }
  }

  void _validateLocation(Map<String, dynamic> row) {
    final library = store;
    if (library == null || storePath == ':memory:') return;
    final id = row['mediaId'] as String;
    final media = library.get('media', id);
    final location = library.local('location:$id') as Map?;
    if (media == null ||
        media.deleted ||
        location?['source'] != row['sourceId'] ||
        location?['path'] != row['remotePath'] ||
        (location?['previewRevision'] ?? '') !=
            (row['bindingRevision'] ?? '')) {
      throw const AppFailure('视频已删除或位置已改变，请重新选择下载。');
    }
  }

  Future<void> _download(
    Map<String, dynamic> row,
    _DownloadAttempt attempt,
  ) async {
    RandomAccessFile? output;
    StreamIterator<List<int>>? input;
    Object? failure;
    var completed = false;
    var previousCheckpoint = row['checkpointBytes'] as int? ?? 0;
    var outputPrepared = false;
    var validatedBytes = previousCheckpoint;
    try {
      final id = row['mediaId'] as String;
      final sourceId = row['sourceId'] as String;
      final remote = row['remotePath'] as String;
      _validateLocation(row);
      final configuration = await _configuration(sourceId, attempt);
      attempt.cancel.check();
      _validateLocation(row);
      final identity = _sourceIdentity(configuration);
      if (row['identity'] != null && row['identity'] != identity) {
        throw const AppFailure('来源地址已改变，请删除旧下载后重新下载。');
      }
      row['identity'] = identity;
      var local = row['localPath'] as String;
      if (local.isEmpty) {
        local = _downloadPath(
          root,
          sourceId,
          remote,
          row['name'] as String,
          configuration,
          downloadRoot: row['downloadRoot'] as String?,
          downloadRelativePath: row['downloadRelativePath'] as String?,
        );
        if (rows.values.any(
          (other) =>
              other['mediaId'] != id &&
              (other['localPath'] as String? ?? '').toLowerCase() ==
                  local.toLowerCase(),
        )) {
          final suffix = sha256
              .convert(utf8.encode(remote))
              .toString()
              .substring(0, 12);
          local = '${p.withoutExtension(local)}-$suffix${p.extension(local)}';
        }
        // Reserve before awaiting so concurrent case-only names cannot collide.
        row['localPath'] = local;
      }
      if (!await _safeManagedPath(local) ||
          !await _safeManagedPath('$local.part')) {
        throw const AppFailure('下载路径不可用。');
      }
      attempt.cancel.check();
      final connection = connectSource(
        configuration,
        password: configuration['password'] as String? ?? '',
      );
      unawaited(
        connection.then<void>((source) {
          if (attempt.cancel.cancelled) {
            unawaited(source.close().catchError((Object _) {}));
          }
        }, onError: (Object _) {}),
      );
      final source = await _wait(connection, attempt);
      attempt.source = source;
      _validateLocation(row);
      final stat = await _wait(source.stat(remote), attempt);
      if (stat.directory || stat.size <= 0) {
        throw const AppFailure('不能下载空文件或目录。');
      }
      _validateLocation(row);
      var offset = await _partialOffset(row);
      attempt.cancel.check();
      if (row['total'] != stat.size || offset > stat.size) offset = 0;
      final _DownloadTransfer transfer;
      if (source is HttpSource) {
        if (row['httpValidator'] == null || row['httpValidatorKind'] == null) {
          offset = 0;
        }
        // A full checkpoint still needs an origin validation before promotion.
        // Re-reading its final byte verifies If-Range without fetching the prefix.
        if (offset == stat.size) offset = stat.size - 1;
        transfer = await _openHttpTransfer(
          source,
          remote,
          stat.size,
          offset,
          row,
          attempt,
        );
      } else {
        if (stat.modified <= 0 || row['remoteModified'] != stat.modified) {
          offset = 0;
        }
        transfer = _DownloadTransfer(
          offset,
          stat.size,
          offset == stat.size
              ? const Stream.empty()
              : source.read(remote, offset, stat.size - 1),
        );
      }
      attempt.cancel.check();
      _validateLocation(row);
      await Directory(p.dirname(local)).create(recursive: true);
      attempt.cancel.check();
      if (!await _safeManagedPath(local) ||
          !await _safeManagedPath('$local.part')) {
        throw const AppFailure('下载路径不可用。');
      }
      output = await File('$local.part').open(mode: FileMode.append);
      attempt.cancel.check();
      if (await output.length() < transfer.start) {
        throw const AppFailure('本地下载片段已改变，请重试。');
      }
      await output.truncate(transfer.start);
      await output.setPosition(transfer.start);
      outputPrepared = true;
      validatedBytes = transfer.start;
      attempt.cancel.check();
      previousCheckpoint = transfer.start;
      row['checkpointBytes'] = transfer.start;
      row['received'] = transfer.start;
      row['total'] = transfer.total;
      row['remoteModified'] = stat.modified;
      row['httpValidator'] = transfer.validator;
      row['httpValidatorKind'] = transfer.validatorKind;
      row['error'] = '';
      _save(row);
      input = StreamIterator(transfer.bytes);
      var received = transfer.start;
      final clock = Stopwatch()..start();
      while (await _wait(input.moveNext(), attempt)) {
        final bytes = input.current;
        if (received + bytes.length > transfer.total) {
          throw const AppFailure('来源返回的文件大小不一致，请重试。');
        }
        await output.writeFrom(bytes);
        received += bytes.length;
        validatedBytes = received;
        row['received'] = received;
        attempt.cancel.check();
        if (clock.elapsedMilliseconds >= 500) {
          if (!closing) reply.send(['changed', row]);
          clock.reset();
        }
      }
      if (received != transfer.total) throw const AppFailure('视频读取提前结束，请重试。');
      if (source is! HttpSource && stat.modified > 0) {
        final latest = await _wait(source.stat(remote), attempt);
        if (latest.size != stat.size || latest.modified != stat.modified) {
          // This fragment belongs to an outdated representation; it cannot be
          // resumed even if the server later reuses the original modification time.
          row['remoteModified'] = null;
          throw const AppFailure('下载期间远程文件发生变化，请重试。');
        }
      }
      await output.flush();
      await output.close();
      output = null;
      row['checkpointBytes'] = received;
      attempt.cancel.check();
      _validateLocation(row);
      await File('$local.part').rename(local);
      row['status'] = 'completed';
      row['received'] = received;
      row['userPaused'] = false;
      row['error'] = '';
      _save(row);
      completed = true;
    } catch (error) {
      failure = error;
    } finally {
      final wasCancelled = attempt.cancel.cancelled || failure is Cancelled;
      attempt.stop();
      try {
        await input?.cancel();
      } catch (_) {}
      if (output != null) {
        var flushed = false;
        try {
          await output.flush();
          flushed = true;
        } catch (error) {
          failure ??= error;
        }
        try {
          await output.close();
        } catch (error) {
          failure ??= error;
          flushed = false;
        }
        final local = row['localPath'] as String;
        if (local.isNotEmpty && await _safeManagedPath('$local.part')) {
          try {
            final length = await File('$local.part').length();
            row['checkpointBytes'] =
                (flushed && outputPrepared
                        ? validatedBytes
                        : previousCheckpoint)
                    .clamp(0, length);
          } on FileSystemException {
            row['checkpointBytes'] = 0;
          }
        }
      }
      try {
        await attempt.source?.close();
      } catch (_) {}
      if (!completed && !deleting.contains(row['mediaId'])) {
        row['received'] = row['checkpointBytes'] as int? ?? 0;
        row['status'] = wasCancelled ? _readyStatus(row) : 'failed';
        row['error'] = wasCancelled
            ? ''
            : _downloadError(failure ?? const AppFailure('下载失败，请重试。'));
        // Keep resumable fragments for pause, process close and transient failure.
        // Only cancellation/deletion removes them. Checkpoint follows file close.
        _save(row);
      }
    }
  }

  (String, String)? _httpValidator(HttpClientResponse response) {
    final etag = response.headers.value('etag')?.trim();
    if (etag != null &&
        etag.length <= 1024 &&
        etag.startsWith('"') &&
        etag.endsWith('"')) {
      return ('etag', etag);
    }
    // If-Range dates are only safe without an entity tag and when Date proves
    // Last-Modified was not a potentially ambiguous same-second validator.
    if (etag != null) return null;
    final modified = response.headers.value('last-modified')?.trim();
    final dated = response.headers.value('date');
    if (modified != null && modified.length < 128 && dated != null) {
      try {
        if (HttpDate.parse(
              dated,
            ).difference(HttpDate.parse(modified)).inSeconds >=
            60) {
          return ('last-modified', modified);
        }
      } on HttpException {
        /* no validator */
      } on FormatException {
        /* no validator */
      }
    }
    return null;
  }

  Future<_DownloadTransfer> _openHttpTransfer(
    HttpSource source,
    String path,
    int size,
    int offset,
    Map<String, dynamic> row,
    _DownloadAttempt attempt,
  ) async {
    var total = size, start = offset;
    for (var pass = 0; pass < 2; pass++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 25)
        ..autoUncompress = false;
      attempt.transferClient = client;
      var handedOff = false;
      try {
        final request = await _wait(
          openProxyAwareRequest(
            client,
            'GET',
            source.url(path),
            proxyResolver: source.proxyResolver,
            cancel: attempt.cancel,
          ),
          attempt,
        );
        request.headers.set('Range', 'bytes=$start-${total - 1}');
        request.headers.set('Accept-Encoding', 'identity');
        if (start > 0) request.headers.set('If-Range', row['httpValidator']);
        if (source.user.isNotEmpty) {
          request.headers.set(
            'Authorization',
            'Basic ${base64Encode(utf8.encode('${source.user}:${source.password}'))}',
          );
        }
        final response = await _wait(request.close(), attempt);
        final encoding = response.headers.value('content-encoding');
        if (encoding != null && encoding.toLowerCase() != 'identity') {
          throw const AppFailure('来源返回了压缩的视频传输，请重试。');
        }
        final validator = _httpValidator(response);
        var restart = false;
        if (response.statusCode == 200) {
          // A full response to If-Range either changed representation or ignored
          // the range. Use that whole body after truncating, never append it.
          if (start > 0) {
            start = 0;
            if (response.contentLength > 0) total = response.contentLength;
          }
          if (response.contentLength >= 0 && response.contentLength != total) {
            throw const AppFailure('下载期间远程文件大小发生变化，请重试。');
          }
        } else if (response.statusCode == 206) {
          final range = RegExp(
            r'^bytes (\d+)-(\d+)/(\d+)$',
          ).firstMatch(response.headers.value('content-range') ?? '');
          final matchingRange =
              range != null &&
              int.tryParse(range[1]!) == start &&
              int.tryParse(range[2]!) == total - 1 &&
              int.tryParse(range[3]!) == total &&
              (response.contentLength < 0 ||
                  response.contentLength == total - start);
          final matchingValidator =
              start == 0 ||
              response.headers
                      .value(row['httpValidatorKind'] as String)
                      ?.trim() ==
                  row['httpValidator'];
          if (!matchingRange || !matchingValidator) {
            if (start > 0) {
              restart = true;
            } else {
              throw const AppFailure('来源返回了不完整或已改变的视频范围，请重试。');
            }
          }
        } else if (response.statusCode == 416 && start > 0) {
          restart = true;
        } else {
          throw sourceHttpFailure(response.statusCode);
        }
        if (restart) {
          client.close(force: true);
          final latest = await _wait(source.stat(path), attempt);
          if (latest.directory || latest.size <= 0) {
            throw const AppFailure('远程视频不可用。');
          }
          total = latest.size;
          start = 0;
          continue;
        }
        handedOff = true;
        return _DownloadTransfer(
          start,
          total,
          response.timeout(_downloadTimeout),
          validatorKind: validator?.$1,
          validator: validator?.$2,
        );
      } finally {
        if (!handedOff) {
          client.close(force: true);
          if (identical(attempt.transferClient, client)) {
            attempt.transferClient = null;
          }
        }
      }
    }
    throw const AppFailure('视频发生变化，请重试下载。');
  }

  Future<void> _remove(String id) async {
    final row = rows[id];
    if (row == null) return;
    deleting.add(id);
    try {
      final attempt = running[id];
      attempt?.stop();
      await attempt?.done;
      final path = row['localPath'] as String;
      if (path.isNotEmpty) {
        for (final file in [path, '$path.part']) {
          if (!await _safeManagedPath(file)) {
            throw const AppFailure('下载路径不可用，未删除文件。');
          }
          final type = await FileSystemEntity.type(file, followLinks: false);
          if (type == FileSystemEntityType.file) await File(file).delete();
        }
      }
      _deleteFolderState(id);
      db!.execute('DELETE FROM downloads WHERE id=?', [id]);
      rows.remove(id);
      if (!closing) reply.send(['removed', id]);
    } finally {
      deleting.remove(id);
      _pump();
    }
  }

  /// Never follow an injected symlink outside the managed directory, including
  /// when deleting or checking a completed download after a restart.
  Future<bool> _safeManagedPath(String path) async {
    if (!p.isWithin(
      p.normalize(p.absolute(root)),
      p.normalize(p.absolute(path)),
    )) {
      return false;
    }
    var cursor = p.normalize(p.absolute(path));
    final boundary = p.normalize(p.absolute(root));
    while (cursor != boundary) {
      if (await FileSystemEntity.type(cursor, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
      cursor = p.dirname(cursor);
    }
    return await FileSystemEntity.type(boundary, followLinks: false) !=
        FileSystemEntityType.link;
  }

  Future<void> _close() async {
    await writes;
    await Future.wait(running.values.map((e) => e.done!));
    db?.dispose();
    store?.dispose();
    commands.close();
    Isolate.exit(reply, ['closed']);
  }
}

String _downloadError(Object error) {
  if (error is AppFailure) return error.message;
  if (error is FileSystemException) return '无法写入下载目录，请检查剩余空间和权限。';
  if (error is TimeoutException) return '下载超时，请检查网络后重试。';
  return '下载失败，请检查网络和来源配置后重试。';
}

String _sourceIdentity(Map<String, dynamic> source) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          for (final key in [
            'kind',
            'host',
            'port',
            'share',
            'url',
            'user',
            'domain',
          ])
            source[key],
        ]),
      ),
    )
    .toString();

List<String> _checkedSegments(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  if (parts.any(
    (part) => part == '.' || part == '..' || part.contains('\u0000'),
  )) {
    throw const AppFailure('视频路径无效。');
  }
  return parts;
}

String _safeSegment(String segment) {
  final escaped = segment.replaceAllMapped(
    RegExp(r'[%<>:"/\\|?*\x00-\x1f\x7f]'),
    (m) => utf8
        .encode(m[0]!)
        .map((b) => '%${b.toRadixString(16).padLeft(2, '0')}')
        .join(),
  );
  var value = escaped.replaceAllMapped(
    RegExp(r'[ .]+$'),
    (m) => m[0]!.codeUnits.map((b) => '%${b.toRadixString(16)}').join(),
  );
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(value)) {
    value = '%${value.codeUnitAt(0).toRadixString(16)}${value.substring(1)}';
  }
  if (utf8.encode(value).length > 200) {
    value =
        '${value.substring(0, value.length.clamp(0, 60))}-${sha256.convert(utf8.encode(value)).toString().substring(0, 20)}${p.extension(value).substring(0, p.extension(value).length.clamp(0, 12))}';
  }
  return value;
}

String _downloadPath(
  String root,
  String sourceId,
  String remotePath,
  String name,
  Map<String, dynamic> configuration, {
  String? downloadRoot,
  String? downloadRelativePath,
}) {
  if (downloadRoot != null && downloadRelativePath != null) {
    final namespace = sha256
        .convert(utf8.encode(jsonEncode([sourceId, downloadRoot])))
        .toString()
        .substring(0, 20);
    return p.joinAll([
      root,
      namespace,
      ..._checkedSegments(downloadRelativePath).map(_safeSegment),
    ]);
  }
  var parts = _checkedSegments(remotePath);
  if (configuration['kind'] == 'webdav') {
    final base = Uri.parse(configuration['url'] as String);
    if (!remotePath.startsWith('/')) {
      parts = [..._checkedSegments(Uri.decodeComponent(base.path)), ...parts];
    }
  } else if (configuration['kind'] == 'smb' &&
      (configuration['share'] as String? ?? '').isNotEmpty) {
    parts = [..._checkedSegments(configuration['share'] as String), ...parts];
  } else if (configuration['kind'] == 'http') {
    final url = Uri.parse(configuration['url'] as String);
    parts = _checkedSegments(Uri.decodeComponent(url.path));
    if (parts.isEmpty || !isVideo(parts.last)) {
      parts.add(isVideo(name) ? name : 'video.mp4');
    }
  }
  if (parts.isEmpty) parts = [name];
  final namespace = sha256
      .convert(utf8.encode(sourceId))
      .toString()
      .substring(0, 20);
  return p.joinAll([root, namespace, ...parts.map(_safeSegment)]);
}
