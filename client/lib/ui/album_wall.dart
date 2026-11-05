import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter/rendering.dart'
    show
        ScrollCacheExtent,
        SliverConstraints,
        SliverGridLayout,
        SliverGridGeometry;

import '../data/album_catalog.dart';
import 'remote_control.dart';
import 'television_input.dart';

/// Applies a saved viewport during layout, before any frame can show the
/// previous directory's scroll position. Only the latest request is retained.
class AlbumScrollController extends ScrollController {
  double? Function()? _restore;

  bool get restoring => _restore != null;

  void restoreOnNextLayout(double? Function() offset) {
    _restore = offset;
    if (hasClients && position is ScrollPositionWithSingleContext) {
      (position as ScrollPositionWithSingleContext).goIdle();
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _AlbumScrollPosition(
    controller: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

class _AlbumScrollPosition extends ScrollPositionWithSingleContext {
  final AlbumScrollController controller;

  _AlbumScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.oldPosition,
  }) : super(initialPixels: 0);

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final restore = controller._restore;
    if (restore != null) {
      controller._restore = null;
      final requested = restore();
      if (requested != null && requested.isFinite) {
        final target = requested.clamp(minScrollExtent, maxScrollExtent);
        if ((target - pixels).abs() > .01) {
          correctPixels(target);
          // The viewport repeats layout immediately with the restored pixels.
          return false;
        }
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// A lazy, edge-to-edge wall. Focus nodes exist only for mounted cells.
class AlbumWall extends StatefulWidget {
  final AlbumSnapshot snapshot;
  final ScrollController controller;
  final int columns;
  final EdgeInsets padding;
  final Widget Function(BuildContext, AlbumItem, int) thumbnail;
  final ValueChanged<AlbumItem> onOpen;
  final ValueChanged<AlbumItem>? onMenu;
  final bool active;

  const AlbumWall({
    super.key,
    required this.snapshot,
    required this.controller,
    required this.thumbnail,
    required this.onOpen,
    this.onMenu,
    this.columns = 4,
    this.padding = EdgeInsets.zero,
    this.active = true,
  });

  @override
  State<AlbumWall> createState() => AlbumWallState();
}

class AlbumWallState extends State<AlbumWall> {
  final _nodes = <int, FocusNode>{};
  int _focused = 0, _columns = 1, _focusRevision = 0, _restoreRevision = 0;
  String? _focusedId;
  int? _navigationColumn;
  double _cellExtent = 160;
  double _rowExtent = 161.5;
  _AlbumGridLayout? _layout;

  int get anchorIndex => widget.controller.hasClients
      ? _layout?.itemIndexForChild(
              _layout!.getMinChildIndexForScrollOffset(
                widget.controller.offset,
              ),
            ) ??
            0
      : _focused;
  String? get focusedId => _focusedId;

  double itemScrollOffset(int index) {
    if (widget.snapshot.items.isEmpty) return 0;
    final target = index.clamp(0, widget.snapshot.items.length - 1);
    return _layout?.offsetForItem(target) ?? (target ~/ _columns) * _rowExtent;
  }

  void restoreIndex(
    int index, {
    bool focus = false,
    double relativeOffset = 0,
    bool onlyWhenIdle = false,
  }) {
    final controller = widget.controller;
    if (controller is AlbumScrollController) {
      if (onlyWhenIdle &&
          controller.hasClients &&
          controller.position.isScrollingNotifier.value) {
        return;
      }
      final ticket = ++_focusRevision;
      controller.restoreOnNextLayout(() {
        if (!mounted || ticket != _focusRevision) return null;
        if (onlyWhenIdle &&
            controller.hasClients &&
            controller.position.isScrollingNotifier.value) {
          return null;
        }
        return itemScrollOffset(index) + relativeOffset;
      });
      setState(() => _restoreRevision++);
      if (focus) _focusAfterLayout(index, ticket);
      return;
    }
    if (widget.snapshot.items.isEmpty) return;
    final target = index.clamp(0, widget.snapshot.items.length - 1);
    final ticket = ++_focusRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ticket != _focusRevision || !widget.active) return;
      if (widget.controller.hasClients) {
        final position = widget.controller.position;
        if (onlyWhenIdle && position.isScrollingNotifier.value) return;
        widget.controller.jumpTo(
          (itemScrollOffset(target) + relativeOffset).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
      }
      if (focus) _focusAfterLayout(target, ticket);
    });
    // Phone commands can arrive while the app has no scheduled frame. A
    // post-frame callback alone would leave the old cell focused indefinitely.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Restore focus without snapping a touch-scrolled wall to a row boundary.
  void restoreViewport(double offset, {String? focusedId}) {
    final ticket = ++_focusRevision;
    final controller = widget.controller;
    if (controller.hasClients &&
        (controller.offset - offset).abs() <= .01 &&
        !(controller is AlbumScrollController && controller.restoring)) {
      final index = widget.snapshot.indexById[focusedId];
      if (index != null && _nodes[index]?.hasFocus == false) {
        _focusAfterLayout(index, ticket);
      }
      return;
    }
    if (controller is AlbumScrollController) {
      controller.restoreOnNextLayout(() => offset);
      setState(() => _restoreRevision++);
      if (focusedId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || ticket != _focusRevision || !widget.active) return;
          final index = widget.snapshot.indexById[focusedId];
          if (index != null) _nodes[index]?.requestFocus();
        });
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ticket != _focusRevision || !widget.active) return;
      if (widget.controller.hasClients &&
          (widget.controller.offset - offset).abs() > .01) {
        widget.controller.jumpTo(
          offset.clamp(0.0, widget.controller.position.maxScrollExtent),
        );
      }
      final index = widget.snapshot.indexById[focusedId];
      if (index != null) _nodes[index]?.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _focusAfterLayout(int index, int ticket) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ticket == _focusRevision && widget.active) {
        _nodes[index]?.requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.active || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final delta = switch (key) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      LogicalKeyboardKey.arrowUp => -_columns,
      LogicalKeyboardKey.arrowDown => _columns,
      _ => 0,
    };
    return _move(
          delta,
          vertical:
              key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.arrowDown,
        )
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  bool _move(int delta, {bool vertical = false}) {
    if (!widget.active) return false;
    if (delta == 0 || widget.snapshot.items.isEmpty) {
      return false;
    }
    _focused = widget.snapshot.indexById[_focusedId] ?? _focused;
    final layout = _layout;
    if (!vertical) _navigationColumn = null;
    if (vertical && layout != null) {
      _navigationColumn ??= layout.columnForItem(_focused);
    }
    final next = vertical && layout != null
        ? layout.verticalNeighbor(
            _focused,
            delta.sign,
            column: _navigationColumn!,
          )
        : _focused + delta;
    // Allow up from the first row to reach the toolbar.
    if (next < 0 || next >= widget.snapshot.items.length) {
      return false;
    }
    _focused = next;
    _focusedId = widget.snapshot.items[next].id;
    final target = _nodes[next];
    if (target != null) {
      target.requestFocus();
      if (widget.controller.hasClients) {
        final position = widget.controller.position;
        // The wall paints beneath the toolbar, but keyboard/TV focus must
        // stay inside the unobscured interaction area. These offsets come
        // from the existing grid layout, without walking mounted children.
        final top = widget.padding.top + itemScrollOffset(next);
        final bottom = top + _cellExtent;
        final visibleTop = position.pixels + widget.padding.top;
        final visibleBottom =
            position.pixels +
            position.viewportDimension -
            widget.padding.bottom;
        final requested = top < visibleTop
            ? top - widget.padding.top
            : bottom > visibleBottom
            ? bottom - position.viewportDimension + widget.padding.bottom
            : position.pixels;
        final offset = requested.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((offset - position.pixels).abs() > .01) {
          widget.controller.jumpTo(offset);
        }
      }
    } else {
      restoreIndex(next, focus: true);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _columns = widget.columns.clamp(1, 24);
      const gap = 1.5;
      _cellExtent = (constraints.maxWidth - gap * (_columns - 1)) / _columns;
      _rowExtent = _cellExtent + gap;
      final layout = _layout = _AlbumGridLayout(
        widget.snapshot.wallSections,
        _columns,
        _cellExtent,
        gap,
      );
      final pixels = (_cellExtent * MediaQuery.devicePixelRatioOf(context))
          .ceil()
          .clamp(64, 1024);
      return RemoteControlTarget(
        onCommand: (command) {
          if (!command.isCurrent || !widget.active) {
            return RemoteCommandResult.unavailable;
          }
          final delta = switch (command.action) {
            'left' => -1,
            'right' => 1,
            'up' => -_columns,
            'down' => _columns,
            _ => 0,
          };
          return _move(
                delta,
                vertical: command.action == 'up' || command.action == 'down',
              )
              ? const RemoteCommandResult(true)
              : null;
        },
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: _key,
          child: GridView.builder(
            key: const ValueKey('album-wall'),
            controller: widget.controller,
            padding: widget.padding,
            scrollCacheExtent: const ScrollCacheExtent.viewport(1),
            gridDelegate: _AlbumGridDelegate(layout, _restoreRevision),
            itemCount: layout.sections.childCount,
            findChildIndexCallback: (key) => key is ValueKey<String>
                ? layout.childIndexForId(widget.snapshot, key.value)
                : null,
            itemBuilder: (context, childIndex) {
              final section = layout.sectionForChild(childIndex);
              if (section.hasHeader && childIndex == section.childStart) {
                return _AlbumDateDivider(
                  key: ValueKey('album-day:${section.itemStart}'),
                  day: section.day!,
                );
              }
              final index = layout.itemIndexForChild(childIndex);
              final item = widget.snapshot.items[index];
              return _AlbumCell(
                key: ValueKey(item.id),
                item: item,
                register: (node) => _nodes[index] = node,
                unregister: (node) {
                  if (identical(_nodes[index], node)) _nodes.remove(index);
                },
                onFocus: () {
                  if (_focusedId != item.id) _navigationColumn = null;
                  _focused = index;
                  _focusedId = item.id;
                },
                onOpen: () => widget.onOpen(item),
                onMenu: widget.onMenu == null
                    ? null
                    : () => widget.onMenu!(item),
                child: widget.thumbnail(context, item, pixels),
              );
            },
          ),
        ),
      );
    },
  );
}

class _AlbumDateDivider extends StatelessWidget {
  final DateTime day;
  const _AlbumDateDivider({super.key, required this.day});

