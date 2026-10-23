import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'player_tokens.dart';

export 'player_tokens.dart';

abstract final class GlassMetrics {
  static const compact = 6.0;
  static const small = 8.0;
  static const preview = 12.0;
  static const control = 12.0;
  static const card = 16.0;
  static const sheet = 20.0;
  static const pill = 999.0;
  static const progress = 4.0;
  static const toast = 24.0;
  static const surfaceBlur = 12.0;
  static const controlBlur = 12.0;
  static const edgeWidth = 1.0;
  static const contrastEdgeWidth = 1.5;
  static const navigationRadius = 24.0;
  static const navigationInset = 4.0;
  static const navigationItemRadius = navigationRadius - navigationInset;
  static const pageTopInset = 4.0;

  /// Extra space below the system safe area, shared by page headers.
  static double pageTopPadding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 1000 ? pageTopInset : 12;
}

@immutable
class GlassColors extends ThemeExtension<GlassColors> {
  final Color canvas,
      text,
      muted,
      accent,
      blue,
      surface,
      border,
      field,
      selected,
      glass,
      success,
      warning,
      danger,
      onAccent,
      onMedia,
      mutedOnMedia,
      mediaScrim,
      mediaShade,
      mediaShadeStrong,
      mediaBackground,
      mediaHighlight,
      elevatedSurface,
      inverseSurface,
      onInverseSurface,
      navigationSurface,
      shadow,
      surfaceHighlight,
      switchTrack,
      switchThumb;
  const GlassColors({
    required this.canvas,
    required this.text,
    required this.muted,
    required this.accent,
    required this.blue,
    required this.surface,
    required this.border,
    required this.field,
    required this.selected,
    required this.glass,
    this.success = const Color(0xff187954),
    this.warning = const Color(0xffaf6500),
    this.danger = const Color(0xffc83434),
    this.onAccent = const Color(0xffffffff),
    this.onMedia = const Color(0xffffffff),
    this.mutedOnMedia = const Color(0xb3ffffff),
    this.mediaScrim = const Color(0x59000000),
    this.mediaShade = const Color(0x73000000),
    this.mediaShadeStrong = const Color(0xa6000000),
    this.mediaBackground = const Color(0xff000000),
    this.mediaHighlight = const Color(0xffffffff),
    this.elevatedSurface = const Color(0xffffffff),
    this.inverseSurface = const Color(0xff263040),
    this.onInverseSurface = const Color(0xffffffff),
    this.navigationSurface = const Color(0x99ffffff),
    this.shadow = const Color(0xff000000),
    this.surfaceHighlight = const Color(0xffffffff),
    this.switchTrack = const Color(0xffd8e0eb),
    this.switchThumb = const Color(0xff526174),
  });
  Color get error => danger;
  static const light = GlassColors(
    canvas: Color(0xfff4f5f7),
    text: Color(0xff202631),
    muted: Color(0xff646c79),
    accent: Color(0xff2463c4),
    blue: Color(0xff2463c4),
    surface: Color(0xffffffff),
    border: Color(0xffdfe3ea),
    field: Color(0xfff6f7fa),
    selected: Color(0xffe4edf9),
    glass: Color(0xe6ffffff),
  );
  static const dark = GlassColors(
    canvas: Color(0xff14181f),
    text: Color(0xffeff2f7),
    muted: Color(0xffa4afbe),
    accent: Color(0xff91bcf4),
    blue: Color(0xff91bcf4),
    surface: Color(0xff202630),
    border: Color(0xff343c48),
    field: Color(0xff191f28),
    selected: Color(0xff303e55),
    glass: Color(0xeb242b36),
    success: Color(0xff7edbb4),
    warning: Color(0xffffbd66),
    danger: Color(0xffff9b95),
    onAccent: Color(0xff102941),
    elevatedSurface: Color(0xff29313d),
    inverseSurface: Color(0xffe4eaf2),
    onInverseSurface: Color(0xff202631),
    navigationSurface: Color(0x80343a43),
    switchTrack: Color(0xff384659),
    switchThumb: Color(0xffe2eaf5),
  );
  @override
  GlassColors copyWith({
    Color? canvas,
    Color? text,
    Color? muted,
    Color? accent,
    Color? blue,
    Color? surface,
    Color? border,
    Color? field,
    Color? selected,
    Color? glass,
    Color? success,
    Color? warning,
    Color? danger,
    Color? onAccent,
    Color? onMedia,
    Color? mutedOnMedia,
    Color? mediaScrim,
    Color? mediaShade,
    Color? mediaShadeStrong,
    Color? mediaBackground,
    Color? mediaHighlight,
    Color? elevatedSurface,
    Color? inverseSurface,
    Color? onInverseSurface,
    Color? navigationSurface,
    Color? shadow,
    Color? surfaceHighlight,
    Color? switchTrack,
    Color? switchThumb,
  }) => GlassColors(
    canvas: canvas ?? this.canvas,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    accent: accent ?? this.accent,
    blue: blue ?? this.blue,
    surface: surface ?? this.surface,
    border: border ?? this.border,
    field: field ?? this.field,
    selected: selected ?? this.selected,
    glass: glass ?? this.glass,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    onAccent: onAccent ?? this.onAccent,
    onMedia: onMedia ?? this.onMedia,
    mutedOnMedia: mutedOnMedia ?? this.mutedOnMedia,
    mediaScrim: mediaScrim ?? this.mediaScrim,
    mediaShade: mediaShade ?? this.mediaShade,
    mediaShadeStrong: mediaShadeStrong ?? this.mediaShadeStrong,
    mediaBackground: mediaBackground ?? this.mediaBackground,
    mediaHighlight: mediaHighlight ?? this.mediaHighlight,
    elevatedSurface: elevatedSurface ?? this.elevatedSurface,
    inverseSurface: inverseSurface ?? this.inverseSurface,
    onInverseSurface: onInverseSurface ?? this.onInverseSurface,
    navigationSurface: navigationSurface ?? this.navigationSurface,
    shadow: shadow ?? this.shadow,
    surfaceHighlight: surfaceHighlight ?? this.surfaceHighlight,
    switchTrack: switchTrack ?? this.switchTrack,
    switchThumb: switchThumb ?? this.switchThumb,
  );
  @override
  GlassColors lerp(covariant GlassColors? other, double t) {
    if (other == null) return this;
    return GlassColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      text: Color.lerp(text, other.text, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      border: Color.lerp(border, other.border, t)!,
      field: Color.lerp(field, other.field, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      onMedia: Color.lerp(onMedia, other.onMedia, t)!,
      mutedOnMedia: Color.lerp(mutedOnMedia, other.mutedOnMedia, t)!,
      mediaScrim: Color.lerp(mediaScrim, other.mediaScrim, t)!,
      mediaShade: Color.lerp(mediaShade, other.mediaShade, t)!,
      mediaShadeStrong: Color.lerp(
        mediaShadeStrong,
        other.mediaShadeStrong,
        t,
      )!,
      mediaBackground: Color.lerp(mediaBackground, other.mediaBackground, t)!,
      mediaHighlight: Color.lerp(mediaHighlight, other.mediaHighlight, t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      inverseSurface: Color.lerp(inverseSurface, other.inverseSurface, t)!,
      onInverseSurface: Color.lerp(
        onInverseSurface,
        other.onInverseSurface,
        t,
      )!,
      navigationSurface: Color.lerp(
        navigationSurface,
        other.navigationSurface,
        t,
      )!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      surfaceHighlight: Color.lerp(
        surfaceHighlight,
        other.surfaceHighlight,
        t,
      )!,
      switchTrack: Color.lerp(switchTrack, other.switchTrack, t)!,
      switchThumb: Color.lerp(switchThumb, other.switchThumb, t)!,
    );
  }
}

abstract final class GlassPalette {
  static GlassColors of(BuildContext context) =>
      Theme.of(context).extension<GlassColors>() ??
      (Theme.of(context).brightness == Brightness.dark
          ? GlassColors.dark
          : GlassColors.light);

  /// Compatibility entry point for existing screens and package consumers.
  static ThemeData theme({
    Brightness brightness = Brightness.light,
    bool highContrast = false,
    GlassColors? colors,
    String fontFamily = AppTheme.fontFamily,
    TextTheme? textTheme,
    PlayerTokens player = PlayerTokens.standard,
  }) => AppTheme.theme(
    brightness: brightness,
    highContrast: highContrast,
    colors: colors,
    fontFamily: fontFamily,
    textTheme: textTheme,
    player: player,
  );
}

/// The app's theme entry point. A skin supplies its palette, typography and
/// player tokens here; screens resolve semantic styles from the active theme.
///
/// Add shared visual roles here, feature treatments in `library_styles.dart`,
/// `settings_styles.dart` or `player_style.dart`, and keep page layout in the
/// widgets. Read styles through BuildContext so existing routes and form state
/// can survive a theme replacement. Media comment colors remain content data.
///
/// A future theme picker can build its light/dark ThemeData with a palette made
/// by `GlassColors.light.copyWith(...)` and optional `PlayerTokens.copyWith(...)`.
/// `fontFamily` and `textTheme` customize typography through the same entry.
abstract final class AppTheme {
  static const fontFamily = 'NotoSansSC';
  static const transparent = Colors.transparent;

  static ThemeData theme({
    Brightness brightness = Brightness.light,
    bool highContrast = false,
    GlassColors? colors,
    String fontFamily = AppTheme.fontFamily,
    TextTheme? textTheme,
    PlayerTokens player = PlayerTokens.standard,
  }) {
    final dark = brightness == Brightness.dark;
    final c = colors ?? (dark ? GlassColors.dark : GlassColors.light);
    final controls = GlassControlStyles(
      colors: c,
      dark: dark,
      contrast: highContrast,
    );
    final control = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(GlassMetrics.control),
    );
    final card = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(GlassMetrics.card),
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      surface: c.surface,
      onSurface: c.text,
      onSurfaceVariant: c.muted,
      outline: c.border,
      outlineVariant: c.border,
      error: c.danger,
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(GlassMetrics.control),
      borderSide: controls.border(),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontFamily,
      colorScheme: scheme,
      extensions: [c, player],
      adaptations: const [_GlassSwitchAdaptation()],
      scaffoldBackgroundColor: c.canvas,
      splashFactory: NoSplash.splashFactory,
      dividerColor: c.border,
      appBarTheme: AppBarTheme(
        backgroundColor: c.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: c.text,
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: c.text,
          letterSpacing: -.4,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: c.text,
          letterSpacing: -.3,
        ),
        headlineSmall: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: c.text,
          letterSpacing: -.3,
        ),
        titleLarge: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: c.text,
        ),
        titleMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: c.text,
        ),
        bodyLarge: TextStyle(fontSize: 14, height: 1.4, color: c.text),
        bodyMedium: TextStyle(fontSize: 13, height: 1.4, color: c.text),
        bodySmall: TextStyle(fontSize: 12, color: c.muted, height: 1.5),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: c.text,
        ),
        labelMedium: TextStyle(fontSize: 12, color: c.muted),
        labelSmall: TextStyle(fontSize: 11, color: c.muted),
      ).merge(textTheme),
      iconTheme: IconThemeData(color: c.muted, size: 22),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: controls.fill(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        labelStyle: TextStyle(color: c.muted),
        hintStyle: TextStyle(color: c.muted, fontWeight: FontWeight.w400),
        prefixIconColor: c.muted,
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: controls
            .button(primary: true)
            .copyWith(
              textStyle: WidgetStatePropertyAll(
                TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600),
              ),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(style: controls.button()),
      textButtonTheme: TextButtonThemeData(style: controls.button(quiet: true)),
      iconButtonTheme: IconButtonThemeData(
        style: controls
            .button(quiet: true)
            .copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.all(8))),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(control),
          side: WidgetStateProperty.resolveWith(
            (states) => controls.border(
              selected: states.contains(WidgetState.selected),
              disabled: states.contains(WidgetState.disabled),
              focused: states.contains(WidgetState.focused),
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => controls.fill(
              selected: states.contains(WidgetState.selected),
              disabled: states.contains(WidgetState.disabled),
            ),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? c.muted.withValues(alpha: .5)
                : states.contains(WidgetState.selected)
                ? c.accent
                : c.text,
          ),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: controls.fill(),
        selectedColor: controls.fill(selected: true),
        disabledColor: controls.fill(disabled: true),
        labelStyle: TextStyle(fontSize: 12, color: c.text),
        checkmarkColor: c.accent,
        side: WidgetStateBorderSide.resolveWith(
          (states) => controls.border(
            selected: states.contains(WidgetState.selected),
            disabled: states.contains(WidgetState.disabled),
            focused: states.contains(WidgetState.focused),
          ),
        ),
        shape: control,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: c.surface,
        shape: card.copyWith(side: BorderSide(color: c.border)),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.sheet),
          side: BorderSide(color: c.border),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: control,
      ),
      listTileTheme: ListTileThemeData(
        shape: control,
        iconColor: c.muted,
        textColor: c.text,
        selectedColor: c.accent,
        selectedTileColor: c.selected,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: c.accent,
        inactiveTrackColor: c.border,
        thumbColor: c.accent,
        overlayColor: c.accent.withValues(alpha: .1),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          return controls.fill(
            selected: states.contains(WidgetState.selected),
            disabled: states.contains(WidgetState.disabled),
          );
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return c.muted.withValues(alpha: .5);
          }
          if (states.contains(WidgetState.selected)) return c.accent;
          return c.switchThumb;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return c.muted.withValues(alpha: .65);
          }
          return states.contains(WidgetState.selected) ? c.accent : c.muted;
        }),
        trackOutlineWidth: const WidgetStatePropertyAll(1.5),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.pressed)
              ? c.accent.withValues(alpha: .14)
              : c.accent.withValues(alpha: .06),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.border,
        borderRadius: BorderRadius.circular(GlassMetrics.progress),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.inverseSurface,
        contentTextStyle: TextStyle(
          color: c.onInverseSurface,
          fontFamily: fontFamily,
        ),
        shape: control,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.inverseSurface,
          borderRadius: BorderRadius.circular(GlassMetrics.small),
        ),
        textStyle: TextStyle(color: c.onInverseSurface, fontSize: 12),
      ),
    );
  }
}

