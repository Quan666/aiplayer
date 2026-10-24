import 'dart:async';

import 'package:flutter/material.dart';

import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/media_file_details.dart';
import '../data/media_technical_info.dart';
import '../data/store.dart';
import '../sources/source.dart';
import 'glass.dart';

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
        : model.store.local('location:${item.id}') ??
              model.store.local('browse:${item.id}');
    final location = stored is Map ? stored : const {};
    final source = sourceId ?? location['source'] as String? ?? '';
    final path = entry?.path ?? location['path'] as String? ?? '';
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
    return SizedBox(
      key: const ValueKey('media-file-details'),
      height: MediaQuery.sizeOf(context).height * .82,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '文件详情',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '关闭文件详情',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: details != null
                ? _FileParameters(details: details)
                : Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
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
  late List<({String title, List<Map<String, String>> values})> _groups;
  final _ends = <int>[];

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
    // Index section lengths only. Do not flatten or copy every metadata row
    // on the UI isolate; the worker has already prepared their display values.
    _groups = [
      (
        title: '文件',
        values: [
          {
            '文件名': details.fileName,
            if (details.sourceName.isNotEmpty) '来源': details.sourceName,
            '大小': '${mediaFileSize(details.size)}（${details.size} 字节）',
            if (details.format.isNotEmpty) '格式': details.format,
            if (details.modified > 0)
              '修改时间': DateTime.fromMillisecondsSinceEpoch(
                details.modified,
              ).toLocal().toString(),
            '支持定位': details.seekable ? '是' : '否',
          },
          details.properties,
        ],
      ),
      for (final track in details.tracks)
        (
          title:
              '${switch (track.type) {
                'video' => '视频',
                'audio' => '音频',
                'sub' => '字幕',
                _ => track.type,
              }}轨道 ${track.id}',
          values: [track.properties, track.metadata],
        ),
      if (details.metadata.isNotEmpty)
        (title: '元数据', values: [details.metadata]),
    ];
    _ends.clear();
    var end = 0;
    for (final group in _groups) {
      end++;
      for (final values in group.values) {
        end += values.length;
      }
      _ends.add(end);
    }
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
    final group = _groups[low];
    var offset = index - (low == 0 ? 0 : _ends[low - 1]);
    if (offset == 0) return (label: group.title, value: null);
    offset--;
    for (final values in group.values) {
      if (offset < values.length) {
        final entry = values.entries.elementAt(offset);
        return (label: entry.key, value: entry.value);
      }
      offset -= values.length;
    }
    throw RangeError.index(index, _ends);
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const ValueKey('file-parameter-list'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      itemCount: _ends.last,
      itemBuilder: (context, index) {
        final row = _row(index);
        if (row.value == null) {
          return Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              row.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 88,
                child: Text(
                  row.label,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(row.value!)),
            ],
          ),
        );
      },
    );
  }
}
