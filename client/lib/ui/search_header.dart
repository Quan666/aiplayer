import 'package:flutter/material.dart';
import 'glass.dart';
import 'theme/settings_styles.dart';

/// Lets navigation dismiss this input and cancel focus queued for its entrance
/// animation without clearing the user's search text.
class SearchHeaderController {
  final _focus = FocusNode();
  int _focusRevision = 0;
  bool _disposed = false;

  void dismissFocus() {
    _focusRevision++;
    _focus.unfocus();
  }

  void dispose() {
    _disposed = true;
    _focusRevision++;
    _focus.dispose();
  }
}

/// The same compact search interaction for the library, settings and logs.
class SearchHeader extends StatefulWidget {
  final String title, hint;
  final String? subtitle;
  final Widget? trailing;
  final double titleSize;
  final ValueChanged<String> onChanged;
  final SearchHeaderController? controller;
  const SearchHeader({
    super.key,
    required this.title,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.subtitle,
    this.trailing,
    this.titleSize = SettingsStyles.searchTitleSize,
  });

  @override
  State<SearchHeader> createState() => _SearchHeaderState();
}

class _SearchHeaderState extends State<SearchHeader>
    with AutomaticKeepAliveClientMixin {
  final controller = TextEditingController();
  SearchHeaderController? _internalController;
  SearchHeaderController get _search =>
      widget.controller ?? (_internalController ??= SearchHeaderController());
  bool expanded = false;

  // A lazy sliver may evict an unfocused input after scrolling. Retain only the
  // expanded header so its text and open state survive; ordinary rows stay lazy.
  @override
  bool get wantKeepAlive => expanded;

  @override
  void didUpdateWidget(SearchHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      (oldWidget.controller ?? _internalController)?.dismissFocus();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    _internalController?.dispose();
    super.dispose();
  }

  void toggle() {
    setState(() => expanded = !expanded);
    updateKeepAlive();
    if (expanded) {
      final search = _search;
      final revision = search._focusRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !expanded ||
            search != _search ||
            search._disposed ||
            revision != search._focusRevision ||
            !(ModalRoute.of(context)?.isCurrent ?? true)) {
          return;
        }
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
        search._focus.requestFocus();
      });
    } else {
      _search.dismissFocus();
      controller.clear();
      widget.onChanged('');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: widget.subtitle == null ? 48 : 56),
      child: AnimatedSwitcher(
        duration: MotionScope.duration(context, 160),
        child: expanded
            ? Row(
                key: const ValueKey('expanded-search'),
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: _search._focus,
                      onChanged: widget.onChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        isDense: true,
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        contentPadding: SettingsStyles.searchFieldPadding,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭搜索',
                    onPressed: toggle,
                    icon: const Icon(Icons.close_rounded, size: 22),
                  ),
                ],
              )
            : Row(
                key: const ValueKey('compact-search'),
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SettingsStyles.of(
                            context,
                          ).searchTitle(widget.titleSize),
                        ),
                        if (widget.subtitle != null)
                          Text(
                            widget.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppStyles.of(context).micro,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: widget.hint,
                    onPressed: toggle,
                    icon: const Icon(Icons.search_rounded, size: 22),
                  ),
                  if (widget.trailing != null) widget.trailing!,
                ],
              ),
      ),
    );
    final duration = MotionScope.duration(context, 220);
    return duration == Duration.zero
        ? content
        : AnimatedSize(
            duration: duration,
            alignment: Alignment.centerLeft,
            curve: Curves.easeOutCubic,
            child: content,
          );
  }
}