/// The navigation material at control scale. Native Material controls retain
/// their gestures, focus, semantics and hit targets; only their paint changes.
class GlassControlStyles {
  final GlassColors colors;
  final bool dark, contrast;
  const GlassControlStyles({
    required this.colors,
    required this.dark,
    this.contrast = false,
  });

  factory GlassControlStyles.of(BuildContext context) => GlassControlStyles(
    colors: GlassPalette.of(context),
    dark: Theme.of(context).brightness == Brightness.dark,
    contrast: MediaQuery.highContrastOf(context),
  );

  Color fill({
    bool selected = false,
    bool disabled = false,
    bool highContrast = false,
  }) {
    if (highContrast || contrast) {
      return selected && !disabled ? colors.selected : colors.surface;
    }
    final base = colors.navigationSurface;
    if (disabled) return base.withValues(alpha: base.a * .45);
    return selected
        ? Color.alphaBlend(colors.accent.withValues(alpha: .13), base)
        : base;
  }

  BorderSide border({
    bool selected = false,
    bool disabled = false,
    bool focused = false,
    bool highContrast = false,
  }) => BorderSide(
    color: disabled
        ? colors.border.withValues(alpha: .45)
        : focused
        ? colors.accent
        : highContrast || contrast
        ? (selected ? colors.accent : colors.muted)
        : selected
        ? colors.accent.withValues(alpha: dark ? .52 : .35)
        : Color.alphaBlend(
            colors.surfaceHighlight.withValues(alpha: dark ? .12 : .5),
            colors.border.withValues(alpha: .7),
          ),
    width: focused || highContrast || contrast
        ? GlassMetrics.contrastEdgeWidth
        : GlassMetrics.edgeWidth,
  );

