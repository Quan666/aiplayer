import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/app_theme.dart';

export 'theme/app_theme.dart';

/// A compact confirmation that replaces previous feedback and expires on its own.
void showGlassSuccess(BuildContext context, String message) {
  final colors = GlassPalette.of(context);
  final styles = AppStyles.of(context);
  final style = styles.toastLabel;
  final maxWidth = (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 360.0);
  final label = TextPainter(
    text: TextSpan(text: message, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: (maxWidth - 60).clamp(0.0, maxWidth));
  final width = (label.width + 60).clamp(0.0, maxWidth);
  label.dispose();
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('glass-success-toast'),
        behavior: SnackBarBehavior.floating,
        width: width,
        duration: const Duration(seconds: 2),
        elevation: 6,
        backgroundColor: colors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: styles.toastShape,
        content: Row(
          children: [
            Icon(Icons.check_circle_rounded, size: 22, color: colors.success),
            const SizedBox(width: 10),
            Flexible(child: Text(message, style: style)),
          ],
        ),
      ),
    );
}

Future<T?> showGlassBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: isScrollControlled,
  useSafeArea: true,
  backgroundColor: AppTheme.transparent,
  barrierColor: GlassPalette.of(context).mediaScrim,
  sheetAnimationStyle: MotionScope.enabledOf(context)
      ? null
      : AnimationStyle.noAnimation,
  // Large moving sheets otherwise sample and blur the whole library on every
  // animation frame. Keep their shared shape and border on an opaque surface.
  builder: (context) => RepaintBoundary(
    child: GlassSurface(
      borderRadius: GlassMetrics.sheet,
      blur: 0,
      tint: GlassPalette.of(context).surface,
      child: GlassBlurScope(enabled: false, child: builder(context)),
    ),
  ),
);

class GlassBackground extends StatelessWidget {
  final Widget child;
  const GlassBackground({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppStyles.of(context).systemOverlay,
      child: ColoredBox(color: GlassPalette.of(context).canvas, child: child),
    );
  }
}

/// Blur stays inside rounded bounds; high contrast uses a solid surface.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius, blur;
  final Color? tint;
  final bool elevated;
  const GlassSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = GlassMetrics.card,
    this.blur = GlassMetrics.surfaceBlur,
    this.tint,
    this.elevated = false,
  });
  @override
  Widget build(BuildContext context) {
    final contrast = MediaQuery.highContrastOf(context);
    final styles = AppStyles.of(context);
    final radius = BorderRadius.circular(borderRadius);
    final fill = styles.surfaceFill(tint: tint, highContrast: contrast);
    final content = DecoratedBox(
      decoration: styles.surfaceDecoration(
        radius: borderRadius,
        fill: fill,
        highContrast: contrast,
      ),
      child: CustomPaint(
        foregroundPainter: _GlassEdgePainter(
          borderRadius,
          styles.surfaceBorder(highContrast: contrast),
          contrast,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    return DecoratedBox(
      decoration: styles.surfaceOuterDecoration(
        radius: borderRadius,
        elevated: elevated,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child:
            blur > 0 &&
                !contrast &&
                fill.a < 1 &&
                GlassBlurScope.enabledOf(context)
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: content,
              )
            : content,
      ),
    );
  }
}

class _GlassEdgePainter extends CustomPainter {
  final double radius;
  final Color color;
  final bool contrast;
  const _GlassEdgePainter(this.radius, this.color, this.contrast);
  @override
  void paint(Canvas canvas, Size size) {
    final width = contrast
        ? GlassMetrics.contrastEdgeWidth
        : GlassMetrics.edgeWidth;
    final rect = (Offset.zero & size).deflate(width / 2);
    if (rect.isEmpty) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius - width / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _GlassEdgePainter oldDelegate) =>
      radius != oldDelegate.radius ||
      color != oldDelegate.color ||
      contrast != oldDelegate.contrast;
}

class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.size = 44,
  });
  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      isSelected: selected,
      style: AppStyles.of(context)
          .iconButton(size: size, selected: selected)
          .merge(GlassControlStyles.of(context).button()),
      icon: Icon(icon, size: size > 50 ? 28 : 21),
    );
  }
}

class GlassHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const GlassHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppStyles.of(context).headline),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: AppStyles.of(context).headerSubtitle),
          ],
        ],
      );
      if (trailing == null) return label;
      if (box.maxWidth < 300 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.3) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [label, const SizedBox(height: 10), trailing!],
        );
      }
      return Row(
        children: [
          Expanded(child: label),
          const SizedBox(width: 12),
          trailing!,
        ],
      );
    },
  );
}

/// One switch for decorative motion, while media and danmaku keep their clocks.
class MotionScope extends InheritedWidget {
  final bool enabled;
  const MotionScope({super.key, required this.enabled, required super.child});
  static bool enabledOf(BuildContext context) =>
      (context.dependOnInheritedWidgetOfExactType<MotionScope>()?.enabled ??
          true) &&
      !MediaQuery.disableAnimationsOf(context);
  static Duration duration(BuildContext context, [int milliseconds = 200]) =>
      enabledOf(context) ? Duration(milliseconds: milliseconds) : Duration.zero;
  @override
  bool updateShouldNotify(MotionScope oldWidget) =>
      enabled != oldWidget.enabled;
}

class GlassOption<T> {
  final T value;
  final String label;
  final IconData? icon;
  const GlassOption(this.value, this.label, {this.icon});
}

Future<T?> showGlassChoice<T>({
  required BuildContext context,
  required String title,
  required T value,
  required List<GlassOption<T>> options,
}) {
  Widget contents(BuildContext sheet) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(sheet).height * .72,
      maxWidth: 440,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: AppStyles.of(sheet).title)),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(sheet),
              ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            children: [
              for (final option in options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    selected: option.value == value,
                    leading: option.icon == null
                        ? null
                        : Icon(option.icon, size: 20),
                    title: Text(option.label),
                    trailing: option.value == value
                        ? Icon(
                            Icons.check_rounded,
                            color: GlassPalette.of(sheet).accent,
                          )
                        : null,
                    onTap: () => Navigator.pop(sheet, option.value),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
  if (MediaQuery.sizeOf(context).width >= 600) {
    return showDialog<T>(
      context: context,
      builder: (sheet) => Dialog(child: contents(sheet)),
    );
  }
  return showGlassBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(top: false, child: contents(sheet)),
  );
}

/// A bounded selector with the same material, type and focus treatment as forms.
class GlassSelect<T> extends StatefulWidget {
  final String label;
  final T value;
  final List<GlassOption<T>> options;
  final ValueChanged<T> onChanged;
  final bool enabled;
  const GlassSelect({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
  });
  @override
  State<GlassSelect<T>> createState() => _GlassSelectState<T>();
}

class _GlassSelectState<T> extends State<GlassSelect<T>> {
  bool opened = false;
  Future<void> choose() async {
    if (!widget.enabled || opened) return;
    setState(() => opened = true);
    final next = await showGlassChoice<T>(
      context: context,
      title: widget.label,
      value: widget.value,
      options: widget.options,
    );
    if (!mounted) return;
    setState(() => opened = false);
    if (next != null) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.options
        .where((o) => o.value == widget.value)
        .firstOrNull;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      child: InkWell(
        onTap: widget.enabled ? choose : null,
        borderRadius: BorderRadius.circular(GlassMetrics.control),
        child: GlassControlBackground(
          focused: opened,
          disabled: !widget.enabled,
          child: InputDecorator(
            isFocused: opened,
            decoration: InputDecoration(
              labelText: widget.label,
              enabled: widget.enabled,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              suffixIcon: AnimatedRotation(
                turns: opened ? .5 : 0,
                duration: MotionScope.duration(context, 160),
                child: const Icon(Icons.expand_more_rounded),
              ),
            ),
            child: Text(
              selected?.label ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.of(
                context,
              ).selectionLabel(enabled: widget.enabled),
            ),
          ),
        ),
      ),
    );
  }
}

class GlassEntrance extends StatelessWidget {
  final Widget child;
  const GlassEntrance({super.key, required this.child});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MotionScope.duration(context, 240),
    curve: Curves.easeOutCubic,
    child: child,
    builder: (context, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, 6 * (1 - value)),
        child: child,
      ),
    ),
  );
}
