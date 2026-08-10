import 'package:flutter/material.dart';

/// Wraps an `ElevatedButton` or `OutlinedButton` with an in-flight loading
/// state. Tapping the button invokes [onPressed] (a `Future<void>`-returning
/// callback); the button stays disabled and shows a spinner-prefixed
/// "loading" form of its label until the future settles, success or
/// failure.
///
/// The widget itself doesn't surface errors — it only manages the
/// disabled/spinner UI. Callers are expected to handle success/failure
/// inside `onPressed` (snackbar, navigation, etc.).
///
/// Use for destructive or network-bound actions where the underlying call
/// has a perceptible delay (Disconnect bank, Remove cards, Reconnect
/// flow's submit, etc.). Replaces the prior pattern of "pop the sheet
/// immediately, do the work invisibly, surface a snackbar later" — which
/// hid the latency from the user and made failures feel unattributed.
class AsyncActionButton extends StatefulWidget {
  const AsyncActionButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.outlined = false,
    this.style,
    this.loadingChild,
  });

  /// The async action. When `null`, the button is disabled (mirrors
  /// stock button semantics). When non-null, pressing it invokes
  /// `onPressed()` and the widget renders the loading state until the
  /// returned future completes.
  final Future<void> Function()? onPressed;

  /// Normal (non-loading) content. Usually a `Text(...)`.
  final Widget child;

  /// `OutlinedButton` (true) vs `ElevatedButton` (false, default).
  final bool outlined;

  /// Optional explicit `ButtonStyle`. Pass-through to the wrapped button.
  final ButtonStyle? style;

  /// Override for the loading content. Defaults to a 16×16
  /// `CircularProgressIndicator` followed by the original [child] —
  /// preserves the button's layout dimensions so neighboring widgets
  /// don't shift when the spinner appears.
  final Widget? loadingChild;

  @override
  State<AsyncActionButton> createState() => _AsyncActionButtonState();
}

class _AsyncActionButtonState extends State<AsyncActionButton> {
  bool _loading = false;

  Future<void> _handlePress() async {
    final fn = widget.onPressed;
    if (fn == null || _loading) return;
    setState(() => _loading = true);
    try {
      await fn();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildContent() {
    if (!_loading) return widget.child;
    if (widget.loadingChild != null) return widget.loadingChild!;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        widget.child,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Loading + disabled callers both produce `onPressed: null` on the
    // underlying button. That's what gives us the standard disabled
    // visual treatment for free.
    final effectiveOnPressed = (_loading || widget.onPressed == null)
        ? null
        : _handlePress;
    final content = _buildContent();
    if (widget.outlined) {
      return OutlinedButton(
        onPressed: effectiveOnPressed,
        style: widget.style,
        child: content,
      );
    }
    return ElevatedButton(
      onPressed: effectiveOnPressed,
      style: widget.style,
      child: content,
    );
  }
}