  BoxDecoration decoration({
    double radius = GlassMetrics.control,
    bool selected = false,
    bool disabled = false,
    bool focused = false,
    bool highContrast = false,
  }) {
    final tint = fill(
      selected: selected,
      disabled: disabled,
      highContrast: highContrast,
    );
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            colors.surfaceHighlight.withValues(
              alpha: highContrast || contrast || disabled
                  ? 0
                  : (dark ? .05 : .2),
            ),
            tint,
          ),
          tint,
        ],
      ),
      border: Border.fromBorderSide(
        border(
          selected: selected,
          disabled: disabled,
          focused: focused,
          highContrast: highContrast,
        ),
      ),
    );
  }

  ButtonStyle button({
    bool primary = false,
    bool quiet = false,
    bool blur = true,
    double radius = GlassMetrics.control,
  }) => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
    side: const WidgetStatePropertyAll(BorderSide.none),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colors.muted.withValues(alpha: .5)
          : primary || states.contains(WidgetState.selected)
          ? colors.accent
          : colors.text,
    ),
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => colors.accent.withValues(
        alpha: states.contains(WidgetState.pressed)
            ? .12
            : states.contains(WidgetState.hovered)
            ? .06
            : 0,
      ),
    ),
    backgroundBuilder: (context, states, child) => GlassControlBackground(
      radius: radius,
      selected: primary || states.contains(WidgetState.selected),
      disabled: states.contains(WidgetState.disabled),
      focused: states.contains(WidgetState.focused),
      quiet:
          quiet &&
          !states.contains(WidgetState.selected) &&
          !states.contains(WidgetState.focused) &&
          !states.contains(WidgetState.hovered) &&
          !states.contains(WidgetState.pressed),
      blur: blur,
      child: child ?? const SizedBox.shrink(),
    ),
  );
}

