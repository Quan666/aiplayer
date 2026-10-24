part of 'sync.dart';

class _SyncWorkerRequest {
  final String path, address, token;
  final bool withProfile, sharedOnly, deferProfile, recoverMissingCredentials;
  final Set<String> artworkIds;
  final String? localCredentialDocuments,
      artworkDocuments,
      artworkCache,
      deviceName;

  const _SyncWorkerRequest({
    required this.path,
    required this.address,
    required this.token,
    required this.withProfile,
    required this.sharedOnly,
    required this.artworkIds,
    required this.deferProfile,
    required this.recoverMissingCredentials,
    this.localCredentialDocuments,
    this.artworkDocuments,
    this.artworkCache,
    this.deviceName,
  });
}

void _applyDeviceName(AppStore store, String name) {
  store.setLocal('syncDevice:name', name);
  // Updating pending provenance can touch the whole catalogue. Keep that
  // SQLite work in the same worker as the snapshot it describes.
  store.db.execute(
    'UPDATE records SET device_name=? WHERE dirty=1 AND device_id=?',
    [name, store.deviceId],
  );
}

/// One worker and SQLite connection per client. Frequent shared syncs reuse
/// prepared statements and the bounded encoded-artwork cache; idle clients
/// release native resources without requiring another app event.
class _SyncWorkerSession {
  final FlutterSecureStorage? secrets;
  final ValueChanged<String>? onPosterChanged;
  final _messages = ReceivePort(),
      _errors = ReceivePort(),
      _exit = ReceivePort();
  final _ready = Completer<SendPort>(), _exited = Completer<void>();
  Completer<int>? _job;
  CancelToken? _activeCancel;
  SendPort? _commands;
  Timer? _idle;
  int _jobId = 0;
  bool closed = false;

