import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../core/logger.dart';
import '../core/network.dart';
import '../data/app_model.dart';
import '../data/media_presentation.dart';
import '../data/media_technical_info.dart';
import '../data/store.dart';
import '../subtitles/ai.dart';
import 'glass.dart';
import 'theme/library_styles.dart';
import 'media_artwork.dart';

/// One presentation for library details and a source directory's introduction.
class MediaDetailsHeader extends StatelessWidget {
  final AppModel model;
  final MediaCollectionDetails details;
  final List<SyncRecord> records;
  final VoidCallback? onMatch;
  const MediaDetailsHeader({
    super.key,
    required this.model,
    required this.details,
    this.records = const [],
    this.onMatch,
  });

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    final score = details.rating;
    final single = records.length == 1 ? records.single : null;
    final technical = single == null
        ? ''
        : MediaTechnicalInfo.forRecord(
            model.store,
            single,
            dimensions: model.mediaDimensions(single),
            duration: model.mediaDuration(single),
          ).label;
    Widget badge(String label, Color color, {IconData? icon}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: LibraryStyles.of(context).badgeDecoration(color),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: LibraryStyles.iconSmall, color: color),
            const SizedBox(width: 4),
          ],
          Text(label, style: LibraryStyles.of(context).badgeLabel(color)),
        ],
      ),
    );
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (details.poster.isNotEmpty) ...[
                SizedBox(
                  width: 82,
                  height: 122,
                  child: ClipRRect(
                    borderRadius: LibraryStyles.posterRadius,
                    child: MediaArtwork(
                      poster: details.poster,
                      cache: model.posterCache,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedBuilder(
                      animation: model,
                      builder: (context, _) => Text(
                        single != null
                            ? model.displayTitle(single)
                            : model.titleTranslations.display(
                                records.isEmpty
                                    ? 'title:${details.title}'
                                    : mediaSeriesKey(records.first),
                                details.title,
                              ),
                        style: LibraryStyles.of(context).detailsTitle,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (score != null && score > 0)
                          badge(
                            '评分 ${score.toStringAsFixed(1)}',
                            LibraryStyles.of(context).ratingColor(score),
                            icon: Icons.star_rounded,
                          ),
                        if (single == null && details.seasonLabel.isNotEmpty)
                          badge(details.seasonLabel, palette.accent),
                        if ((details.totalEpisodes ?? 0) > 0)
                          badge('共 ${details.totalEpisodes} 集', palette.accent),
                        if (details.year.isNotEmpty)
                          badge(details.year, palette.muted),
                        for (final genre in details.genres)
                          badge(genre, palette.muted),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      details.availability,
                      style: LibraryStyles.of(context).availability,
                    ),
                    if (technical.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          technical,
                          style: AppStyles.of(context).caption,
                        ),
                      ),
                  ],
                ),
              ),
              if (onMatch != null)
                IconButton(
                  tooltip: '匹配海报与简介',
                  onPressed: onMatch,
                  icon: const Icon(Icons.manage_search_rounded),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: MediaSummary(
              model: model,
              summary: details.summary,
              titleAction: MediaTitleTranslation(
                model: model,
                title: details.title,
                records: records,
              ),
            ),
          ),
          if (details.provider == 'tmdb')
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '资料来源：TMDB\nThis product uses the TMDB API but is not endorsed or certified by TMDB.',
                style: AppStyles.of(context).tiny,
              ),
            ),
        ],
      ),
    );
  }
}

/// The same action translates the work title and named episodes. Numeric season
/// and episode labels remain generated locally and never enter the AI request.
class MediaTitleTranslation extends StatefulWidget {
  final AppModel model;
  final String title;
  final List<SyncRecord> records;
  const MediaTitleTranslation({
    super.key,
    required this.model,
    required this.title,
    this.records = const [],
  });
  @override
  State<MediaTitleTranslation> createState() => _MediaTitleTranslationState();
}

