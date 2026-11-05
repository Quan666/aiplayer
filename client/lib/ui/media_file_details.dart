import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/media_file_details.dart';
import '../data/media_technical_info.dart';
import '../data/store.dart';
import '../sources/source.dart';
import 'glass.dart';
import 'artwork_lifecycle.dart';

typedef MediaFileDetailsLoader = Future<MediaFileDetails> Function(CancelToken);

Future<void> showMediaFileDetails(
  BuildContext context, {
  required AppModel model,
  SyncRecord? item,
  String? sourceId,
  SourceEntry? entry,
  String sourceName = '',
}) async {
  Future<MediaFileDetails> load(CancelToken cancel) async {
    // A brief background/foreground transition may return while the previous
    // native probe is still closing. Share its completion signal, with a
    // cancellable deadline, instead of turning that short overlap into an error.
    final service = MediaFileDetailsService.instance;
    await service.waitUntilIdle(cancel);
    cancel.check();
    final stored = item == null
        ? null
        : await model.playbackLocation(item) ??
              model.store.local('browse:${item.id}');
    cancel.check();
    final location = stored is Map ? stored : const {};
    final offline = location['offline'] == true;
    final source =
        (offline ? null : sourceId) ?? location['source'] as String? ?? '';
    final path =
        (offline ? null : entry?.path) ?? location['path'] as String? ?? '';
    if (source.isEmpty || path.isEmpty) {
      throw const AppFailure('尚未关联视频文件，请先关联视频位置。');
    }
    cancel.check();
    return service.inspect(
      openSource: () => model.adapter(source),
      path: path,
      cancel: cancel,
      fileName: entry?.name ?? '${item?.data['fileName'] ?? ''}',
      sourceName: source == 'local' ? '本地视频' : sourceName,
    );
  }

  Object revision() => (
    model.store.localKeyRevision('sources'),
    item == null ? null : model.store.localKeyRevision('location:${item.id}'),
    item == null ? null : model.store.localKeyRevision('browse:${item.id}'),
    model.store.localPrefixRevision('externalSource:'),
    model.downloads.completedRevision,
  );

  await showGlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => MediaFileDetailsSheet(
      invalidation: model,
      revision: revision,
      load: load,
    ),
  );
}

/// Opens immediately; only an explicitly opened sheet starts a file probe.
class MediaFileDetailsSheet extends StatefulWidget {
  final MediaFileDetailsLoader load;
  final Listenable? invalidation;
  final Object Function()? revision;

  const MediaFileDetailsSheet({
    super.key,
    required this.load,
    this.invalidation,
    this.revision,
  });

  @override
  State<MediaFileDetailsSheet> createState() => _MediaFileDetailsSheetState();
}