/// Surfaces keep the glass decoration without sampling a moving backdrop for
/// every control. A scope can explicitly enable filtering where it is needed.
class GlassBlurScope extends InheritedWidget {
  final bool enabled;
  const GlassBlurScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassBlurScope>()?.enabled ??
      false;

  @override
  bool updateShouldNotify(GlassBlurScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Clip every filter to its control; quiet and disabled controls need no blur.
/// Player surfaces can reuse the same paint without filtering the video again.
class GlassControlBackground extends StatelessWidget {
  final Widget child;
  final bool selected, disabled, focused, quiet, blur;
  final double radius;
  const GlassControlBackground({
    super.key,
    required this.child,
    this.selected = false,
    this.disabled = false,
    this.focused = false,
    this.quiet = false,
    this.blur = true,
    this.radius = GlassMetrics.control,
  });

  @override
  Widget build(BuildContext context) {
    if (quiet) return child;
    final contrast = MediaQuery.highContrastOf(context);
    final styles = GlassControlStyles.of(context);
    final content = DecoratedBox(
      decoration: styles.decoration(
        radius: radius,
        selected: selected,
        disabled: disabled,
        focused: focused,
        highContrast: contrast,
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: blur && !contrast && !disabled && GlassBlurScope.enabledOf(context)
          ? BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: GlassMetrics.controlBlur,
                sigmaY: GlassMetrics.controlBlur,
              ),
              child: content,
            )
          : content,
    );
  }
}

/// Semantic text and surface styles shared by app widgets. They are resolved
/// from ThemeData on every build so a new palette or font reaches existing UI.
class AppStyles {
  final ThemeData theme;
  final GlassColors colors;
  const AppStyles._(this.theme, this.colors);

