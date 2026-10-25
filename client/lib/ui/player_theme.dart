import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'glass.dart';
import 'theme/player_style.dart';
export 'theme/player_style.dart';

class PlayerGlass extends StatelessWidget {
  // The filter is immutable and shared: timeline/volume changes must not
  // allocate a new blur operation or replace the backdrop render object.
  static final _blur = ui.ImageFilter.blur(
    sigmaX: PlayerTheme.blurSigma,
    sigmaY: PlayerTheme.blurSigma,
  );
  final Widget child;
  final double? radius;

  /// A playing texture changes every frame. Blur requires sampling that texture
  /// for each control capsule even when the controls themselves are unchanged.
  /// Keep the translucent material without that work unless explicitly requested.
  final bool blur;
  const PlayerGlass({
    super.key,
    required this.child,
    this.radius,
    this.blur = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = PlayerTheme.of(context);
    final radius = this.radius ?? style.glassRadius;
    final highContrast = MediaQuery.highContrastOf(context);
    final filtered = blur && !highContrast;
    final content = DecoratedBox(
      decoration: style.glassDecoration(
        radius: radius,
        highContrast: highContrast,
      ),
      child: CustomPaint(
        foregroundPainter: _PlayerGlassEdge(radius, style.edgeGradient),
        child: child,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: blur
          ? BackdropFilter(enabled: filtered, filter: _blur, child: content)
          : content,
    );
  }
}

class _PlayerGlassEdge extends CustomPainter {
  final double radius;
  final Gradient gradient;
  const _PlayerGlassEdge(this.radius, this.gradient);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(PlayerTheme.glassEdgeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = PlayerTheme.glassEdgeWidth
      ..shader = gradient.createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_PlayerGlassEdge oldDelegate) =>
      radius != oldDelegate.radius || gradient != oldDelegate.gradient;
}

/// Shared rows keep every compact choice menu aligned with the playlist.
class PlayerChoiceTile extends StatelessWidget {
  final Widget title;
  final Widget? subtitle, leading, trailing;
  final bool selected;
  final VoidCallback? onTap;

  const PlayerChoiceTile({
    super.key,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.onTap,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final style = PlayerTheme.of(context);
    final radius = BorderRadius.circular(style.controlRadius);
    final marker =
        trailing ?? (selected ? const Icon(Icons.check_rounded) : null);
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? style.selectedColor : Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: subtitle == null
                  ? PlayerTheme.choiceRowHeight
                  : PlayerTheme.choiceRowWithSubtitleHeight,
            ),
            child: Padding(
              padding: PlayerTheme.choiceTilePadding,
              child: IconTheme.merge(
                data: IconThemeData(
                  color: selected
                      ? style.foreground
                      : style.secondaryForeground,
                  size: PlayerTheme.choiceIconSize,
                ),
                child: Stack(
                  alignment: AlignmentDirectional.centerStart,
                  children: [
                    // Center the text block vertically; reserve only the icon space.
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        start: leading == null
                            ? 0
                            : PlayerTheme.choiceIconSize +
                                  PlayerTheme.choiceTitleGap,
                        end:
                            PlayerTheme.choiceIconSize +
                            PlayerTheme.choiceTitleGap,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DefaultTextStyle.merge(
                            style: style.optionLabelStyle
                                .merge(
                                  selected ? style.selectedLabelStyle : null,
                                )
                                .copyWith(height: 1.2),
                            textAlign: TextAlign.start,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            child: title,
                          ),
                          if (subtitle != null)
                            DefaultTextStyle.merge(
                              style: style.optionValueStyle.copyWith(
                                height: 1.2,
                              ),
                              textAlign: TextAlign.start,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              child: subtitle!,
                            ),
                        ],
                      ),
                    ),
                    if (leading != null)
                      PositionedDirectional(start: 0, child: leading!),
                    if (marker != null)
                      PositionedDirectional(end: 0, child: marker),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation and diagnostic dialogs use the same material as player menus.
class PlayerDialog extends StatelessWidget {
  final Widget title, content;
  final List<Widget> actions;
  const PlayerDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(
        Radius.circular(PlayerTheme.of(context).panelRadius),
      ),
    ),
    constraints: const BoxConstraints(maxWidth: 520),
    child: PlayerGlass(
      radius: PlayerTheme.of(context).panelRadius,
      blur: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DefaultTextStyle.merge(
              style: PlayerTheme.of(context).dialogTitleStyle,
              child: title,
            ),
            const SizedBox(height: 18),
            content,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 20),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// A player selector keeps nested choices on the player's glass surface.
class PlayerSelect<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<GlassOption<T>> options;
  final ValueChanged<T> onChanged;
  final int maxLines;
  const PlayerSelect({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.maxLines = 2,
  }) : assert(maxLines == 1 || maxLines == 2);

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(PlayerTheme.of(context).controlRadius),
    onTap: () async {
      final selected = await showModalBottomSheet<T>(
        context: PlayerTheme.routeContext(context),
        backgroundColor: Colors.transparent,
        barrierColor: PlayerTheme.of(context).barrierColor,
        isScrollControlled: true,
        builder: (c) => PlayerSheet(
          child: PlayerMenuList(
            padding: PlayerTheme.choiceMenuPadding,
            selectedIndex:
                options.indexWhere((option) => option.value == value) + 1,
            itemExtent: PlayerTheme.choiceExtent(c, twoLines: maxLines > 1),
            itemCount: options.length + 1,
            itemBuilder: (_, index) {
              if (index == 0) {
                return PlayerChoiceTile(
                  title: Text(
                    label,
                    style: PlayerTheme.of(context).selectedLabelStyle,
                  ),
                );
              }
              final option = options[index - 1];
              return PlayerChoiceTile(
                title: Text(
                  option.label,
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: option.value == value,
                onTap: () => Navigator.pop(c, option.value),
              );
            },
          ),
        ),
      );
      if (context.mounted && selected != null) onChanged(selected);
    },
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.expand_more_rounded),
      ),
      child: Text(
        options.where((option) => option.value == value).firstOrNull?.label ??
            '',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// Short menus fit their contents; long menus use a bounded, lazy viewport.
class PlayerMenuList extends StatefulWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final int? selectedIndex;
  final double? itemExtent;

  const PlayerMenuList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.selectedIndex,
    this.itemExtent,
  });

  @override
  State<PlayerMenuList> createState() => _PlayerMenuListState();
}

class _PlayerMenuListState extends State<PlayerMenuList> {
  ScrollController? _scroll;
  Object? _selectionLayout;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Choice menus use a predictable extent so even the thousandth selected
      // episode opens at the center without constructing all preceding rows.
      final extent = widget.itemExtent;
      final padding = widget.padding.resolve(Directionality.of(context));
      final height =
          widget.itemCount * (extent ?? PlayerTheme.menuRowHeight) +
          padding.vertical;
      final viewport = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : height;
      final selected = widget.selectedIndex;
      final offset = selected == null || selected < 0 || extent == null
          ? 0.0
          : (padding.top + (selected + .5) * extent - viewport / 2).clamp(
              0.0,
              (height - viewport).clamp(0.0, double.infinity),
            );
      _scroll ??= ScrollController(initialScrollOffset: offset);
      final layout = (selected, widget.itemCount, extent, viewport, padding);
      if (_selectionLayout != layout && _scroll!.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectionLayout == layout && _scroll!.hasClients) {
            _scroll!.jumpTo(offset.clamp(0, _scroll!.position.maxScrollExtent));
          }
        });
      }
      _selectionLayout = layout;
      return ListView.builder(
        controller: _scroll,
        primary: false,
        shrinkWrap: !constraints.hasBoundedHeight || height <= viewport,
        padding: widget.padding,
        itemExtent: extent,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      );
    },
  );
}

