import 'package:flutter/material.dart';
import '../data/app_model.dart';
import 'glass.dart';
import 'theme/library_styles.dart';
import 'metadata_match_dialog.dart';

Future<void> showMetadataTasks(BuildContext context, AppModel model) =>
    showGlassBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .6,
          child: AnimatedBuilder(
            animation: model,
            builder: (context, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '识别任务',
                          style: LibraryStyles.of(context).taskTitle,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(sheet),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: model.metadataTasks.length,
                    itemBuilder: (context, index) {
                      final task = model.metadataTasks[index];
                      return ListTile(
                        leading: Icon(
                          task.running
                              ? Icons.manage_search_rounded
                              : task.cancelled
                              ? Icons.pause_circle_outline
                              : Icons.task_alt_rounded,
                        ),
                        title: Text(
                          task.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(task.error.isEmpty ? task.status : task.error),
                            if (task.running)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: LinearProgressIndicator(
                                  value: task.completed == 0 || task.total == 0
                                      ? null
                                      : task.completed / task.total,
                                ),
                              ),
                          ],
                        ),
                        trailing: task.running
                            ? IconButton(
                                tooltip: '取消识别',
                                onPressed: () => model.cancelMetadataTask(task),
                                icon: const Icon(Icons.close_rounded),
                              )
                            : const Icon(Icons.chevron_right_rounded),
                        onTap: () {
                          final records = model.media
                              .where((r) => task.mediaIds.contains(r.id))
                              .toList();
                          if (records.isEmpty) return;
                          Navigator.pop(sheet);
                          showMetadataMatchDialog(
                            context,
                            model,
                            '${records.first.data['series'] ?? task.label}',
                            season: '${records.first.data['season'] ?? ''}',
                            mediaIds: task.mediaIds,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
