import 'package:flutter/material.dart';
import '../playback/session.dart';
import '../core/logger.dart';
import '../ui/theme/app_theme.dart';

class SubtitleToolsPanel extends StatelessWidget {
  final PlaybackSession session;
  const SubtitleToolsPanel({super.key, required this.session});
  Future<void> _translate(BuildContext context) async {
    try {
      await session.translateSubtitle();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(safeFailure(e).message)));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 0,
          children: [
            TextButton.icon(
              onPressed:
                  session.subtitleTaskBusy || !session.hasSubtitleForTools
                  ? null
                  : session.simplifySubtitle,
              icon: const Icon(Icons.text_fields_rounded, size: 18),
              label: const Text('繁体转简体'),
            ),
            TextButton.icon(
              onPressed:
                  session.subtitleTaskBusy || !session.hasSubtitleForTools
                  ? null
                  : () => _translate(context),
              icon: const Icon(Icons.translate_rounded, size: 18),
              label: const Text('AI 翻译'),
            ),
            if (session.subtitleTransformed)
              TextButton(
                onPressed: session.restoreOriginalSubtitle,
                child: const Text('原始字幕'),
              ),
            if (session.subtitleTaskBusy)
              TextButton(
                onPressed: session.cancelSubtitleTask,
                child: const Text('取消'),
              ),
          ],
        ),
        if (session.selectedSubtitleIsImage)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '当前为图片字幕，可直接播放；繁简转换和 AI 翻译需要文字字幕。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (session.subtitleTaskBusy)
          LinearProgressIndicator(
            value: session.subtitleTaskProgress > 0
                ? session.subtitleTaskProgress
                : null,
            minHeight: 2,
          ),
        if (session.subtitleTaskStatus.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              session.subtitleTaskStatus,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (session.subtitleTaskError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SelectableText(
              session.subtitleTaskError,
              style: AppStyles.of(context).errorCaption,
            ),
          ),
      ],
    ),
  );
}
