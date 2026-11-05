import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/album_catalog.dart';
import 'glass.dart';

Future<AlbumOptions?> showAlbumFilterSheet(
  BuildContext context, {
  required AlbumOptions initial,
  required AlbumSnapshot snapshot,
}) => showGlassBottomSheet<AlbumOptions>(
  context: context,
  isScrollControlled: true,
  builder: (_) => AlbumFilterSheet(initial: initial, snapshot: snapshot),
);

class AlbumFilterSheet extends StatefulWidget {
  final AlbumOptions initial;
  final AlbumSnapshot snapshot;
  const AlbumFilterSheet({
    super.key,
    required this.initial,
    required this.snapshot,
  });
  @override
  State<AlbumFilterSheet> createState() => _AlbumFilterSheetState();
}

class _AlbumFilterSheetState extends State<AlbumFilterSheet> {
  late AlbumOptions _value = widget.initial;
  // Worker snapshots already contain sorted type labels and the legacy default
  // selection. No file-list discovery, filtering or sorting occurs in this UI.
  late Set<String> _types = {
    for (final type in widget.snapshot.availableTypes)
      if (widget.initial.types.contains('*') ||
          (widget.initial.types.isEmpty
              ? widget.snapshot.defaultTypes.contains(type)
              : widget.initial.types.contains(type)))
        type,
  };
  bool get _allTypes =>
      _types.isNotEmpty &&
      _types.length == widget.snapshot.availableTypes.length;
  late String _datePreset = _value.unknownDatesOnly
      ? 'unknown'
      : _value.dateFrom != null || _value.dateTo != null
      ? 'range'
      : 'any';

  void _chooseType(String type) => setState(() {
    if (type == '*') {
      _types = _allTypes ? <String>{} : widget.snapshot.availableTypes.toSet();
    } else {
      final changed = Set<String>.of(_types);
      if (!changed.add(type)) changed.remove(type);
      _types = changed;
    }
  });

  void _apply() {
    if (_types.isEmpty) return;
    // Removed name, size and orientation inputs must not leave invisible
    // constraints behind. Explicit type chips replace legacy suffix/kind rules.
    Navigator.pop(
      context,
      AlbumOptions(
        types: _allTypes ? const {'*'} : _types,
        sortField: _value.sortField,
        descending: _value.descending,
        dateField: _value.dateField,
        dateFrom: _value.dateFrom,
        dateTo: _value.dateTo,
        unknownDatesOnly: _value.unknownDatesOnly,
        groupPhotos: _value.groupPhotos,
        hideHiddenFiles: _value.hideHiddenFiles,
      ),
    );
  }

  String _day(int? milliseconds) {
    if (milliseconds == null) return '不限';
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    return '${date.year}/${date.month}/${date.day}';
  }

  String get _rangeLabel => _datePreset == 'range'
      ? '${_day(_value.dateFrom)} – ${_day(_value.dateTo)}'
      : '自定义范围';

