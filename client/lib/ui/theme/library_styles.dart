import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Library-specific presentation, resolved from the active application theme.
/// Keep widget layout and media data in the pages; put visual choices here.
class LibraryStyles {
  LibraryStyles.of(BuildContext context)
    : colors = GlassPalette.of(context),
      text = AppStyles.of(context),
      title = Theme.of(context).textTheme.titleLarge!;

  final GlassColors colors;
  final AppStyles text;
  final TextStyle title;

  static const compactRadius = BorderRadius.all(
    Radius.circular(GlassMetrics.small),
  );
  static const posterRadius = BorderRadius.all(
    Radius.circular(GlassMetrics.preview),
  );
  static const historyRadius = BorderRadius.all(Radius.circular(14));
  static const progressRadius = BorderRadius.all(Radius.circular(2));
  static const progressHeight = 2.0;
  static const iconSmall = 14.0;
  static const iconAction = 16.0;
  static const iconButton = 18.0;
  static const iconHeading = 20.0;
  static const iconNavigationDesktop = 21.0;
  static const iconNavigation = 22.0;
  static const iconPlaceholder = 28.0;

  TextStyle get sectionTitle => text.sectionTitle.copyWith(letterSpacing: -.3);
  TextStyle get detailsTitle => title.copyWith(fontWeight: FontWeight.w700);
  TextStyle get taskTitle =>
      text.panelTitle.copyWith(fontSize: text.panelTitle.fontSize! + 1);
  TextStyle get emptyHint => text.muted.copyWith(height: 1.8);
  TextStyle get availability =>
      text.caption.copyWith(fontWeight: FontWeight.w600);
  TextStyle get summary => text.muted.copyWith(height: 1.6);
  TextStyle get errorCaption => text.errorCaption;
  TextStyle get posterTitle => text.body.copyWith(fontWeight: FontWeight.w500);
  TextStyle get episodeProgress => text.micro.copyWith(color: colors.text);
  TextStyle get continueTitle =>
      text.strong.copyWith(color: colors.onMedia, height: 1.3);
  TextStyle get mediaCaption => text.micro.copyWith(color: colors.mutedOnMedia);
  TextStyle get posterCount => text.micro.copyWith(
    color: colors.onMedia,
    shadows: [Shadow(color: colors.shadow, blurRadius: 5)],
  );
  TextStyle badgeLabel(Color color) =>
      text.caption.copyWith(color: color, fontWeight: FontWeight.w700);
  TextStyle navigationLabel({required bool desktop, required bool selected}) =>
      text.body.copyWith(
        fontSize: desktop ? text.body.fontSize : text.micro.fontSize,
        fontWeight: selected
            ? FontWeight.w600
            : desktop
            ? FontWeight.w400
            : FontWeight.w500,
        color: selected ? colors.accent : colors.muted,
      );

  Color ratingColor(double score) => score >= 8
      ? colors.success
      : score >= 6
      ? colors.warning
      : colors.danger;
  Color get mediaProgressTrack => colors.onMedia.withValues(alpha: .3);
  Color get placeholderIcon => colors.muted.withValues(alpha: .45);
  Color get navigationSelection => colors.accent.withValues(alpha: .13);
  List<Shadow> get posterIconShadows => [
    Shadow(color: colors.shadow.withValues(alpha: .87), blurRadius: 4),
  ];

  BoxDecoration badgeDecoration(Color color) => BoxDecoration(
    color: color.withValues(alpha: .12),
    borderRadius: compactRadius,
  );
  BoxDecoration get dragHandle => BoxDecoration(
    color: colors.muted.withValues(alpha: .4),
    borderRadius: progressRadius,
  );
  BoxDecoration get taskStatus => BoxDecoration(
    color: colors.accent.withValues(alpha: .08),
    borderRadius: posterRadius,
  );
  BoxDecoration get historyOverlay => BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        colors.shadow.withValues(alpha: 8 / 255),
        colors.shadow.withValues(alpha: .4),
        colors.shadow.withValues(alpha: 221 / 255),
      ],
      stops: const [0, .45, 1],
    ),
  );
  BoxDecoration get desktopNavigationSelection => BoxDecoration(
    borderRadius: BorderRadius.circular(GlassMetrics.control),
    color: colors.selected,
  );
  BoxDecoration navigationDecoration({required double radius}) => BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    color: Colors.transparent,
  );
}