  _SyncWorkerSession(this.secrets, {this.onPosterChanged}) {
    _messages.listen((message) {
      if (message is SendPort) {
        _commands = message;
        _ready.complete(message);
        if (closed) message.send(['close']);
      } else if (message is List && message[0] == 'result') {
        if (message[1] == _jobId && _job?.isCompleted == false) {
          _job!.complete(message[2] as int);
        }
      } else if (message is List && message[0] == 'failure') {
        if (message[1] == _jobId && _job?.isCompleted == false) {
          _job!.completeError(
            message[2] == 'cancelled'
                ? const Cancelled()
                : AppFailure(message[3] as String, message[4] as int?),
          );
        }
      } else if (message is List && message[0] == 'posterChanged') {
        if (!closed) onPosterChanged?.call(message[1] as String);
      } else if (message is List && message.length == 4) {
        unawaited(_serveCredentialRequest(message, secrets, _activeCancel));
      }
    });
    _errors.listen((_) => _fail(const AppFailure('同步后台任务异常结束，请重试。')));
    _exit.listen((_) {
      _fail(closed ? const Cancelled() : const AppFailure('同步后台任务意外退出，请重试。'));
      _messages.close();
      _errors.close();
      _exit.close();
      if (!_exited.isCompleted) _exited.complete();
    });
    unawaited(
      Isolate.spawn(
            _syncWorkerMain,
            [_messages.sendPort, ServicesBinding.rootIsolateToken],
            onError: _errors.sendPort,
            onExit: _exit.sendPort,
          )
          .catchError((Object error) {
            _fail(const AppFailure('无法启动同步后台任务，请重试。'));
            _messages.close();
            _errors.close();
            _exit.close();
            if (!_exited.isCompleted) _exited.complete();
            throw error;
          })
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _fail(AppFailure error) {
    closed = true;
    _idle?.cancel();
    if (!_ready.isCompleted) _ready.completeError(error);
    if (_job?.isCompleted == false) _job!.completeError(error);
  }

  Future<int> run(_SyncWorkerRequest request, CancelToken? cancel) async {
    _idle?.cancel();
    final commands = await _ready.future;
    if (closed) throw const Cancelled();
    cancel?.check();
    final id = ++_jobId;
    final ownCancel = _activeCancel = CancelToken();
    final result = _job = Completer<int>();
    commands.send(['run', id, request]);
    unawaited(
      cancel?.whenCancelled.then((_) {
        if (_jobId == id && !result.isCompleted) {
          ownCancel.cancel();
          commands.send(['cancel', id]);
        }
      }),
    );
    try {
      return await result.future;
    } finally {
      if (identical(_job, result)) {
        _job = null;
        _activeCancel = null;
      }
      if (!closed) {
        _idle = Timer(const Duration(seconds: 15), () => unawaited(close()));
      }
    }
  }

  Future<void> close() {
    if (!closed) {
      closed = true;
      _idle?.cancel();
      _activeCancel?.cancel();
      _commands?.send(['close']);
    }
    return _exited.future;
  }
}

Future<void> _serveCredentialRequest(
  List message,
  FlutterSecureStorage? secrets,
  CancelToken? cancel,
) async {
  final response = message[3] as SendPort;
  try {
    cancel?.check();
    if (secrets == null) throw const AppFailure('安全凭据存储不可用。');
    final operation = message[0] as String;
    final key = message[1] as String;
    String? result;
    switch (operation) {
      case 'read':
        result = await secrets.read(key: key);
        AppLog.instance.rememberSecret(result);
      case 'write':
        final value = message[2] as String?;
        AppLog.instance.rememberSecret(value);
        await secrets.write(key: key, value: value);
      case 'delete':
        await secrets.delete(key: key);
      default:
        throw const AppFailure('安全凭据操作无效。');
    }
    response.send(['ok', result]);
  } catch (error) {
    response.send([
      error is Cancelled ? 'cancelled' : 'error',
      error is AppFailure ? error.message : '无法访问安全凭据，请检查设备凭据设置。',
      error is AppFailure ? error.status : null,
    ]);
  }
}

void _syncWorkerMain(List<Object?> startup) {
  final reply = startup[0] as SendPort;
  initializeSystemProxyWorker(startup[1] as RootIsolateToken?);
  final commands = ReceivePort();
  final state = _SyncWorkerState(reply);
  CancelToken? activeCancel;
  int? activeId;
  var closing = false;
  Future<void>? active;
  Future<void> close() async {
    if (closing) return;
    closing = true;
    activeCancel?.cancel();
    await active;
    await state.close();
    commands.close();
  }

  commands.listen((dynamic message) {
    final command = message as List;
    switch (command[0]) {
      case 'close':
        unawaited(close());
      case 'cancel':
        if (activeId == command[1]) activeCancel?.cancel();
      case 'run':
        final id = command[1] as int;
        if (closing || active != null) {
          reply.send(['failure', id, 'error', '同步后台任务忙，请重试。', null]);
          return;
        }
        final cancel = activeCancel = CancelToken();
        activeId = id;
        active = () async {
          try {
            final revision = await state.run(
              command[2] as _SyncWorkerRequest,
              cancel,
            );
            reply.send(['result', id, revision]);
          } catch (error) {
            final failure = error is AppFailure ? error : safeFailure(error);
            reply.send([
              'failure',
              id,
              error is Cancelled ? 'cancelled' : 'error',
              failure.message,
              failure.status,
            ]);
          } finally {
            active = null;
            activeId = null;
            activeCancel = null;
          }
        }();
    }
  });
  reply.send(commands.sendPort);
}

class _SyncWorkerState {
  final SendPort reply;
  AppStore? store;
  LocalCredentialStorage? localSecrets;
  PosterCache? posters;
  SyncArtwork? artwork;
  _SyncWorkerState(this.reply);

  Future<int> run(_SyncWorkerRequest request, CancelToken cancel) =>
      retryStoreBusy(() async {
        cancel.check();
        try {
          return await _run(request, cancel);
        } catch (_) {
          // SQLite can leave a failed prepared write active after BUSY. Do
          // not reuse that connection for a later transaction or request.
          _discardConnection();
          rethrow;
        }
      });

  Future<int> _run(_SyncWorkerRequest request, CancelToken cancel) async {
    final opened =
        store ??
        await retryStoreBusy<AppStore>(() {
          cancel.check();
          return AppStore.openExisting(request.path);
        });
    store = opened;
    // Short native waits let the worker receive cancellation while another
    // engine owns the writer lock. Retrying preserves the existing checkpoints.
    opened.db.execute('PRAGMA busy_timeout=25');
    if (request.deviceName != null) {
      await retryStoreBusy(() {
        cancel.check();
        _applyDeviceName(opened, request.deviceName!);
      });
    }
    final FlutterSecureStorage secrets;
    if (request.localCredentialDocuments != null) {
      secrets = localSecrets ??= LocalCredentialStorage(
        Directory(request.localCredentialDocuments!),
      );
    } else {
      secrets = _WorkerCredentialStorage(reply, cancel);
    }
    if (artwork == null &&
        request.artworkDocuments != null &&
        request.artworkCache != null) {
      final cache = posters = PosterCache(
        directory: Directory(request.artworkCache!),
      );
      artwork = SyncArtwork(
        opened,
        Directory(request.artworkDocuments!),
        cache,
        background: true,
        onPosterChanged: (url) => reply.send(['posterChanged', url]),
      );
    }
    final client = SyncClient(
      opened,
      transport: IoJsonTransport(),
      profile: request.withProfile
          ? SyncProfile(
              opened,
              secrets,
              watchedKey: mediaWatchedKey,
              artwork: artwork,
              recoverMissingCredentials: request.recoverMissingCredentials,
            )
          : null,
    ).._deviceRead = true;
    await client._synchronize(
      request.address,
      request.token,
      cancel: cancel,
      sharedOnly: request.sharedOnly,
      artworkIds: request.artworkIds,
      deferProfile: request.deferProfile,
      playbackOnly: false,
    );
    return client.profileRevision;
  }

  void _discardConnection() {
    posters?.close();
    posters = null;
    artwork = null;
    store?.dispose();
    store = null;
  }

  Future<void> close() async {
    _discardConnection();
    await localSecrets?.close();
  }
}

/// Platform storage stays on its owning isolate. Only individual credential
/// operations cross the port; profiles, JSON and ciphertext stay in the worker.
class _WorkerCredentialStorage extends FlutterSecureStorage {
  final SendPort parent;
  final CancelToken cancel;
  _WorkerCredentialStorage(this.parent, this.cancel);

  Future<String?> _request(
    String operation,
    String key, [
    String? value,
  ]) async {
    cancel.check();
    final response = ReceivePort();
    try {
      parent.send([operation, key, value, response.sendPort]);
      final result =
          await Future.any<dynamic>([
                response.first,
                cancel.whenCancelled.then((_) => throw const Cancelled()),
              ])
              as List;
      if (result[0] == 'cancelled') throw const Cancelled();
      if (result[0] != 'ok') throw AppFailure(result[1], result[2]);
      return result[1] as String?;
    } finally {
      response.close();
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _request('read', key);

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await _request('write', key, value);
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await _request('delete', key);
  }
}
