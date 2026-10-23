import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/logger.dart';
import 'glass.dart';
import 'theme/settings_styles.dart';
import 'search_header.dart';

class LogsView extends StatefulWidget {
  final AppLog? log;
  const LogsView({super.key, this.log});
  @override
  State<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends State<LogsView> {
  String filter = '全部';
  String search = '';
  AppLog get log => widget.log ?? AppLog.instance;
  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空本机日志？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) await log.clear();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制日志'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: log,
    builder: (context, _) {
      final entries = log.entries.reversed
          .where(
            (entry) =>
                (filter == '全部' || entry.level == filter) &&
                '${entry.scope} ${entry.message}'.toLowerCase().contains(
                  search.toLowerCase(),
                ),
          )
          .toList();
      Widget list({required bool bounded}) => ListView.separated(
        key: const ValueKey('diagnostic-log-list'),
        shrinkWrap: !bounded,
        physics: bounded ? null : const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final entry = entries[i];
          return InkWell(
            onTap: () => _copy(entry.text),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.time.toLocal().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} · ${entry.scope} · ${entry.level}',
                    style: entry.level == '错误'
                        ? AppStyles.of(context).errorMicro
                        : AppStyles.of(context).micro,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    entry.message,
                    style: SettingsStyles.of(context).logMessage,
                  ),
                ],
              ),
            ),
          );
        },
      );
      return LayoutBuilder(
        builder: (context, constraints) => Column(
          mainAxisSize: constraints.hasBoundedHeight
              ? MainAxisSize.max
              : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SearchHeader(
              title: '运行日志',
              titleSize: SettingsStyles.compactSearchTitleSize,
              hint: '搜索日志',
              onChanged: (v) => setState(() => search = v),
              trailing: PopupMenuButton<String>(
                tooltip: '日志操作',
                onSelected: (value) async {
                  if (value == 'clear') {
                    await clear();
                    return;
                  }
                  await _copy(entries.map((e) => e.text).join('\n'));
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'copy',
                    enabled: entries.isNotEmpty,
                    child: const Text('复制当前日志'),
                  ),
                  PopupMenuItem(
                    value: 'clear',
                    enabled: log.entries.isNotEmpty,
                    child: const Text('清空日志'),
                  ),
                ],
                icon: const Icon(Icons.more_horiz_rounded, size: 20),
              ),
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final level in ['全部', '错误', '警告', '信息'])
                  ChoiceChip(
                    visualDensity: SettingsStyles.logFilterDensity,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(level),
                    selected: level == filter,
                    onSelected: (_) => setState(() => filter = level),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('暂无相关日志', textAlign: TextAlign.center),
              ),
            if (entries.isNotEmpty)
              if (constraints.hasBoundedHeight)
                Expanded(child: list(bounded: true))
              else
                list(bounded: false),
          ],
        ),
      );
    },
  );
}
