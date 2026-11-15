import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoNavigationBar, CupertinoPageScaffold;
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:material_ui/material_ui.dart';

import '../../core/platform_style.dart';
import '../gtk_header.dart';
import 'platform_controls.dart';
import 'platform_gtk.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_theme_context.dart';

/// The screen frame: a header bar, a body, and optional trailing actions.
///
/// One wrapper because the OS decides which frame a screen gets — a Material
/// `Scaffold`/`AppBar`, a `CupertinoPageScaffold`/`CupertinoNavigationBar`, a
/// Fluent `ScaffoldPage`/`PageHeader`, or GTK4's header bar. Screens describe the
/// frame once; the family is chosen here and nowhere else.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.title,
    this.actions = const [],
    required this.body,
    this.floatingActionButton,
    this.bottomBar,
  });

  /// The screen's title. Null means no header bar at all.
  final String? title;

  /// Trailing header-bar widgets, laid out at their intrinsic width.
  final List<Widget> actions;

  final Widget body;

  /// Rendered floating over the body, bottom-right. Material has
  /// `Scaffold.floatingActionButton` for this; the other three families do not,
  /// so they get a positioned overlay instead.
  final Widget? floatingActionButton;

  /// A tab strip or similar that sits below the body.
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    // SafeArea used to be applied inside every screen. Moving it here keeps it
    // in one place and gives every family's full-bleed bars the same
    // notch-and-gesture handling Material had.
    Widget content = SafeArea(child: body);
    final fab = floatingActionButton;
    final style = context.style;
    if (fab != null && style != PlatformStyle.material) {
      // Not flush with the corner: the other families drew this as a positioned
      // overlay with no inset at all.
      content = Stack(
        alignment: Alignment.bottomRight,
        children: [
          content,
          Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              0,
              16,
              16 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: fab,
          ),
        ],
      );
    }

    switch (style) {
      case PlatformStyle.material:
        return Scaffold(
          appBar: title == null
              ? null
              : AppBar(title: Text(title!), actions: actions),
          body: content,
          bottomNavigationBar: bottomBar,
          floatingActionButton: fab,
        );
      case PlatformStyle.cupertino:
        // CupertinoPageScaffold has no bottomBar of its own: the body sits
        // above it in a column so the selection bar (playlist, batch) shows on
        // iOS exactly as it does on Android.
        return CupertinoPageScaffold(
          navigationBar: title == null
              ? null
              : CupertinoNavigationBar(
                  middle: Text(title!),
                  trailing: actions.isEmpty
                      ? null
                      : Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
          child: bottomBar == null
              ? content
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: content),
                    ?bottomBar,
                  ],
                ),
        );
      case PlatformStyle.fluent:
        return fui.ScaffoldPage(
          header: title == null
              ? null
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: fui.PageHeader(title: Text(title!))),
                    if (actions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: actions,
                        ),
                      ),
                  ],
                ),
          content: content,
          // fluent_ui 4.17 renamed ScaffoldPage.bottomBar to footer.
          footer: bottomBar,
        );
      case PlatformStyle.gtk:
        // The window's header bar belongs to the shell (it carries the view
        // switcher and the screen's title); the screen contributes its own
        // action buttons, in a slim right-aligned row, and publishes its
        // title upward — one frame per window, not two.
        final publish = GtkHeaderScope.of(context);
        if (publish != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => publish.update(title),
          );
        }
        return SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (actions.isNotEmpty) _GtkActionRow(actions: actions),
              Expanded(child: content),
              ?bottomBar,
            ],
          ),
        );
    }
  }
}

/// The GTK screen's action row: the screen's own icon buttons (scan, sort,
/// pause…), right-aligned under the window's header bar. The title lives in
/// the shell's header, so this row carries none — one frame per window, not
/// two.
class _GtkActionRow extends StatelessWidget {
  const _GtkActionRow({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final greys = AppTheme.gtkGreys(Theme.of(context).brightness);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: greys.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.max,
        children: actions,
      ),
    );
  }
}

/// The Fluent FAB: a filled accent circle with the Windows 56dp metric,
/// wrapped in a tooltip so the icon-only button is labelled for screen readers
/// and hover.
Widget _fluentFab({
  required VoidCallback? onPressed,
  required IconData icon,
  String? tooltip,
}) {
  final button = fui.FilledButton(
    onPressed: onPressed,
    style: const fui.ButtonStyle(
      shape: fui.WidgetStatePropertyAll(CircleBorder()),
      padding: fui.WidgetStatePropertyAll(EdgeInsets.all(14)),
      iconSize: fui.WidgetStatePropertyAll(22),
    ),
    child: Icon(icon, size: 22),
  );
  if (tooltip == null) return button;
  return Tooltip(message: tooltip, child: button);
}

/// The bottom selection strip: a count and one primary action.
///
/// The playlist and batch screens both ended in a raw Material bar before
/// this existed, which is why it takes no family-specific chrome of its own —
/// each family draws its standard bottom-edge strip and the row inside it is
/// the same everywhere.
class AppSelectionBar extends StatelessWidget {
  const AppSelectionBar({
    super.key,
    required this.label,
    required this.actionLabel,
    required this.onAction,
    this.icon = Icons.download,
  });

  /// The leading text — the running count of what is selected.
  final String label;

  final String actionLabel;

  /// Null disables the action.
  final VoidCallback? onAction;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final child = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textStyles.bodyMedium,
              ),
            ),
            AppButton.icon(
              onPressed: onAction,
              icon: icon,
              label: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
    return switch (context.style) {
      PlatformStyle.material => Material(
        elevation: 3,
        color: colors.surfaceContainer,
        child: child,
      ),
      // A translucent top-edge band with a hairline, iOS' tab-bar idiom.
      PlatformStyle.cupertino => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainer.withValues(alpha: 0.92),
          border: Border(
            top: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: child,
      ),
      // Windows' command bar look: a high surface with a hard top border.
      PlatformStyle.fluent => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          border: Border(top: BorderSide(color: colors.outline)),
        ),
        child: child,
      ),
      // GTK: a low surface with one hairline, no elevation.
      PlatformStyle.gtk => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(top: BorderSide(color: colors.outline)),
        ),
        child: child,
      ),
    };
  }
}

/// The floating action button, in the family the OS asked for.
///
/// Material's is a filled circle; the Fluent equivalent is a circular
/// accent-filled button; Cupertino has none, so it is a circle tinted with the
/// theme's accent — the shape a Mac user expects from a floating control.
/// GTK has no FAB at all: what it has is a button in the header bar, so this
/// is a flat round accent-tinted icon button with no shadow.
class AppFab extends StatelessWidget {
  const AppFab({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return switch (context.style) {
      PlatformStyle.material => FloatingActionButton(
        onPressed: onPressed,
        tooltip: tooltip,
        child: Icon(icon),
      ),
      PlatformStyle.cupertino => Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: colors.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: colors.onPrimary),
          ),
        ),
      ),
      PlatformStyle.fluent => _fluentFab(
        onPressed: onPressed,
        icon: icon,
        tooltip: tooltip,
      ),
      PlatformStyle.gtk => GtkFab(
        onPressed: onPressed,
        icon: icon,
        tooltip: tooltip,
      ),
    };
  }
}