class _MediaFileDetailsSheetState extends State<MediaFileDetailsSheet>
    with WidgetsBindingObserver {
  CancelToken? _cancel;
  MediaFileDetails? _details;
  String? _error;
  Object? _revision;
  bool _visible = false, _foreground = true, _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _revision = widget.revision?.call();
    widget.invalidation?.addListener(_invalidated);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _updateActivity();
  }

  @override
  void didUpdateWidget(covariant MediaFileDetailsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.invalidation != widget.invalidation) {
      oldWidget.invalidation?.removeListener(_invalidated);
      widget.invalidation?.addListener(_invalidated);
    }
    if (oldWidget.load != widget.load) {
      _cancel?.cancel();
      _cancel = null;
      _details = null;
      _error = null;
      _started = false;
      _revision = widget.revision?.call();
      _updateActivity();
    }
  }

  void _invalidated() {
    final revision = widget.revision?.call();
    if (revision == _revision) return;
    _revision = revision;
    _cancel?.cancel();
    _cancel = null;
    setState(() {
      _details = null;
      _error = '文件位置或来源已更新，请重新读取。';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateActivity();
  }

  void _updateActivity() {
    if (!_visible || !_foreground) {
      if (_cancel != null) {
        _cancel!.cancel();
        _cancel = null;
        _started = false;
      }
      return;
    }
    if (!_started && _details == null && _error == null) {
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    final cancel = CancelToken();
    _cancel?.cancel();
    _cancel = cancel;
    _started = true;
    try {
      final details = await widget.load(cancel);
      if (!mounted || cancel.cancelled || _cancel != cancel) return;
      setState(() => _details = details);
    } catch (error) {
      if (!mounted || cancel.cancelled || _cancel != cancel) return;
      setState(() => _error = safeFailure(error).message);
    } finally {
      if (_cancel == cancel) _cancel = null;
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _details = null;
      _started = false;
    });
    _updateActivity();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    widget.invalidation?.removeListener(_invalidated);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return GlassSheetBody(
      key: const ValueKey('media-file-details'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '文件详情',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '关闭文件详情',
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Flexible(
            child: details != null
                ? _FileParameters(details: details)
                : Align(
                    heightFactor: 1,
                    child: _error == null
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_error!, textAlign: TextAlign.center),
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: _retry,
                                  child: const Text('重新读取'),
                                ),
                              ],
                            ),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FileParameters extends StatefulWidget {
  final MediaFileDetails details;
  const _FileParameters({required this.details});

  @override
  State<_FileParameters> createState() => _FileParametersState();
}

class _FileParametersState extends State<_FileParameters> {
  late List<MediaParameterSection> _sections, _moreSections;

  static const _trackFields = [
    '标题',
    '分辨率',
    '编码',
    '帧率',
    '码率',
    '语言',
    '声道布局',
    '声道数',
    '采样率',
  ];

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant _FileParameters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.details != widget.details) _prepare();
  }

  void _prepare() {
    final details = widget.details;
    _sections = [
      MediaParameterSection(
        values: {
          '文件名': details.fileName,
          if (details.format.isNotEmpty) '格式': details.format,
          if (details.size > 0) '大小': mediaFileSize(details.size),
          if (details.properties['时长'] case final String duration)
            '时长': duration,
        },
      ),
    ];
    _moreSections = [
      MediaParameterSection(
        title: '文件',
        values: {
          if (details.sourceName.isNotEmpty) '来源': details.sourceName,
          if (details.modified > 0)
            '修改时间': DateTime.fromMillisecondsSinceEpoch(details.modified)
                .toLocal()
                .toIso8601String()
                .split('.')
                .first
                .replaceFirst('T', ' '),
          if (details.size > 0) '字节数': '${details.size}',
          '支持定位': details.seekable ? '是' : '否',
        },
      ),
      MediaParameterSection(values: details.properties, omit: const {'时长'}),
    ];
    for (final track in details.tracks) {
      final title =
          '${switch (track.type) {
            'video' => '视频',
            'audio' => '音频',
            'sub' => '字幕',
            _ => track.type,
          }}轨道 ${track.id}';
      // Only read the small fixed set of common fields here. Raw metadata stays
      // in its worker-prepared map and is built lazily after expanding More.
      _sections.add(
        MediaParameterSection(
          title: title,
          values: {
            for (final key in _trackFields)
              if (track.properties[key] case final String value) key: value,
          },
        ),
      );
      _moreSections.addAll([
        MediaParameterSection(
          title: title,
          values: track.properties,
          omit: const {..._trackFields},
        ),
        MediaParameterSection(values: track.metadata),
      ]);
    }
    _moreSections.add(
      MediaParameterSection(title: '元数据', values: details.metadata),
    );
  }

  @override
  Widget build(BuildContext context) => MediaFileParameterList(
    key: const ValueKey('file-parameter-list'),
    sections: _sections,
    moreSections: _moreSections,
  );
}

/// A view over prepared metadata. Exclusions are a small fixed set, so opening
/// a sheet never scans or copies all raw tags on the UI isolate.
class MediaParameterSection {
  final String title;
  final Map<String, String> values;
  final Set<String> omit;
  const MediaParameterSection({
    this.title = '',
    required this.values,
    this.omit = const {},
  });

  int get length => values.length - omit.where(values.containsKey).length;
}

/// Shared, compact photo/video parameters with a finite lazy viewport. The
/// expanded section uses the same list instead of nesting eager scroll views.
class MediaFileParameterList extends StatefulWidget {
  final List<MediaParameterSection> sections, moreSections;
  const MediaFileParameterList({
    super.key,
    required this.sections,
    this.moreSections = const [],
  });

  @override
  State<MediaFileParameterList> createState() => _MediaFileParameterListState();
}

// A sheet batches its raw sections into one bounded worker request. Only ordered
// keys come back; values stay in the existing snapshot and row lookup is O(1).
List<List<String>> _indexMediaParameterKeys(
  List<(Map<String, String>, Set<String>)> sections,
) => [
  for (final (values, omit) in sections)
    [
      for (final key in values.keys)
        if (!omit.contains(key)) key,
    ],
];

class _MediaFileParameterListState extends State<MediaFileParameterList> {
  bool _expanded = false, _indexing = false, _indexError = false;
  bool _visible = false;
  int _revision = 0;
  final _groups = <({MediaParameterSection section, List<String> keys})>[];
  final _ends = <int>[];
  final _keys =
      Map<
        Map<String, String>,
        List<({Set<String> omit, List<String> keys})>
      >.identity();
  int _moreIndex = -1, _loadingIndex = -1, _itemCount = 0;

  bool get _active => mounted && _visible && ArtworkLifecycle.instance.value;

  @override
  void initState() {
    super.initState();
    ArtworkLifecycle.instance.addListener(_activityChanged);
    _prepare();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _activityChanged();
  }

