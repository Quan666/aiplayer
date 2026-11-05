import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/file_open.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/text_document.dart';
import '../sources/source.dart';
import 'glass.dart';

/// Resolve credentials only for the selected file, never while building rows.
Future<void> openSourceDocument(
  BuildContext context, {
  required AppModel model,
  required String sourceId,
  required SourceEntry entry,
  Map<String, dynamic>? source,
  bool external = false,
}) async {
  final downloaded = sourceId == 'local'
      ? null
      : model.downloads.entryForSource(sourceId, entry.path);
  if (downloaded?.isComplete == true) {
    return openSourceDocument(
      context,
      model: model,
      sourceId: 'local',
      entry: SourceEntry(
        name: entry.name,
        path: downloaded!.localPath,
        size: entry.size,
        modified: entry.modified,
      ),
      external: external,
    );
  }
  Map<String, dynamic>? configuration() => sourceId == 'local'
      ? const {'id': 'local', 'kind': 'local'}
      : model.sources.where((s) => s['id'] == sourceId).firstOrNull ??
            (model.store.local('externalSource:$sourceId') is Map
                ? Map<String, dynamic>.from(
                    model.store.local('externalSource:$sourceId'),
                  )
                : null);
  final selected = configuration();
  final resolved = selected ?? source;
  if (resolved == null) throw const AppFailure('来源未配置，请重新关联文件位置。');
  final attempt = _DocumentOpenAttempt();
  Future<void>? route;
  try {
    final password = sourceId == 'local'
        ? ''
        : await model.secrets.read(key: 'source:$sourceId') ?? '';
    if (!context.mounted ||
        attempt.cancelled ||
        !(ModalRoute.of(context)?.isCurrent ?? true) ||
        !TickerMode.valuesOf(context).enabled ||
        !mapEquals(selected, configuration())) {
      return;
    }
    route = Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => external
            ? ExternalFilePage(
                source: resolved,
                password: password,
                documentsPath: model.documents.path,
                entry: entry,
                externalCacheBytes: () =>
                    model.preferences.externalFileCacheBytes,
              )
            : TextFilePage(
                source: resolved,
                password: password,
                documentsPath: model.documents.path,
                entry: entry,
                externalCacheBytes: () =>
                    model.preferences.externalFileCacheBytes,
              ),
      ),
    );
  } finally {
    attempt.dispose();
  }
  await route;
}

bool _backgrounded(AppLifecycleState? state) =>
    state == AppLifecycleState.hidden ||
    state == AppLifecycleState.paused ||
    state == AppLifecycleState.detached;

class _DocumentOpenAttempt with WidgetsBindingObserver {
  bool cancelled = _backgrounded(WidgetsBinding.instance.lifecycleState);
  _DocumentOpenAttempt() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_backgrounded(state)) cancelled = true;
  }

  void dispose() => WidgetsBinding.instance.removeObserver(this);
}

class TextFilePage extends StatefulWidget {
  final Map<String, dynamic> source;
  final String password, documentsPath;
  final SourceEntry entry;
  final int Function()? externalCacheBytes;

  const TextFilePage({
    super.key,
    required this.source,
    this.password = '',
    required this.documentsPath,
    required this.entry,
    this.externalCacheBytes,
  });

  @override
  State<TextFilePage> createState() => _TextFilePageState();
}

