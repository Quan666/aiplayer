import 'package:flutter/material.dart';

/// Keeps credentials marked as private even while their value is visible.
class SecretTextField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final bool enabled;
  final TextStyle? style;

  const SecretTextField({
    super.key,
    required this.controller,
    required this.decoration,
    this.enabled = true,
    this.style,
  });

  @override
  State<SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<SecretTextField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    enabled: widget.enabled,
    style: widget.style,
    obscureText: !_visible,
    keyboardType: TextInputType.visiblePassword,
    autocorrect: false,
    enableSuggestions: false,
    decoration: widget.decoration.copyWith(
      suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      suffixIcon: IconButton(
        tooltip: _visible ? '隐藏' : '显示',
        onPressed: widget.enabled
            ? () => setState(() => _visible = !_visible)
            : null,
        iconSize: 20,
        icon: Icon(
          _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    ),
  );
}