/// Variable-height subtitle tools precede the track choices. Their scroll view
/// lays out all tracks once, so the selected row can use its measured position.
class PlayerScrollToSelection extends StatefulWidget {
  final bool selected;
  final Widget child;
  const PlayerScrollToSelection({
    super.key,
    required this.selected,
    required this.child,
  });
  @override
  State<PlayerScrollToSelection> createState() =>
      _PlayerScrollToSelectionState();
}

class _PlayerScrollToSelectionState extends State<PlayerScrollToSelection> {
  @override
  void initState() {
    super.initState();
    _center();
  }

  @override
  void didUpdateWidget(PlayerScrollToSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.selected && widget.selected) _center();
  }

  void _center() {
    if (!widget.selected) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.selected) {
        Scrollable.ensureVisible(context, alignment: .5);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

double playerMenuWidth(BuildContext context, Iterable<String> labels) {
  var width = PlayerTheme.menuMinWidth;
  final painter = TextPainter(
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  );
  for (final label in labels) {
    painter.text = TextSpan(
      text: label,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.merge(PlayerTheme.of(context).optionLabelStyle),
    );
    painter.layout();
    width = (painter.width + PlayerTheme.menuLabelPadding).clamp(
      width,
      PlayerTheme.menuMaxWidth,
    );
    if (width == PlayerTheme.menuMaxWidth) break;
  }
  painter.dispose();
  return width;
}

class PlayerSheet extends StatelessWidget {
  final Widget child;
  const PlayerSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available =
        (media.size.height -
                media.viewInsets.bottom -
                media.padding.vertical -
                40)
            .clamp(0.0, media.size.height * .84);
    return PlayerTheme.surface(
      SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            PlayerTheme.viewportInset,
            0,
            PlayerTheme.viewportInset,
            PlayerTheme.viewportInset + media.viewInsets.bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 640, maxHeight: available),
            child: PlayerGlass(
              radius: PlayerTheme.of(context).panelRadius,
              // A large scrolling panel should not blur every video frame.
              blur: false,
              child: Material(
                color: Colors.transparent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (available >= 24)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Container(
                          width: 34,
                          height: 4,
                          decoration: PlayerTheme.of(
                            context,
                          ).sheetHandleDecoration,
                        ),
                      ),
                    Flexible(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The settings panel retains its original bottom-right position.
Future<T?> showPlayerSettingsMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showDialog<T>(
  context: PlayerTheme.routeContext(context),
  useSafeArea: false,
  barrierColor: PlayerTheme.of(context).barrierColor,
  builder: (context) => PlayerTheme.surface(
    SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          const original = PlayerTheme.settingsMenuInsets;
          // Preserve the familiar position at normal sizes while allowing
          // the menu to remain within a short landscape or resized window.
          final insets = EdgeInsets.fromLTRB(
            original.left.clamp(0.0, constraints.maxWidth / 4),
            original.top.clamp(0.0, constraints.maxHeight / 10),
            original.right.clamp(0.0, constraints.maxWidth / 4),
            original.bottom.clamp(0.0, constraints.maxHeight / 3),
          );
          final height =
              (constraints.maxHeight -
                      insets.vertical -
                      PlayerTheme.settingsMenuHeightReserve)
                  .clamp(0.0, double.infinity);
          return Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: insets,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: PlayerTheme.settingsMenuMaxWidth,
                  maxHeight: height,
                ),
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  removeTop: true,
                  removeRight: true,
                  removeBottom: true,
                  child: Builder(
                    builder: (context) => PlayerGlass(
                      radius: PlayerTheme.of(context).panelRadius,
                      blur: false,
                      child: Material(
                        color: Colors.transparent,
                        child: builder(context),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  ),
);

/// A compact player menu positioned above the actual triggering control.
Future<T?> showPlayerPopover<T>({
  required BuildContext context,
  required GlobalKey anchor,
  required WidgetBuilder builder,
  double width = PlayerTheme.menuDefaultWidth,
}) {
  final overlay = Navigator.of(context, rootNavigator: true).overlay!;
  final overlayBox = overlay.context.findRenderObject()! as RenderBox;
  final anchorBox = anchor.currentContext?.findRenderObject() as RenderBox?;
  final bounds = anchorBox == null
      ? Rect.fromLTWH(
          overlayBox.size.width - 60,
          overlayBox.size.height - 80,
          44,
          44,
        )
      : anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
            anchorBox.size;
  return showDialog<T>(
    context: PlayerTheme.routeContext(context),
    useSafeArea: false,
    barrierColor: PlayerTheme.of(context).barrierColor,
    builder: (context) => PlayerTheme.surface(
      CustomSingleChildLayout(
        delegate: _PlayerPopoverLayout(
          anchor: bounds,
          padding:
              MediaQuery.paddingOf(context) +
              const EdgeInsets.all(PlayerTheme.viewportInset),
          width: width,
        ),
        // The layout delegate already keeps the whole popup inside the safe
        // area. ListTile has its own SafeArea, so consume these screen insets
        // before building the contents instead of applying the notch twice.
        child: MediaQuery.removePadding(
          context: context,
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          child: Builder(
            builder: (context) => PlayerGlass(
              radius: PlayerTheme.of(context).panelRadius,
              blur: false,
              child: Material(
                color: Colors.transparent,
                child: builder(context),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PlayerPopoverLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final EdgeInsets padding;
  final double width;
  const _PlayerPopoverLayout({
    required this.anchor,
    required this.padding,
    required this.width,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxWidth = (constraints.maxWidth - padding.horizontal).clamp(
      0.0,
      width,
    );
    final above = (anchor.top - padding.top - PlayerTheme.menuGap).clamp(
      0.0,
      PlayerTheme.menuMaxHeight,
    );
    final below =
        (constraints.maxHeight -
                padding.bottom -
                anchor.bottom -
                PlayerTheme.menuGap)
            .clamp(0.0, PlayerTheme.menuMaxHeight);
    return BoxConstraints(
      minWidth: maxWidth,
      maxWidth: maxWidth,
      maxHeight: above > below ? above : below,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (anchor.right - childSize.width).clamp(
      padding.left,
      (size.width - padding.right - childSize.width).clamp(
        padding.left,
        double.infinity,
      ),
    ),
    (childSize.height <= anchor.top - padding.top - PlayerTheme.menuGap
            ? anchor.top - childSize.height - PlayerTheme.menuGap
            : anchor.bottom + PlayerTheme.menuGap)
        .clamp(
          padding.top,
          (size.height - padding.bottom - childSize.height).clamp(
            padding.top,
            double.infinity,
          ),
        ),
  );

  @override
  bool shouldRelayout(_PlayerPopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      width != oldDelegate.width;
}