  Future<void> _chooseDate(String preset) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime? from, to;
    if (preset == 'range') {
      final first = DateTime(1900), last = DateTime(now.year + 10, 12, 31);
      final start = _value.dateFrom == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(_value.dateFrom!);
      final end = _value.dateTo == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(_value.dateTo!);
      final current =
          start != null &&
              end != null &&
              !start.isBefore(first) &&
              !end.isAfter(last) &&
              !start.isAfter(end)
          ? DateTimeRange(start: start, end: end)
          : null;
      final selected = await showDateRangePicker(
        context: context,
        firstDate: first,
        lastDate: last,
        initialDateRange: current,
        helpText: '日期范围',
        saveText: '确定',
      );
      if (!mounted || selected == null) return;
      from = selected.start;
      to = DateTime(
        selected.end.year,
        selected.end.month,
        selected.end.day + 1,
      ).subtract(const Duration(milliseconds: 1));
    } else if (preset == 'today' || preset == 'week' || preset == 'month') {
      final days = preset == 'week'
          ? 6
          : preset == 'month'
          ? 29
          : 0;
      from = DateTime(today.year, today.month, today.day - days);
      to = DateTime(
        today.year,
        today.month,
        today.day + 1,
      ).subtract(const Duration(milliseconds: 1));
    }
    if (!mounted) return;
    setState(() {
      _datePreset = preset;
      _value = _value.copyWith(
        dateFrom: from?.millisecondsSinceEpoch,
        dateTo: to?.millisecondsSinceEpoch,
        unknownDatesOnly: preset == 'unknown',
      );
    });
  }

  Widget _typeChip(int index) {
    final type = index == 0 ? '*' : widget.snapshot.availableTypes[index - 1];
    final label = switch (type) {
      '*' => '全部',
      'folder' => '文件夹',
      'file' => '无后缀',
      _ => type.startsWith('.') ? type.substring(1).toUpperCase() : type,
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 112),
      child: FilterChip(
        key: ValueKey('album-type:$type'),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        tooltip: label,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        labelPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        selected: type == '*' ? _allTypes : _types.contains(type),
        showCheckmark: false,
        onSelected: (_) => _chooseType(type),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(size.width, 560),
          maxHeight: math.min(size.height * .82, 540),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '筛选与排序',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, AlbumOptions()),
                    child: const Text('重置'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _types.isEmpty ? null : _apply,
                    child: const Text('应用'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: CustomScrollView(
                shrinkWrap: true,
                key: const ValueKey('album-filter-scroll'),
                slivers: [
                  const SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 2),
                    sliver: SliverToBoxAdapter(child: Text('类型')),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    // Bounded groups keep large format lists lazy. Within
                    // each group chips flow at their natural width, left aligned.
                    sliver: SliverList.builder(
                      itemCount:
                          (widget.snapshot.availableTypes.length + 16) ~/ 16,
                      itemBuilder: (context, group) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (
                              var index = group * 16;
                              index <
                                  math.min(
                                    (group + 1) * 16,
                                    widget.snapshot.availableTypes.length + 1,
                                  );
                              index++
                            )
                              _typeChip(index),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: GlassSelect<String>(
                                  label: '排序',
                                  value: _value.sortField,
                                  options: const [
                                    GlassOption('name', '名称'),
                                    GlassOption('modified', '修改时间'),
                                    GlassOption('captured', '拍摄时间'),
                                    GlassOption('size', '文件大小'),
                                    GlassOption('type', '类型'),
                                  ],
                                  onChanged: (value) => setState(
                                    () => _value = _value.copyWith(
                                      sortField: value,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilterChip(
                                label: const Text('降序'),
                                selected: _value.descending,
                                onSelected: (value) => setState(
                                  () => _value = _value.copyWith(
                                    descending: value,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: GlassSelect<String>(
                                  label: '日期依据',
                                  value: _value.dateField,
                                  options: const [
                                    GlassOption('modified', '修改时间'),
                                    GlassOption('captured', '拍摄时间'),
                                  ],
                                  onChanged: (value) => setState(
                                    () => _value = _value.copyWith(
                                      dateField: value,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: GlassSelect<String>(
                                  label: '日期范围',
                                  value: _datePreset,
                                  options: [
                                    const GlassOption('any', '不限'),
                                    const GlassOption('today', '今天'),
                                    const GlassOption('week', '最近 7 天'),
                                    const GlassOption('month', '最近 30 天'),
                                    GlassOption('range', _rangeLabel),
                                    const GlassOption('unknown', '日期未知'),
                                  ],
                                  onChanged: _chooseDate,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('合并同名照片'),
                            value: _value.groupPhotos,
                            onChanged: (value) => setState(
                              () =>
                                  _value = _value.copyWith(groupPhotos: value),
                            ),
                          ),
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('不显示隐藏文件'),
                            value: _value.hideHiddenFiles,
                            onChanged: (value) => setState(
                              () => _value = _value.copyWith(
                                hideHiddenFiles: value,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