  factory AppStyles.of(BuildContext context) =>
      AppStyles._(Theme.of(context), GlassPalette.of(context));

  bool get dark => theme.brightness == Brightness.dark;
  TextTheme get typography => theme.textTheme;
  TextStyle get body => typography.bodyMedium!;
  TextStyle get bodyLarge => typography.bodyLarge!;
  TextStyle get bodySmall => caption.copyWith(color: colors.text);
  TextStyle get caption => typography.bodySmall!;
  TextStyle get micro => caption.copyWith(fontSize: caption.fontSize! - 1);
  TextStyle get tiny => caption.copyWith(fontSize: caption.fontSize! - 2);
  TextStyle get sectionTitle => typography.titleLarge!.copyWith(
    fontSize: typography.titleLarge!.fontSize! - 1,
  );
  TextStyle get panelTitle => typography.titleLarge!.copyWith(
    fontSize: typography.titleLarge!.fontSize! + 1,
  );
  TextStyle get title14 => typography.titleMedium!;
  TextStyle get strong => body.copyWith(fontWeight: FontWeight.w600);
  TextStyle get muted => body.copyWith(color: colors.muted);
  TextStyle get secondary => bodyLarge.copyWith(color: colors.muted);
  TextStyle get accent => body.copyWith(color: colors.accent);
  TextStyle get error => body.copyWith(color: colors.danger);
  TextStyle get errorCaption => caption.copyWith(color: colors.danger);
  TextStyle get errorMicro => micro.copyWith(color: colors.danger);
  TextStyle get headline => typography.headlineMedium!;
  TextStyle get title => typography.titleLarge!;
  TextStyle get headerSubtitle => caption.copyWith(height: 1.6);
  TextStyle get toastLabel => body.copyWith(fontWeight: FontWeight.w500);
  TextStyle selectionLabel({required bool enabled}) => enabled ? body : muted;

