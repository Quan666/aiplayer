import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Specialized treatments shared by settings, source forms and diagnostics.
/// Colors and typography resolve from the active theme on every rebuild.
class SettingsStyles {
  final ThemeData theme;
  final GlassColors colors;
  final AppStyles text;

  SettingsStyles._(BuildContext context)
    : theme = Theme.of(context),
      colors = GlassPalette.of(context),
      text = AppStyles.of(context);

  static SettingsStyles of(BuildContext context) => SettingsStyles._(context);

  static const searchTitleSize = 26.0;
  static const compactSearchTitleSize = 16.0;
  static const folderArtworkRadius = BorderRadius.all(
    Radius.circular(GlassMetrics.compact),
  );
  static const folderRowShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(GlassMetrics.control)),
  );
  static const folderRowDensity = VisualDensity(vertical: -2);
  static const logFilterDensity = VisualDensity(horizontal: -2, vertical: -2);
  static const shortcutPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 6,
  );
  static const searchFieldPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 8,
  );

  TextStyle searchTitle(double size) => theme.textTheme.headlineLarge!.copyWith(
    fontSize: theme.textTheme.headlineLarge!.fontSize! * size / searchTitleSize,
    fontWeight: FontWeight.w700,
  );

  TextStyle sourceTitle({required bool nested}) =>
      (nested ? theme.textTheme.headlineSmall! : theme.textTheme.headlineLarge!)
          .copyWith(fontWeight: FontWeight.w600, letterSpacing: -.5);

  TextStyle get shortcutPreview => theme.textTheme.headlineSmall!;
  TextStyle get logMessage => text.bodySmall.copyWith(height: 1.3);
  TextStyle get sourceErrorMessage => text.body.copyWith(height: 1.5);
  TextStyle get destructiveAction =>
      theme.textTheme.labelLarge!.copyWith(color: colors.danger);

  Color folderIcon({required bool video}) =>
      colors.accent.withValues(alpha: video ? .7 : .8);
  Color get emptyFolderIcon => colors.muted.withValues(alpha: .6);

  BoxDecoration get shortcutDecoration => BoxDecoration(
    color: colors.field,
    border: Border.all(color: colors.border),
    borderRadius: const BorderRadius.all(Radius.circular(GlassMetrics.small)),
  );
}