  @override
  Widget build(BuildContext context) {
    final label = day.year == DateTime.now().year
        ? '${day.month}月${day.day}日'
        : '${day.year}年${day.month}月${day.day}日';
    return Row(
      children: [
        const SizedBox(width: 8, child: Divider(height: 1, thickness: .5)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ),
        const Expanded(child: Divider(height: 1, thickness: .5)),
      ],
    );
  }
}

class _AlbumGridDelegate extends SliverGridDelegate {
  final _AlbumGridLayout layout;
  final int restoreRevision;
  const _AlbumGridDelegate(this.layout, this.restoreRevision);
  @override
  SliverGridLayout getLayout(SliverConstraints constraints) => layout;
  @override
  bool shouldRelayout(_AlbumGridDelegate oldDelegate) =>
      oldDelegate.restoreRevision != restoreRevision ||
      oldDelegate.layout.sections != layout.sections ||
      oldDelegate.layout.columns != layout.columns ||
      oldDelegate.layout.cell != layout.cell;
}

/// Full-width date dividers share the same lazy sliver as photo cells. Section
/// offsets come from the worker, so scrolling never walks or groups the library.
class _AlbumGridLayout extends SliverGridLayout {
  static const headerHeight = 22.0;
  final AlbumWallSections sections;
  final int columns;
  final double cell, gap;
  const _AlbumGridLayout(this.sections, this.columns, this.cell, this.gap);
  double get rowExtent => cell + gap;
  double startOf(AlbumWallSection section) =>
      section.rowsBefore[columns - 1] * rowExtent +
      section.headersBefore * headerHeight;

