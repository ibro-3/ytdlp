import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
import 'platform_gtk.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_theme_context.dart';

/// How hard a button says "do this", in order of prominence.
enum AppButtonVariant {
  /// The primary action. Material's filled, Fluent's filled, Cupertino's
  /// accent-filled.
  filled,

  /// A supporting action next to a filled one. Material's tonal, Fluent's
  /// accent-tinted button, Cupertino's tinted.
  tonal,

  /// No fill at all — for rows that are already busy. Material's text button,
  /// Cupertino's plain, Fluent's hyperlink.
  plain,

  /// A border instead of a fill, for an action that is not *the* action but is
  /// still worth finding (the playlist page's "load more", say).
  outlined,
}

/// One button in the OS's own family.
///
/// The app previously used `FilledButton`, `FilledButton.tonalIcon` and
/// `TextButton` directly, each of which renders Material's shading and corner
/// radius on macOS and Windows — which is exactly what "follows the OS" is meant
/// to stop. The named constructors mirror the three shapes the app uses, so a
/// call site reads the same whichever family is underneath.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.variant = AppButtonVariant.filled,
  });

  /// A button carrying a leading icon — the app's most common button by far.
  ///
  /// [AppButton.icon] keeps [AppButton.child] as the label: a bar of text
  /// beside an icon is the shape nearly every button in the app has.
  const AppButton.icon({
    super.key,
    required this.onPressed,
    required this.icon,
    required Widget label,
    this.variant = AppButtonVariant.filled,
  }) : child = label;

  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final AppButtonVariant variant;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    switch (context.style) {
      case PlatformStyle.material:
        return switch ((icon, variant)) {
          (null, _) => FilledButton(
            onPressed: onPressed,
            style: _materialStyle(context),
            child: child,
          ),
          (_, AppButtonVariant.tonal) => FilledButton.tonalIcon(
            onPressed: onPressed,
            style: _materialStyle(context),
            icon: Icon(icon),
            label: child,
          ),
          (_, AppButtonVariant.plain) => TextButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: child,
          ),
          (_, AppButtonVariant.outlined) => OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: child,
          ),
          _ => FilledButton.icon(
            onPressed: onPressed,
            style: _materialStyle(context),
            icon: Icon(icon),
            label: child,
          ),
        };

      case PlatformStyle.cupertino:
        return CupertinoButton(
          onPressed: onPressed,
          borderRadius: BorderRadius.circular(10),
          // Cupertino sizes its buttons from their padding alone; this is the
          // app's 48dp target rather than iOS' 44.
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: switch (variant) {
            AppButtonVariant.filled => colors.primary,
            AppButtonVariant.tonal => colors.secondaryContainer,
            AppButtonVariant.plain => Colors.transparent,
            AppButtonVariant.outlined => Colors.transparent,
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18),
                const SizedBox(width: 8),
              ],
              DefaultTextStyle.merge(
                style: (context.textStyles.labelLarge ?? const TextStyle())
                    .copyWith(
                      fontWeight: FontWeight.w600,
                      color: _onAccent(colors, variant),
                    ),
                child: child,
              ),
            ],
          ),
        );

      case PlatformStyle.fluent:
        final content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18),
              const SizedBox(width: 8),
            ],
            child,
          ],
        );
        return Padding(
          // Fluent buttons are 32dp tall by default; the app's controls are
          // sized for touch, so they get the room.
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: switch (variant) {
            AppButtonVariant.filled => fui.FilledButton(
              onPressed: onPressed,
              child: content,
            ),
            AppButtonVariant.tonal => fui.Button(
              onPressed: onPressed,
              style: fui.ButtonStyle(
                backgroundColor: fui.WidgetStatePropertyAll(
                  colors.secondaryContainer,
                ),
                foregroundColor: fui.WidgetStatePropertyAll(
                  colors.onSecondaryContainer,
                ),
              ),
              child: content,
            ),
            AppButtonVariant.plain => fui.HyperlinkButton(
              onPressed: onPressed,
              child: child,
            ),
            AppButtonVariant.outlined => fui.OutlinedButton(
              onPressed: onPressed,
              child: content,
            ),
          },
        );

      case PlatformStyle.gtk:
        final content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16),
              const SizedBox(width: 8),
            ],
            child,
          ],
        );
        // Adwaita has three kinds of button, and none of them lifts: the
        // accent-filled `suggested-action`, the bordered `flat` button, and the
        // text-only one. So a filled action is a 6dp flat accent, a tonal one
        // is the same on a neutral fill, and plain and outlined are both
        // bordered — GTK has no "outlined with a coloured label".
        return ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AppTheme.gtkControlHeight,
          ),
          child: switch (variant) {
            AppButtonVariant.filled => FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, AppTheme.gtkControlHeight),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
                ),
              ),
              child: content,
            ),
            AppButtonVariant.tonal => FilledButton.tonal(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, AppTheme.gtkControlHeight),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
                ),
              ),
              child: content,
            ),
            AppButtonVariant.plain ||
            AppButtonVariant.outlined => OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppTheme.gtkControlHeight),
                side: BorderSide(color: context.colors.outline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
                ),
              ),
              child: content,
            ),
          },
        );
    }
  }

  /// The Material theme already shapes filled buttons; only the plain variant
  /// needs a one-off, because the app's theme never styled `TextButton`.
  ButtonStyle? _materialStyle(BuildContext context) =>
      variant == AppButtonVariant.plain
      ? TextButton.styleFrom(minimumSize: const Size(64, 48))
      : null;

  /// The colour of the label for [variant]'s fill, or the accent when there is
  /// no fill.
  static Color _onAccent(ColorScheme colors, AppButtonVariant variant) =>
      switch (variant) {
        AppButtonVariant.filled => colors.onPrimary,
        AppButtonVariant.tonal => colors.onSecondaryContainer,
        AppButtonVariant.plain || AppButtonVariant.outlined => colors.primary,
      };
}

/// Icon-only actions, in the family the OS asked for.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final button = switch (context.style) {
      PlatformStyle.material => IconButton(
        icon: Icon(icon),
        onPressed: onPressed,
        tooltip: tooltip,
      ),
      // Cupertino has no icon button: what iOS ships is a 44pt tap target
      // around an icon, which is what this is.
      PlatformStyle.cupertino => CupertinoButton(
        onPressed: onPressed,
        padding: const EdgeInsets.all(12),
        minimumSize: const Size(44, 44),
        child: Icon(icon, size: 22, color: colors.primary),
      ),
      PlatformStyle.fluent => fui.IconButton(
        icon: Icon(icon),
        onPressed: onPressed,
      ),
      // GTK's header-bar button is a flat, square, 32dp icon target with a
      // hover fill — never a filled circle, and never a ripple.
      PlatformStyle.gtk => GtkIconButton(
        icon: icon,
        onPressed: onPressed,
        tooltip: tooltip,
      ),
    };
    // Material's own IconButton shows a tooltip, and nesting a second one would
    // show both; the other two families show none, so they take one from here.
    if (tooltip == null || context.style == PlatformStyle.material) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}