class _MediaTitleTranslationState extends State<MediaTitleTranslation> {
  bool busy = false;
  String error = '';
  CancelToken? cancel;
  Set<String>? _titles;
  late int _titleRevision;
  late String _profile;
  String get seriesKey => widget.records.isEmpty
      ? 'title:${widget.title}'
      : mediaSeriesKey(widget.records.first);
  Set<String> get titles => _titles ??= {
    widget.title,
    for (final item in widget.records) mediaSeriesName(item),
    for (final item in widget.records)
      if (widget.model.originalEpisodeTitle(item).trim().isNotEmpty)
        widget.model.originalEpisodeTitle(item),
  };

  @override
  void initState() {
    super.initState();
    _titleRevision = widget.model.titleTranslations.revision;
    _profile = widget.model.titleTranslations.profile;
    widget.model.addListener(_changed);
  }

  void _changed() {
    final translations = widget.model.titleTranslations;
    final profile = translations.profile;
    if (_titleRevision == translations.revision && _profile == profile) return;
    _titleRevision = translations.revision;
    _profile = profile;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(MediaTitleTranslation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.records != widget.records) {
      _titles = null;
    }
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_changed);
      widget.model.addListener(_changed);
    }
    if (oldWidget.title != widget.title ||
        oldWidget.model != widget.model ||
        (oldWidget.records.firstOrNull?.id != widget.records.firstOrNull?.id)) {
      cancel?.cancel();
      cancel = null;
      busy = false;
      error = '';
    }
  }

  @override
  void dispose() {
    cancel?.cancel();
    widget.model.removeListener(_changed);
    super.dispose();
  }

  Future<void> _translate() async {
    final translations = widget.model.titleTranslations;
    if (translations.isComplete(seriesKey, titles)) {
      translations.setVisible(seriesKey, !translations.isVisible(seriesKey));
      widget.model.changed();
      return;
    }
    final token = cancel = CancelToken();
    final key = seriesKey, sourceTitle = widget.title, originals = titles;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final settings = widget.model.settings;
      final config = SubtitleAiConfig(
        origin:
            '${settings['aiSubtitleOrigin'] ?? 'https://api.openai.com/v1'}',
        token: await widget.model.secrets.read(key: 'aiSubtitleToken') ?? '',
        model: '${settings['aiSubtitleModel'] ?? ''}',
        target: '${settings['aiSubtitleTarget'] ?? '简体中文'}',
      );
      token.check();
      if (config.model.trim().isEmpty) {
        throw const AppFailure('请先在设置中配置 AI 翻译模型。');
      }
      await translations.translate(
        seriesKey: key,
        seriesTitle: sourceTitle,
        titles: originals,
        config: config,
        cancel: token,
      );
      token.check();
      widget.model.changed();
    } on Cancelled {
      // Keep original titles and retain only fully validated cached batches.
    } catch (failure) {
      if (mounted && !token.cancelled) {
        setState(() => error = safeFailure(failure).message);
      }
    } finally {
      if (mounted && identical(cancel, token)) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final translations = widget.model.titleTranslations;
    final hasTranslations = translations.hasTranslations(seriesKey);
    final complete =
        hasTranslations && translations.isComplete(seriesKey, titles);
    final visible = translations.isVisible(seriesKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: busy ? null : _translate,
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: LibraryStyles.progressHeight,
                      ),
                    )
                  : const Icon(
                      Icons.translate_rounded,
                      size: LibraryStyles.iconAction,
                    ),
              label: Text(
                busy
                    ? '正在翻译标题…'
                    : complete
                    ? (visible ? '标题原文' : '标题译文')
                    : hasTranslations
                    ? '翻译新增标题'
                    : 'AI 翻译标题',
              ),
            ),
            if (busy)
              TextButton(
                onPressed: () => cancel?.cancel(),
                child: const Text('取消'),
              ),
            if (!busy && !complete && visible && hasTranslations)
              TextButton(
                onPressed: () {
                  translations.setVisible(seriesKey, false);
                  widget.model.changed();
                },
                child: const Text('标题原文'),
              ),
          ],
        ),
        if (error.isNotEmpty)
          Text(error, style: LibraryStyles.of(context).errorCaption),
      ],
    );
  }
}