  SystemUiOverlayStyle get systemOverlay =>
      (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
        statusBarColor: AppTheme.transparent,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarColor: colors.canvas,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      );

  RoundedRectangleBorder get toastShape => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(GlassMetrics.toast),
    side: BorderSide(color: colors.border),
  );

  Color surfaceFill({Color? tint, required bool highContrast}) =>
      highContrast ? colors.surface : tint ?? colors.glass;

  BoxDecoration surfaceDecoration({
    required double radius,
    required Color fill,
    required bool highContrast,
  }) => BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          colors.surfaceHighlight.withValues(
            alpha: highContrast ? 0 : (dark ? .025 : .12),
          ),
          fill,
        ),
        fill,
      ],
    ),
  );

  Color surfaceBorder({required bool highContrast}) => highContrast
      ? colors.muted
      : colors.border.withValues(alpha: dark ? .8 : .9);

  BoxDecoration surfaceOuterDecoration({
    required double radius,
    required bool elevated,
  }) => BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    boxShadow: elevated
        ? [
            BoxShadow(
              color: colors.shadow.withValues(alpha: dark ? .16 : .06),
              blurRadius: 18,
              offset: const Offset(0, 4),
            ),
          ]
        : null,
  );

  ButtonStyle iconButton({required double size, required bool selected}) =>
      IconButton.styleFrom(
        minimumSize: Size.square(size),
        maximumSize: Size.square(size),
        padding: EdgeInsets.zero,
        foregroundColor: selected ? colors.accent : colors.text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.control),
        ),
      );
}

class _GlassSwitchAdaptation extends Adaptation<SwitchThemeData> {
  const _GlassSwitchAdaptation();

  @override
  SwitchThemeData adapt(ThemeData theme, SwitchThemeData defaultValue) =>
      defaultValue;
}
