import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart';

/// Shared entry for player styling. Geometry lives here; visual values resolve
/// from the app's PlayerTokens so a theme replacement updates every overlay.
abstract final class PlayerTheme {
  static const menuMinWidth = 220.0;
  static const menuDefaultWidth = 360.0;
  static const menuMaxWidth = 400.0;
  static const audioMenuMaxWidth = 300.0;
  static const speedMenuWidth = 180.0;
  static const settingsMenuWidth = 280.0;
  static const settingsMenuMaxWidth = 300.0;
  static const settingsMenuInsets = EdgeInsets.fromLTRB(12, 12, 16, 90);
  static const settingsMenuHeightReserve = 8.0;
  static const advancedSettingsMaxHeight = 440.0;
  static const advancedSettingsContentPadding = EdgeInsets.fromLTRB(
    16,
    8,
    16,
    16,
  );
  static const menuMaxHeight = 420.0;
  static const menuGap = 8.0;
  static const menuRowHeight = 42.0;
  static const choiceRowHeight = 40.0;
  static const compactChoiceRowHeight = 36.0;
  static const choiceTrackRowHeight = 44.0;
  static const choiceRowWithSubtitleHeight = 56.0;
  static const playlistRowHeight = 48.0;
  static const choiceContentPadding = EdgeInsets.symmetric(horizontal: 16);
  static const choiceTilePadding = EdgeInsets.symmetric(
    horizontal: 8,
    vertical: 4,
  );
  static const choiceTitleGap = 4.0;
  static const choiceIconSize = 20.0;
  static const menuLabelPadding = 76.0;
  static const viewportInset = 12.0;
  static const controlsEntranceMilliseconds = 240;
  static const choiceMenuPadding = EdgeInsets.all(6);

  static const blurSigma = 14.0;
  static const glassEdgeWidth = .8;
  static final _cache = Expando<PlayerStyles>();
  static final _default = PlayerStyles(PlayerTokens.standard, 'NotoSansSC');
  static ThemeData get data => _default.data;
  static Color get fieldColor => _default.fieldColor;
  static Color get barrierColor => _default.barrierColor;

  /// Modal routes inherit the live app theme, then apply their player surface.
  /// Capturing the local player Theme would freeze an already-open menu's skin.
  static BuildContext routeContext(BuildContext context) =>
      Navigator.of(context, rootNavigator: true).context;

  static PlayerStyles of(BuildContext context) {
    final theme = Theme.of(context);
    return _cache[theme] ??= PlayerStyles(
      theme.extension<PlayerTokens>() ?? PlayerTokens.standard,
      theme.textTheme.bodyMedium?.fontFamily,
      colors: GlassPalette.of(context),
      textTheme: theme.textTheme,
    );
  }

  static Widget surface(Widget child) => Builder(
    builder: (context) {
      final style = of(context);
      final theme = MediaQuery.highContrastOf(context)
          ? style.highContrastData
          : style.data;
      _cache[theme] = style;
      return Theme(
        data: theme,
        child: DefaultTextStyle(
          style: theme.textTheme.bodyMedium!,
          child: child,
        ),
      );
    },
  );
}

/// All controls and modal routes opened by playback use this palette, even
/// when the surrounding library uses the light theme.
class PlayerStyles {
  // Keep player colors, material, typography, and control geometry here. A
  // surface's opacity is independent of whether it uses a backdrop blur.
  final PlayerTokens tokens;
  final String? fontFamily;
  final GlassColors colors;
  final TextTheme? textTheme;
  PlayerStyles(
    this.tokens,
    this.fontFamily, {
    this.colors = GlassColors.dark,
    this.textTheme,
  });

