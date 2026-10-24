import 'package:flutter/material.dart';
import '../data/app_model.dart';
import 'glass.dart';
import 'theme/library_styles.dart';
import 'metadata_match_dialog.dart';

Future<void> showMetadataTasks(
  BuildContext context,
  AppModel model,
) => showGlassBottomSheet(
  context: context,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(sheet).height * .6,
      child: AnimatedBuilder(
        animation: model,
        builder: (context, _) {
          final tasks = model.metadataTasks;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
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
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final work = task.selectionTask?.running == true
                        ? task.selectionTask!
                        : task;
                    return ListTile(
                      leading: Icon(
                        work.running
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
                          Text(work.error.isEmpty ? work.status : work.error),
                          if (work.running)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: LinearProgressIndicator(
                                value: work.completed == 0 || work.total == 0
                                    ? null
                                    : work.completed / work.total,
                              ),
                            ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (work.running)
                            IconButton(
                              tooltip: '取消识别',
                              onPressed: () => model.cancelMetadataTask(work),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          IconButton(
                            tooltip: '删除识别任务',
                            onPressed: () => model.removeMetadataTask(task),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                      onTap: () {
                        final records = task.records;
                        if (records.isEmpty) return;
                        Navigator.pop(sheet);
                        showMetadataMatchDialog(
                          context,
                          model,
                          '${records.first.data['series'] ?? task.label}',
                          season: '${records.first.data['season'] ?? ''}',
                          task: task,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ),
  ),
);