  int _sectionIndexForChild(int index) {
    var low = 0, high = sections.sections.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (sections.sections[middle].childStart <= index) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  AlbumWallSection sectionForChild(int index) =>
      sections.sections[_sectionIndexForChild(index)];

  int columnForItem(int index) {
    final section = sectionForChild(sections.childByItem[index]);
    return (index - section.itemStart) % columns;
  }

  int verticalNeighbor(int index, int direction, {required int column}) {
    final position = _sectionIndexForChild(sections.childByItem[index]);
    var section = sections.sections[position];
    var row = (index - section.itemStart) ~/ columns + direction;
    final rows = (section.itemEnd - section.itemStart + columns - 1) ~/ columns;
    if (row < 0 || row >= rows) {
      final nextPosition = position + direction;
      if (nextPosition < 0) return -1;
      if (nextPosition >= sections.sections.length) {
        return sections.childByItem.length;
      }
      section = sections.sections[nextPosition];
      row = direction > 0
          ? 0
          : (section.itemEnd - section.itemStart - 1) ~/ columns;
    }
    return math.min(
      section.itemStart + row * columns + column,
      section.itemEnd - 1,
    );
  }

  AlbumWallSection sectionForOffset(double offset) {
    var low = 0, high = sections.sections.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (startOf(sections.sections[middle]) <= offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return sections.sections[low];
  }

  int itemIndexForChild(int child) {
    if (sections.sections.isEmpty) return 0;
    final section = sectionForChild(child);
    return (section.itemStart +
            child -
            section.childStart -
            (section.hasHeader ? 1 : 0))
        .clamp(section.itemStart, section.itemEnd - 1);
  }

  int? childIndexForId(AlbumSnapshot snapshot, String id) {
    final itemIndex = snapshot.indexById[id];
    if (itemIndex != null) return sections.childByItem[itemIndex];
    if (!id.startsWith('album-day:')) return null;
    final start = int.tryParse(id.substring('album-day:'.length));
    if (start == null || start >= sections.childByItem.length) return null;
    final child = sections.childByItem[start] - 1;
    final section = sectionForChild(child);
    return section.hasHeader && section.itemStart == start ? child : null;
  }

  double offsetForItem(int index) =>
      getGeometryForChildIndex(sections.childByItem[index]).scrollOffset;

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    if (sections.sections.isEmpty) {
      return SliverGridGeometry(
        scrollOffset: 0,
        crossAxisOffset: 0,
        mainAxisExtent: cell,
        crossAxisExtent: cell,
      );
    }
    final section = sectionForChild(index);
    final start = startOf(section);
    final relative = index - section.childStart - (section.hasHeader ? 1 : 0);
    if (relative < 0) {
      return SliverGridGeometry(
        scrollOffset: start,
        crossAxisOffset: 0,
        mainAxisExtent: headerHeight,
        crossAxisExtent: columns * rowExtent - gap,
      );
    }
    return SliverGridGeometry(
      scrollOffset:
          start +
          (section.hasHeader ? headerHeight : 0) +
          (relative ~/ columns) * rowExtent,
      crossAxisOffset: (relative % columns) * rowExtent,
      mainAxisExtent: cell,
      crossAxisExtent: cell,
    );
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (sections.sections.isEmpty) return 0;
    final section = sectionForOffset(scrollOffset);
    final offset = scrollOffset - startOf(section);
    if (section.hasHeader && offset < headerHeight) return section.childStart;
    final row = math.max(
      0,
      ((offset - (section.hasHeader ? headerHeight : 0)) / rowExtent).floor(),
    );
    return math.min(
      section.childStart + section.childCount - 1,
      section.childStart + (section.hasHeader ? 1 : 0) + row * columns,
    );
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (sections.sections.isEmpty) return 0;
    final section = sectionForOffset(scrollOffset);
    final offset = scrollOffset - startOf(section);
    if (section.hasHeader && offset < headerHeight) return section.childStart;
    final row = math.max(
      0,
      ((offset - (section.hasHeader ? headerHeight : 0)) / rowExtent).floor(),
    );
    return math.min(
      section.childStart + section.childCount - 1,
      section.childStart +
          (section.hasHeader ? 1 : 0) +
          (row + 1) * columns -
          1,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) => childCount == 0
      ? 0
      : sections.totalRows[columns - 1] * rowExtent -
            gap +
            sections.headerCount * headerHeight;
}

class _AlbumCell extends StatefulWidget {
  final AlbumItem item;
  final Widget child;
  final ValueChanged<FocusNode> register, unregister;
  final VoidCallback onFocus, onOpen;
  final VoidCallback? onMenu;

  const _AlbumCell({
    super.key,
    required this.item,
    required this.child,
    required this.register,
    required this.unregister,
    required this.onFocus,
    required this.onOpen,
    this.onMenu,
  });

  @override
  State<_AlbumCell> createState() => _AlbumCellState();
}

class _AlbumCellState extends State<_AlbumCell> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.register(_focus);
  }

  @override
  void didUpdateWidget(_AlbumCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    oldWidget.unregister(_focus);
    widget.register(_focus);
  }

  @override
  void dispose() {
    widget.unregister(_focus);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Semantics(
      label: item.name,
      button: true,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
              ActivateIntent(),
        },
        child: Material(
          color: Colors.white,
          child: InkWell(
            focusNode: _focus,
            focusColor: TelevisionMode.of(context) ? null : Colors.transparent,
            onTap: widget.onOpen,
            onLongPress: widget.onMenu,
            onSecondaryTap: widget.onMenu,
            onFocusChange: (value) {
              if (value) widget.onFocus();
              if (_focused != value) setState(() => _focused = value);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                widget.child,
                if (item.isDirectory)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                if (item.isVideo || item.isAudio || item.members.length > 1)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(color: Colors.black54),
                      child: SizedBox.square(
                        dimension: 18,
                        child: Center(
                          child: item.members.length > 1
                              ? Text(
                                  '${item.members.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    height: 1,
                                  ),
                                )
                              : Icon(
                                  item.isAudio
                                      ? Icons.music_note
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 14,
                                ),
                        ),
                      ),
                    ),
                  ),
                if (_focused && TelevisionMode.of(context))
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                          width: 4,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