class _TextFilePageState extends State<TextFilePage>
    with WidgetsBindingObserver {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _horizontal = ScrollController();
  final _searchFocus = FocusNode();
  TextDocumentService? _service;
  TextDocumentSnapshot? _document;
  List<TextMatch> _matches = const [];
  Map<int, List<TextMatch>> _matchesByRow = const {};
  Timer? _debounce;
  String? _error;
  String _searchedQuery = '';
  int _revision = 0, _currentMatch = 0;
  bool _searchVisible = false, _searching = false, _truncated = false;
  bool _paused = false, _reload = false, _searchPending = false;
  bool _visible = true;
  double _rowHeight = 22;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _paused = _backgrounded(WidgetsBinding.instance.lifecycleState);
    if (_paused) {
      _reload = true;
    } else {
      unawaited(_load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (_visible == visible) return;
    _visible = visible;
    if (!visible) {
      _suspend();
    } else if (!_paused && _reload) {
      unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final paused = _backgrounded(state);
    if (paused && !_paused) {
      _paused = true;
      _suspend();
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      if (_visible && _reload) unawaited(_load());
    }
  }

  void _suspend() {
    _debounce?.cancel();
    _revision++;
    _service?.dispose();
    _service = null;
    _searching = false;
    _reload = true;
    for (final controller in [_scroll, _horizontal]) {
      if (controller.hasClients) {
        final position = controller.position;
        if (position is ScrollPositionWithSingleContext) position.goIdle();
      }
    }
  }

  Future<void> _load() async {
    final revision = ++_revision;
    _reload = false;
    _service?.dispose();
    final service = _service = TextDocumentService(
      source: widget.source,
      password: widget.password,
      documentsPath: widget.documentsPath,
    );
    try {
      final document = await service.load(widget.entry);
      if (!mounted || _paused || !_visible || revision != _revision) return;
      setState(() {
        _document = document;
        _matches = const [];
        _matchesByRow = const {};
        _error = null;
      });
      _searchPending = true;
      await _search();
    } on Cancelled {
      // Closing/backgrounding revokes the whole worker, including late replies.
    } catch (error) {
      if (mounted && !_paused && revision == _revision) {
        setState(() => _error = safeFailure(error).message);
      }
    }
  }

  void _queryChanged(String value) {
    _debounce?.cancel();
    _searchPending = true;
    // One search in flight; subsequent edits replace the pending query.
    _debounce = Timer(const Duration(milliseconds: 200), _search);
  }

  Future<void> _search() async {
    final service = _service;
    if (_paused ||
        !_visible ||
        _searching ||
        service == null ||
        _document == null) {
      return;
    }
    final revision = _revision;
    _searching = true;
    try {
      while (_searchPending && mounted && !_paused && revision == _revision) {
        _searchPending = false;
        final query = _query.text;
        final result = await service.search(query);
        if (!mounted || _paused || revision != _revision) return;
        if (query != _query.text) {
          _searchPending = true;
          continue;
        }
        final queryChanged = _searchedQuery != query;
        setState(() {
          _matches = result.matches;
          _matchesByRow = result.matchesByRow;
          _searchedQuery = query;
          _currentMatch = queryChanged || _matches.isEmpty
              ? 0
              : _currentMatch.clamp(0, _matches.length - 1);
          _truncated = result.truncated;
        });
        if (queryChanged && _matches.isNotEmpty) _jumpToMatch();
      }
    } on Cancelled {
      // Lifecycle cancellation is synchronous and does not require a frame.
    } catch (error) {
      if (mounted && !_paused && revision == _revision) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeFailure(error).message)));
      }
    } finally {
      if (revision == _revision) _searching = false;
    }
  }

  void _jumpToMatch([int delta = 0]) {
    if (_matches.isEmpty || !_scroll.hasClients) return;
    setState(() => _currentMatch = (_currentMatch + delta) % _matches.length);
    final match = _matches[_currentMatch];
    _scroll.jumpTo(
      (match.row * _rowHeight).clamp(0.0, _scroll.position.maxScrollExtent),
    );
    if (_horizontal.hasClients) {
      final text = _document!.lines[match.row];
      final prefix = text.substring(0, match.start);
      final painter = TextPainter(
        text: TextSpan(
          text: prefix,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final offset = painter.width - _horizontal.position.viewportDimension / 4;
      painter.dispose();
      _horizontal.jumpTo(
        offset.clamp(0.0, _horizontal.position.maxScrollExtent),
      );
    }
  }

  void _toggleSearch() {
    setState(() => _searchVisible = !_searchVisible);
    if (_searchVisible) {
      _searchFocus.requestFocus();
    } else {
      _searchFocus.unfocus();
      _query.clear();
      _queryChanged('');
    }
  }

  Future<void> _openExternally() => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => ExternalFilePage(
        source: widget.source,
        password: widget.password,
        documentsPath: widget.documentsPath,
        entry: widget.entry,
        externalCacheBytes: widget.externalCacheBytes,
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _service?.dispose();
    _revision++;
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final colors = GlassPalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    _rowHeight = 22 * scale;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          if (!_searchVisible) _toggleSearch();
          _searchFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          if (!_searchVisible) _toggleSearch();
          _searchFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchVisible) _toggleSearch();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: 48,
            title: Text(
              widget.entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: '搜索内容',
                onPressed: _toggleSearch,
                icon: const Icon(Icons.search_rounded, size: 22),
              ),
              IconButton(
                tooltip: '用其他应用打开',
                onPressed: _openExternally,
                icon: const Icon(Icons.open_in_new_rounded, size: 20),
              ),
            ],
          ),
          body: Column(
            children: [
              if (_searchVisible)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 4, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _query,
                          focusNode: _searchFocus,
                          onChanged: _queryChanged,
                          onSubmitted: (_) => _jumpToMatch(1),
                          textInputAction: TextInputAction.search,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '搜索内容',
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          _searchedQuery != _query.text
                              ? '…'
                              : '${_matches.isEmpty ? 0 : _currentMatch + 1}/${_matches.length}${_truncated ? '+' : ''}',
                          key: const ValueKey('text-search-count'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      IconButton(
                        tooltip: '上一个匹配',
                        visualDensity: VisualDensity.compact,
                        onPressed: _matches.isEmpty
                            ? null
                            : () => _jumpToMatch(-1),
                        icon: const Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 22,
                        ),
                      ),
                      IconButton(
                        tooltip: '下一个匹配',
                        visualDensity: VisualDensity.compact,
                        onPressed: _matches.isEmpty
                            ? null
                            : () => _jumpToMatch(1),
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: _openExternally,
                                child: const Text('用其他应用打开'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : document == null
                    ? const Center(child: _FileLoading())
                    : LayoutBuilder(
                        builder: (context, constraints) => Scrollbar(
                          controller: _horizontal,
                          notificationPredicate: (notification) =>
                              notification.metrics.axis == Axis.horizontal,
                          child: SingleChildScrollView(
                            controller: _horizontal,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: math.max(
                                constraints.maxWidth,
                                document.maxColumns * 14.0 * scale + 32,
                              ),
                              child: SelectionArea(
                                child: Scrollbar(
                                  controller: _scroll,
                                  child: ListView.builder(
                                    key: const ValueKey('text-document-lines'),
                                    controller: _scroll,
                                    itemExtent: _rowHeight,
                                    padding: EdgeInsets.fromLTRB(
                                      12,
                                      0,
                                      12,
                                      MediaQuery.paddingOf(context).bottom + 20,
                                    ),
                                    itemCount: document.lines.length,
                                    itemBuilder: (context, row) {
                                      final text = document.lines[row];
                                      final matches =
                                          _matchesByRow[row] ??
                                          const <TextMatch>[];
                                      final spans = <InlineSpan>[];
                                      var position = 0;
                                      for (final match in matches) {
                                        if (match.start < position) continue;
                                        spans.add(
                                          TextSpan(
                                            text: text.substring(
                                              position,
                                              match.start,
                                            ),
                                          ),
                                        );
                                        spans.add(
                                          TextSpan(
                                            text: text.substring(
                                              match.start,
                                              match.end,
                                            ),
                                            style: TextStyle(
                                              backgroundColor: colors.accent
                                                  .withValues(
                                                    alpha:
                                                        match.id ==
                                                            _matches[_currentMatch]
                                                                .id
                                                        ? .45
                                                        : .2,
                                                  ),
                                            ),
                                          ),
                                        );
                                        position = match.end;
                                      }
                                      spans.add(
                                        TextSpan(
                                          text: text.substring(position),
                                        ),
                                      );
                                      return Text.rich(
                                        TextSpan(children: spans),
                                        key: ValueKey('text-line:$row'),
                                        softWrap: false,
                                        maxLines: 1,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 14,
                                          height: 1.4,
                                          color: colors.text,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExternalFilePage extends StatefulWidget {
  final Map<String, dynamic> source;
  final String password, documentsPath;
  final SourceEntry entry;
  final int Function()? externalCacheBytes;
  @visibleForTesting
  final Future<void> Function(String)? opener;

  const ExternalFilePage({
    super.key,
    required this.source,
    this.password = '',
    required this.documentsPath,
    required this.entry,
    this.externalCacheBytes,
    this.opener,
  });

  @override
  State<ExternalFilePage> createState() => _ExternalFilePageState();
}

class _ExternalFilePageState extends State<ExternalFilePage>
    with WidgetsBindingObserver {
  TextDocumentService? _service;
  String? _prepared, _error;
  int _revision = 0;
  bool _handedOff = false, _opening = false, _paused = false, _visible = true;

  bool get _local =>
      widget.source['kind'] == 'local' || widget.source['id'] == 'local';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _paused = _backgrounded(WidgetsBinding.instance.lifecycleState);
    if (!_paused) unawaited(_open());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = ModalRoute.isCurrentOf(context) ?? true;
    if (_visible == visible) return;
    _visible = visible;
    if (!visible && !_handedOff) {
      _cancel();
    } else if (!visible && _handedOff) {
      unawaited(cancelPendingExternalFileOpen());
    } else if (visible && !_paused && !_handedOff && _error == null) {
      unawaited(_open());
    }
  }

  void _cancel() {
    _revision++;
    unawaited(cancelPendingExternalFileOpen());
    _service?.dispose();
    _service = null;
    _opening = false;
    final path = _prepared;
    _prepared = null;
    if (!_handedOff && path != null) unawaited(discardExternalFile(path));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_backgrounded(state)) {
      _paused = true;
      if (!_handedOff) {
        _cancel();
      } else {
        unawaited(cancelPendingExternalFileOpen());
      }
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      if (_visible && !_handedOff && _error == null) unawaited(_open());
    }
  }

  Future<void> _open() async {
    if (_opening || _paused || !_visible) return;
    _opening = true;
    final revision = ++_revision;
    final service = _service = TextDocumentService(
      source: widget.source,
      password: widget.password,
      documentsPath: widget.documentsPath,
    );
    String? prepared;
    try {
      var path = widget.entry.path;
      if (!_local) {
        final temporary = await getTemporaryDirectory();
        if (!mounted || _paused || !_visible || revision != _revision) return;
        path = await service.prepareExternal(
          widget.entry,
          cacheDirectory: p.join(temporary.path, 'aiplayer-external-files-v1'),
          maxCacheBytes: widget.externalCacheBytes?.call() ?? 512 * 1024 * 1024,
        );
        prepared = path;
      }
      if (!mounted || _paused || !_visible || revision != _revision) {
        if (!_local) await discardExternalFile(path);
        return;
      }
      _prepared = prepared;
      // The receiving application may read after this future completes. Keep
      // its lease in the bounded cache; failures/cancellations release at once.
      _handedOff = true;
      await (widget.opener ?? openExternalFile)(path);
      if (mounted && revision == _revision) {
        final route = ModalRoute.of(context);
        if (route?.isCurrent ?? false) {
          if (Navigator.canPop(context)) Navigator.pop(context);
        } else if (route != null) {
          Navigator.of(context).removeRoute(route);
        }
      }
    } catch (error) {
      if (revision == _revision) {
        _handedOff = false;
        _prepared = null;
      }
      if (prepared != null) await discardExternalFile(prepared);
      if (mounted && !_paused && revision == _revision) {
        setState(() => _error = safeFailure(error).message);
      }
    } finally {
      service.dispose();
      if (revision == _revision) _opening = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(toolbarHeight: 48, title: Text(widget.entry.name)),
    body: Center(
      child: _error == null
          ? const _FileLoading()
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
    ),
  );
}

class _FileLoading extends StatefulWidget {
  const _FileLoading();

  @override
  State<_FileLoading> createState() => _FileLoadingState();
}

class _FileLoadingState extends State<_FileLoading>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  bool _foreground = false, _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled &&
        MotionScope.enabledOf(context);
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  void _update() {
    if (_foreground && _visible) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: RotationTransition(
      turns: _rotation,
      child: const SizedBox.square(
        dimension: 28,
        child: CircularProgressIndicator(
          value: .7,
          strokeWidth: 2.5,
          semanticsLabel: '正在读取文件',
        ),
      ),
    ),
  );
}
