import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_theme_context.dart';

/// A short message over the app, in the family the OS asked for.
///
/// Material has `SnackBar`, and this uses it there. Neither Cupertino nor
/// Fluent has one: iOS uses a small translucent dark pill that fades out,
/// Windows a light `InfoBar`-style card at the top. Rather than shrink a
/// Material snackbar into either, this draws the right shape per family from a
/// single [OverlayEntry].
///
/// An overlay entry rather than a `ScaffoldMessenger` call, because the
/// start-up banner is built in the root's `builder` — above the `Navigator`,
/// where no `ScaffoldMessenger` exists — and its dismiss button is exactly what
/// needs to say something. An overlay entry lives above anything.
/// The toast currently on screen.
///
/// One at a time, the way Material's `SnackBar` queue is one at a time: the
/// app says something per action (a cookie site switched off, a download
/// queued), and without this three taps would leave three half-covered banners
/// rather than three readable ones — and a `hideCurrentSnackBar()` on every
/// call site that this replaced.
OverlayEntry? _current;

void showAppToast(
  BuildContext context,
  String message, {
  VoidCallback? action,
  String actionLabel = '',
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  // The next toast replaces the one still on screen. Its timer is still
  // pending, and cancels itself when the entry is disposed — so an abandoned
  // toast cannot reappear after the replacement is gone.
  final previous = _current;
  if (previous != null && previous.mounted) previous.remove();
  // Declared late so the entry's own dismiss can reach it.
  late final OverlayEntry manager;
  manager = OverlayEntry(
    builder: (context) => _Toast(
      message: message,
      action: action,
      actionLabel: actionLabel,
      onDismiss: () {
        if (_current == manager) _current = null;
        if (manager.mounted) manager.remove();
      },
    ),
  );
  _current = manager;
  overlay.insert(manager);
}

class _Toast extends StatefulWidget {
  const _Toast({
    required this.message,
    required this.action,
    required this.actionLabel,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback? action;
  final String actionLabel;
  final VoidCallback onDismiss;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// The dismissal timer. It belongs to the widget rather than to
  /// [showAppToast] so that disposing the toast cancels it: a `SnackBar`
  /// behaves the same way, and an uncancelled one would survive the overlay
  /// entry and fail every test that pumps and settles.
  Timer? _lifetime;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _lifetime = Timer(const Duration(seconds: 4), widget.onDismiss);
  }

  @override
  void dispose() {
    _lifetime?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final atBottom = context.style != PlatformStyle.fluent;
    return Positioned(
      left: 0,
      right: 0,
      bottom: atBottom ? 0 : null,
      top: atBottom ? null : MediaQuery.paddingOf(context).top,
      child: SafeArea(
        child: Align(
          alignment: atBottom ? Alignment.bottomCenter : Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FadeTransition(
              opacity: _controller,
              child: _StyledToast(
                message: widget.message,
                action: widget.action,
                actionLabel: widget.actionLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The frame the family asks for, around the same words.
class _StyledToast extends StatelessWidget {
  const _StyledToast({
    required this.message,
    required this.action,
    required this.actionLabel,
  });

  final String message;
  final VoidCallback? action;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles.bodyMedium;
    final Style style = switch (context.style) {
      // GTK has no snackbar. What it has is an in-window banner, which is a
      // card on the view background rather than an inverted one — a light card
      // pinned to the bottom, dismissible, sitting *inside* the app.
      PlatformStyle.gtk => (
        background: colors.surfaceContainerLowest,
        foreground: colors.onSurface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(AppTheme.gtkSurfaceRadius),
          ),
        ),
      ),
      PlatformStyle.material => (
        background: colors.inverseSurface,
        foreground: colors.onInverseSurface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      PlatformStyle.cupertino => (
        // iOS' toast is a translucent dark pill.
        background: Colors.black.withValues(alpha: 0.85),
        foreground: Colors.white,
        shape: const StadiumBorder(),
      ),
      PlatformStyle.fluent => (
        // Windows' is a light card pinned to the top, an `InfoBar` without the
        // severity icon.
        background: colors.surfaceContainerHigh,
        foreground: colors.onSurface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
    };
    return Material(
      color: style.background,
      shape: style.shape,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      // GTK's banner is bordered rather than floating over a scrim, and the
      // shadow a Material snackbar has is the wrong depth for it.
      shadowColor: Colors.transparent,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, action == null ? 16 : 8, 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                message,
                style: text?.copyWith(color: style.foreground),
              ),
            ),
            if (action != null)
              TextButton(
                onPressed: action,
                style: TextButton.styleFrom(foregroundColor: style.foreground),
                child: Text(actionLabel),
              ),
          ],
        ),
      ),
    );
  }
}

/// One toast's appearance, per family.
typedef Style = ({Color background, Color foreground, ShapeBorder shape});

/// Says something to the user, in the family the OS asked for.
///
/// Replaces `ScaffoldMessenger.of(context).showSnackBar(...)` at every call
/// site: Material gets a snackbar and the other two get their own shape, and no
/// call site has to know which.
extension AppToastContext on BuildContext {
  void showToast(
    String message, {
    String actionLabel = '',
    VoidCallback? onAction,
  }) => showAppToast(this, message, action: onAction, actionLabel: actionLabel);
}
