import 'package:flutter/material.dart';
import 'glass.dart';
import 'theme/settings_styles.dart';

/// The same compact search interaction for the library, settings and logs.
class SearchHeader extends StatefulWidget {
  final String title, hint;
  final String? subtitle;
  final Widget? trailing;
  final double titleSize;
  final ValueChanged<String> onChanged;
  const SearchHeader({
    super.key,
    required this.title,
    required this.hint,
    required this.onChanged,
    this.subtitle,
    this.trailing,
    this.titleSize = SettingsStyles.searchTitleSize,
  });

  @override
  State<SearchHeader> createState() => _SearchHeaderState();
}

class _SearchHeaderState extends State<SearchHeader> {
  final controller = TextEditingController();
  final focus = FocusNode();
  bool expanded = false;
  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  void toggle() {
    setState(() => expanded = !expanded);
    if (expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && expanded) focus.requestFocus();
      });
    } else {
      focus.unfocus();
      controller.clear();
      widget.onChanged('');
    }
  }

  @override
  Widget build(BuildContext context) {
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
                      focusNode: focus,
                      onChanged: widget.onChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        isDense: true,
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
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