  Color get foreground => tokens.foreground;
  late final secondaryForeground = foreground.withAlpha(179);
  late final mutedForeground = foreground.withAlpha(153);
  late final faintForeground = foreground.withAlpha(97);
  late final disabledForeground = foreground.withAlpha(77);
  Color get videoBackground => tokens.videoBackground;
  Color get canvasColor => tokens.tint;
  late final surfaceColor = tokens.tint.withAlpha(
    (184 * tokens.opacity).round(),
  );
  late final barrierColor = tokens.shadow.withAlpha(20);
  late final fieldColor = tokens.tint.withAlpha(40);
  late final outlineColor = foreground.withAlpha(61);
  late final dividerColor = foreground.withAlpha(31);
  late final selectedColor = foreground.withAlpha(24);
  late final buttonColor = foreground.withAlpha(38);
  late final subtleButtonColor = tokens.tint.withAlpha(20);
  late final disabledColor = foreground.withAlpha(26);
  late final previewPlaceholderColor = tokens.tint.withAlpha(136);
  late final previewLoadingColor = tokens.tint.withAlpha(170);
  double get controlRadius => tokens.controlRadius;
  double get glassRadius => tokens.glassRadius;
  double get panelRadius => tokens.panelRadius;

  SystemUiOverlayStyle get systemOverlay => SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: videoBackground,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: videoBackground,
  );

  BoxDecoration glassDecoration({
    required double radius,
    required bool highContrast,
  }) => BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    gradient: highContrast ? opaqueGlassGradient : glassGradient,
  );
  late final shadeDecoration = BoxDecoration(gradient: shadeGradient);
  late final sheetHandleDecoration = BoxDecoration(
    color: outlineColor,
    borderRadius: BorderRadius.circular(GlassMetrics.progress),
  );

  late final glassGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    stops: [0, .48, 1],
    colors: [
      tokens.highlight.withAlpha((158 * tokens.opacity).round()),
      surfaceColor,
      tokens.shade.withAlpha((204 * tokens.opacity).round()),
    ],
  );
  late final opaqueGlassGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    stops: [0, .48, 1],
    colors: [tokens.highlight, canvasColor, tokens.shade],
  );
  late final edgeGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    stops: [0, .34, .7, 1],
    colors: [
      foreground.withAlpha(128),
      selectedColor,
      foreground.withAlpha(8),
      foreground.withAlpha(64),
    ],
  );
  late final shadeGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0, .22, .60, 1],
    colors: [
      tokens.shadow.withAlpha(102),
      Colors.transparent,
      Colors.transparent,
      tokens.shadow.withAlpha(119),
    ],
  );
  late final iconShadows = [
    Shadow(
      color: tokens.shadow.withAlpha(115),
      blurRadius: 4,
      offset: Offset(0, 1),
    ),
  ];
  late final textShadows = [
    Shadow(color: tokens.shadow.withAlpha(138), blurRadius: 8),
  ];
  late final panelTitleStyle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: foreground,
  );
  late final dialogTitleStyle = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w600,
    color: foreground,
  );
  late final selectedLabelStyle = TextStyle(fontWeight: FontWeight.w600);
  late final optionLabelStyle = TextStyle(color: foreground, fontSize: 14);
  late final optionValueStyle = TextStyle(color: mutedForeground, fontSize: 12);
  late final captionStyle = optionValueStyle;
  late final smallLabelStyle = TextStyle(fontSize: 12);
  late final trackLabelStyle = TextStyle(fontSize: 13);
  late final mutedStyle = TextStyle(color: mutedForeground);
  late final timelineLabelStyle = TextStyle(
    color: foreground,
    fontSize: 11,
    fontFeatures: [ui.FontFeature.tabularFigures()],
  );
  late final seekTimeStyle = TextStyle(
    fontSize: 34,
    color: foreground,
    fontWeight: FontWeight.w300,
    fontFeatures: [ui.FontFeature.tabularFigures()],
    shadows: textShadows,
  );
  TextStyle mediaTitleStyle({required bool compact}) => TextStyle(
    color: foreground,
    fontSize: compact ? 17 : 22,
    height: 1.25,
    fontWeight: FontWeight.w600,
    shadows: textShadows,
  );
  TextStyle playlistItemStyle({required bool selected}) => TextStyle(
    fontSize: 14,
    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
  );
  late final playlistProgressStyle = TextStyle(
    color: mutedForeground,
    fontSize: 11,
  );
  late final volumeLabelStyle = TextStyle(color: foreground, fontSize: 10);

  late final ThemeData data = _build(highContrast: false);
  late final ThemeData highContrastData = _build(highContrast: true);
  late final timelineSliderTheme = data.sliderTheme.copyWith(
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4),
    overlayColor: foreground.withAlpha(20),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
    trackShape: RoundedRectSliderTrackShape(),
  );
  late final volumeSliderTheme = data.sliderTheme.copyWith(
    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4),
    overlayShape: RoundSliderOverlayShape(overlayRadius: 10),
  );

  ButtonStyle get filledIconButtonStyle => data.iconButtonTheme.style!.copyWith(
    backgroundBuilder: data.filledButtonTheme.style!.backgroundBuilder,
  );

  ButtonStyle controlButtonStyle(double size) =>
      IconButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: Size.square(size),
        maximumSize: Size.square(size),
        disabledForegroundColor: disabledForeground,
        padding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        side: BorderSide.none,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ).copyWith(
        // The enclosing PlayerGlass supplies the material for a control group.
        backgroundBuilder: (context, states, child) =>
            child ?? const SizedBox.shrink(),
      );

  ThemeData _build({required bool highContrast}) {
    final base = GlassPalette.theme(
      brightness: Brightness.dark,
      colors: colors,
      player: tokens,
      fontFamily: fontFamily ?? 'NotoSansSC',
      textTheme: textTheme,
    );
    final materialColor = highContrast ? canvasColor : surfaceColor;
    final playerColors = colors.copyWith(
      canvas: canvasColor,
      text: foreground,
      muted: mutedForeground,
      accent: foreground,
      blue: foreground,
      surface: materialColor,
      border: outlineColor,
      field: fieldColor,
      selected: highContrast
          ? Color.alphaBlend(selectedColor, canvasColor)
          : selectedColor,
      glass: materialColor,
      navigationSurface: surfaceColor,
      surfaceHighlight: foreground,
      onAccent: canvasColor,
      switchTrack: dividerColor,
      switchThumb: foreground,
    );
    // Share the material without adding per-button filters over moving video.
    final controls = GlassControlStyles(
      colors: playerColors,
      dark: true,
      contrast: highContrast,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(controlRadius),
    );
    final panelShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(panelRadius),
      side: BorderSide(color: outlineColor),
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(controlRadius),
      borderSide: BorderSide(color: outlineColor),
    );
    return base.copyWith(
      visualDensity: VisualDensity.compact,
      colorScheme: base.colorScheme.copyWith(
        primary: foreground,
        onPrimary: canvasColor,
        secondary: secondaryForeground,
        primaryContainer: selectedColor,
        onPrimaryContainer: foreground,
        secondaryContainer: fieldColor,
        onSecondaryContainer: foreground,
        surface: materialColor,
        surfaceDim: materialColor,
        surfaceBright: materialColor,
        surfaceContainerLowest: materialColor,
        surfaceContainerLow: materialColor,
        surfaceContainer: materialColor,
        surfaceContainerHigh: materialColor,
        surfaceContainerHighest: materialColor,
        onSurface: foreground,
        onSurfaceVariant: mutedForeground,
        outline: outlineColor,
        outlineVariant: dividerColor,
      ),
      textTheme: base.textTheme
          .apply(bodyColor: foreground, displayColor: foreground)
          .copyWith(
            bodySmall: base.textTheme.bodySmall?.copyWith(
              color: mutedForeground,
            ),
          ),
      extensions: [tokens, playerColors],
      iconTheme: IconThemeData(color: secondaryForeground, size: 22),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: fieldColor,
        labelStyle: TextStyle(color: secondaryForeground),
        hintStyle: TextStyle(color: faintForeground),
        prefixIconColor: mutedForeground,
        suffixIconColor: mutedForeground,
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: secondaryForeground),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: foreground,
        selectionColor: outlineColor,
        selectionHandleColor: foreground,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style:
            FilledButton.styleFrom(
              foregroundColor: foreground,
              backgroundColor: Colors.transparent,
              disabledForegroundColor: disabledForeground,
              disabledBackgroundColor: Colors.transparent,
              minimumSize: Size(44, 42),
              shape: shape,
            ).merge(
              controls.button(
                primary: true,
                blur: false,
                radius: controlRadius,
              ),
            ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          backgroundColor: Colors.transparent,
          disabledForegroundColor: disabledForeground,
          disabledBackgroundColor: Colors.transparent,
          minimumSize: Size(44, 42),
          shape: shape,
        ).merge(controls.button(blur: false, radius: controlRadius)),
      ),
      textButtonTheme: TextButtonThemeData(
        style:
            TextButton.styleFrom(
              foregroundColor: foreground,
              disabledForegroundColor: disabledForeground,
              shape: shape,
            ).merge(
              controls.button(quiet: true, blur: false, radius: controlRadius),
            ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style:
            IconButton.styleFrom(
              foregroundColor: foreground,
              disabledForegroundColor: disabledForeground,
              padding: const EdgeInsets.all(8),
              shape: shape,
            ).merge(
              controls.button(quiet: true, blur: false, radius: controlRadius),
            ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: foreground,
        inactiveTrackColor: outlineColor,
        thumbColor: foreground,
        overlayColor: selectedColor,
        activeTickMarkColor: Colors.transparent,
        inactiveTickMarkColor: Colors.transparent,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        showValueIndicator: ShowValueIndicator.never,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledForeground
              : foreground,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => controls
              .border(
                selected: states.contains(WidgetState.selected),
                disabled: states.contains(WidgetState.disabled),
                focused: states.contains(WidgetState.focused),
                highContrast: highContrast,
              )
              .color,
        ),
        trackOutlineWidth: WidgetStatePropertyAll(highContrast ? 1.5 : 1),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => controls.fill(
            selected: states.contains(WidgetState.selected),
            disabled: states.contains(WidgetState.disabled),
            highContrast: highContrast,
          ),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minTileHeight: PlayerTheme.menuRowHeight,
        minVerticalPadding: 3,
        contentPadding: PlayerTheme.choiceContentPadding,
        iconColor: secondaryForeground,
        textColor: foreground,
        selectedColor: foreground,
        selectedTileColor: selectedColor,
        shape: shape,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: foreground,
        unselectedLabelColor: mutedForeground,
        labelStyle: optionLabelStyle.merge(selectedLabelStyle),
        unselectedLabelStyle: optionLabelStyle,
        indicatorColor: foreground,
        dividerColor: dividerColor,
        overlayColor: WidgetStatePropertyAll(selectedColor),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: materialColor,
        barrierColor: barrierColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: panelShape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: materialColor,
        surfaceTintColor: Colors.transparent,
        shape: panelShape,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: materialColor,
        surfaceTintColor: Colors.transparent,
        shape: shape.copyWith(side: BorderSide(color: outlineColor)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: materialColor,
          borderRadius: BorderRadius.circular(controlRadius),
          border: Border.all(color: outlineColor),
        ),
        textStyle: captionStyle.copyWith(color: foreground),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(shape),
          side: WidgetStateProperty.resolveWith(
            (states) => controls.border(
              selected: states.contains(WidgetState.selected),
              disabled: states.contains(WidgetState.disabled),
              focused: states.contains(WidgetState.focused),
              highContrast: highContrast,
            ),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? disabledForeground
                : foreground,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => controls.fill(
              selected: states.contains(WidgetState.selected),
              disabled: states.contains(WidgetState.disabled),
              highContrast: highContrast,
            ),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: controls.fill(highContrast: highContrast),
        selectedColor: controls.fill(
          selected: true,
          highContrast: highContrast,
        ),
        disabledColor: controls.fill(
          disabled: true,
          highContrast: highContrast,
        ),
        labelStyle: TextStyle(color: foreground, fontSize: 12),
        side: controls.border(highContrast: highContrast),
        shape: shape,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 2,
        backgroundColor: materialColor,
        contentTextStyle: TextStyle(color: foreground),
        actionTextColor: foreground,
        shape: panelShape,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: secondaryForeground,
        linearTrackColor: dividerColor,
      ),
      dividerColor: dividerColor,
    );
  }
}
