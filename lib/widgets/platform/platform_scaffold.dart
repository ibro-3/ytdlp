import 'package:flutter/cupertino.dart'
    show CupertinoNavigationBar, CupertinoPageScaffold;
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
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
      content = Stack(
        alignment: Alignment.bottomRight,
        children: [content, fab],
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
        return CupertinoPageScaffold(
          navigationBar: title == null
              ? null
              : CupertinoNavigationBar(
                  middle: Text(title!),
                  trailing: actions.isEmpty
                      ? null
                      : Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
          child: content,
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
          bottomBar: bottomBar,
        );
      case PlatformStyle.gtk:
        return _GtkFrame(
          title: title,
          actions: actions,
          bottomBar: bottomBar,
          child: content,
        );
    }
  }
}

/// The GTK4 frame: a 42px header bar, the window's title in it, and the body
/// below.
///
/// GTK4 apps put their chrome in a header bar and give the window the
/// decorations — the native runner already draws the client-side window
/// controls for us, so this bar carries no close button and stops short of the
/// left edge by the width of those controls. It is the one frame here built
/// out of Material widgets, because that is what the app has: a `Container`
/// at the header height over the body, with a bottom hairline rather than an
/// elevation.
class _GtkFrame extends StatelessWidget {
  const _GtkFrame({
    required this.title,
    required this.actions,
    required this.bottomBar,
    required this.child,
  });

  final String? title;
  final List<Widget> actions;
  final Widget? bottomBar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final greys = AppTheme.gtkGreys(Theme.of(context).brightness);
    final text = Theme.of(context).textTheme;
    final bar = Container(
      height: AppTheme.gtkHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: greys.header,
        border: Border(bottom: BorderSide(color: greys.border)),
      ),
      child: Row(
        children: [
          // Room for the runner's client-side window controls, which sit
          // outside the Flutter view.
          const SizedBox(width: 60),
          if (title case final titleText?)
            Text(
              titleText,
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          const Spacer(),
          for (final action in actions) action,
        ],
      ),
    );
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) bar,
          Expanded(child: child),
          ?bottomBar,
        ],
      ),
    );
  }
}

/// The floating action button, in the family the OS asked for.
///
/// Material's is a filled circle; the Fluent equivalent is a circular icon
/// button; Cupertino has none, so it is a circle tinted with the theme's accent
/// — the shape a Mac user expects from a floating control. GTK has no FAB at
/// all: what it has is a button in the header bar, so this is a flat round
/// accent-tinted icon button with no shadow.
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
      PlatformStyle.fluent => fui.IconButton(
        icon: Icon(icon),
        onPressed: onPressed,
      ),
      PlatformStyle.gtk => GtkFab(
        onPressed: onPressed,
        icon: icon,
        tooltip: tooltip,
      ),
    };
  }
}