class MediaSummary extends StatefulWidget {
  final AppModel model;
  final String summary;
  final Widget? titleAction;
  const MediaSummary({
    super.key,
    required this.model,
    required this.summary,
    this.titleAction,
  });
  @override
  State<MediaSummary> createState() => _MediaSummaryState();
}

class _MediaSummaryState extends State<MediaSummary> {
  bool expanded = false, busy = false, showTranslation = false;
  String? translated;
  late String _originalPreview;
  String? _translatedPreview;
  String error = '';
  CancelToken? cancel;

  // The folded view only shows four lines. Avoid shaping a provider's entire
  // multi-page synopsis every time a sheet scrolls or a translation toggles.
  static String _preview(String text) => text.length <= 600
      ? text
      : '${String.fromCharCodes(text.runes.take(600))}…';

  @override
  void initState() {
    super.initState();
    _originalPreview = _preview(widget.summary);
  }

  @override
  void didUpdateWidget(MediaSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary != widget.summary) {
      cancel?.cancel();
      translated = null;
      _originalPreview = _preview(widget.summary);
      _translatedPreview = null;
      busy = false;
      showTranslation = false;
      error = '';
    }
  }

  @override
  void dispose() {
    cancel?.cancel();
    super.dispose();
  }

  Future<void> _translate() async {
    if (translated != null) {
      setState(() => showTranslation = !showTranslation);
      return;
    }
    final token = cancel = CancelToken();
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final settings = widget.model.settings;
      final config = SubtitleAiConfig(
        origin:
            '${settings['aiSubtitleOrigin'] ?? 'https://api.openai.com/v1'}',
        token: await widget.model.secrets.read(key: 'aiSubtitleToken') ?? '',
        model: '${settings['aiSubtitleModel'] ?? ''}',
        target: '${settings['aiSubtitleTarget'] ?? '简体中文'}',
      );
      token.check();
      if (config.model.trim().isEmpty) {
        throw const AppFailure('请先在设置 → AI 翻译中加载并选择模型。');
      }
      final key =
          'summary-translation:${sha256.convert(utf8.encode(jsonEncode([widget.summary, config.identity])))}';
      var result = widget.model.store.local(key) as String?;
      if (result == null) {
        result = await translateText(
          widget.summary,
          config: config,
          cancel: token,
        );
        token.check();
        widget.model.store.setLocal(key, result);
      }
      if (mounted) {
        setState(() {
          translated = result;
          _translatedPreview = _preview(result!);
          showTranslation = true;
          expanded = true;
        });
      }
    } on Cancelled {
      // Dismissing the view stops the request without replacing the original.
    } catch (failure) {
      if (mounted && !token.cancelled) {
        setState(() => error = safeFailure(failure).message);
      }
    } finally {
      if (mounted && identical(cancel, token)) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.summary.isNotEmpty)
        Text(
          expanded
              ? (showTranslation ? translated! : widget.summary)
              : (showTranslation ? _translatedPreview! : _originalPreview),
          maxLines: expanded ? null : 4,
          overflow: expanded ? null : TextOverflow.ellipsis,
          style: LibraryStyles.of(context).summary,
        ),
      Wrap(
        spacing: 8,
        children: [
          if (widget.summary.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => expanded = !expanded),
              child: Text(expanded ? '收起简介' : '展开简介'),
            ),
          if (widget.summary.isNotEmpty)
            TextButton.icon(
              onPressed: busy ? null : _translate,
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: LibraryStyles.progressHeight,
                      ),
                    )
                  : const Icon(
                      Icons.translate_rounded,
                      size: LibraryStyles.iconAction,
                    ),
              label: Text(
                busy
                    ? '正在翻译…'
                    : showTranslation
                    ? '查看原文'
                    : translated != null
                    ? '查看译文'
                    : 'AI 翻译简介',
              ),
            ),
          ?widget.titleAction,
          if (busy)
            TextButton(
              onPressed: () => cancel?.cancel(),
              child: const Text('取消'),
            ),
        ],
      ),
      if (error.isNotEmpty)
        Text(error, style: LibraryStyles.of(context).errorCaption),
    ],
  );
}