  void _activityChanged() {
    if (_active) unawaited(_indexMissing());
  }

  @override
  void didUpdateWidget(covariant MediaFileParameterList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sections != widget.sections ||
        oldWidget.moreSections != widget.moreSections) {
      _revision++;
      _indexError = false;
      final retained = Set<Map<String, String>>.identity()
        ..addAll(widget.sections.map((section) => section.values))
        ..addAll(widget.moreSections.map((section) => section.values));
      _keys.removeWhere((values, _) => !retained.contains(values));
      _prepare();
    }
  }

  List<String>? _cachedKeys(MediaParameterSection section) {
    for (final cached in _keys[section.values] ?? const []) {
      if (setEquals(cached.omit, section.omit)) return cached.keys;
    }
    // Common summaries have a small fixed set of fields. Bound this synchronous
    // preparation explicitly; large raw maps are indexed only by the worker.
    if (section.values.length <= 16) {
      final keys = [
        for (final key in section.values.keys)
          if (!section.omit.contains(key)) key,
      ];
      _cacheKeys(section, keys);
      return keys;
    }
    return null;
  }

  void _cacheKeys(MediaParameterSection section, List<String> keys) {
    (_keys[section.values] ??= []).add((
      omit: Set.unmodifiable(section.omit),
      keys: keys,
    ));
  }

  Future<void> _indexMissing() async {
    if (_indexing || _indexError || !_active) return;
    final pending = [
      for (final section in widget.sections)
        if (_cachedKeys(section) == null) section,
      if (_expanded)
        for (final section in widget.moreSections)
          if (_cachedKeys(section) == null) section,
    ];
    if (pending.isEmpty) return;
    _indexing = true;
    final revision = _revision;
    try {
      final indexed = await compute(_indexMediaParameterKeys, [
        for (final section in pending) (section.values, section.omit),
      ]);
      if (!mounted || revision != _revision) return;
      for (var i = 0; i < pending.length; i++) {
        _cacheKeys(pending[i], indexed[i]);
      }
      setState(_prepare);
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _indexError = true);
      }
    } finally {
      _indexing = false;
      // A changed snapshot replaces the previous attempt; at most one worker
      // runs at once, and hidden/background sheets never enqueue a replacement.
      if (mounted && revision != _revision) _activityChanged();
    }
  }

  void _prepare() {
    _groups.clear();
    _ends.clear();
    _moreIndex = -1;
    _loadingIndex = -1;
    var end = 0;
    var waiting = false;
    void add(MediaParameterSection section) {
      if (section.length == 0) return;
      final keys = _cachedKeys(section);
      if (keys == null) {
        waiting = true;
        return;
      }
      _groups.add((section: section, keys: keys));
      end += keys.length + (section.title.isEmpty ? 0 : 1);
      _ends.add(end);
    }

    for (final section in widget.sections) {
      add(section);
    }
    if (widget.moreSections.any((section) => section.length > 0)) {
      _moreIndex = end++;
      if (_expanded) {
        for (final section in widget.moreSections) {
          add(section);
        }
      }
    }
    if (waiting) _loadingIndex = end++;
    _itemCount = end;
    _activityChanged();
  }

  @override
  void dispose() {
    _revision++;
    ArtworkLifecycle.instance.removeListener(_activityChanged);
    super.dispose();
  }

  ({String label, String? value}) _row(int index) {
    var low = 0, high = _ends.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_ends[mid] <= index) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final indexed = _groups[low];
    final group = indexed.section;
    var offset = index - (low == 0 ? 0 : _ends[low - 1]);
    if (_moreIndex >= 0 &&
        index > _moreIndex &&
        (low == 0 || _ends[low - 1] <= _moreIndex)) {
      offset--;
    }
    if (group.title.isNotEmpty) {
      if (offset == 0) return (label: group.title, value: null);
      offset--;
    }
    final key = indexed.keys[offset];
    return (label: key, value: group.values[key]!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = GlassPalette.of(context);
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      itemCount: _itemCount,
      itemBuilder: (context, index) {
        if (index == _loadingIndex) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: _indexError
                ? TextButton(
                    onPressed: () => setState(() {
                      _indexError = false;
                      _prepare();
                    }),
                    child: const Text('重新读取参数'),
                  )
                : const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '读取参数…',
                      key: ValueKey('media-parameters-indexing'),
                    ),
                  ),
          );
        }
        if (index == _moreIndex) {
          return Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('media-parameters-more'),
              onPressed: () => setState(() {
                _expanded = !_expanded;
                _prepare();
              }),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(48, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(
                _expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
              ),
              label: Text(_expanded ? '收起更多' : '更多'),
            ),
          );
        }
        final row = _row(index);
        if (row.value == null) {
          return Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 5),
            child: Text(
              row.label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 84,
                child: Text(
                  row.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  row.value!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
