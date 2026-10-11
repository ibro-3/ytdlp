import 'package:flutter/cupertino.dart';
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
import '../../core/theme/app_theme_context.dart';

/// The screen frame: an app bar, a body, and optional trailing actions.
///
/// One wrapper because the OS decides which frame a screen gets — Material
/// `Scaffold`/`AppBar`, a `CupertinoPageScaffold`/`CupertinoNavigationBar`, or a
/// Fluent `ScaffoldPage`/`PageHeader`. Screens describe the frame once; the
/// family is chosen here and nowhere else.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.title,
    this.actions = const [],
    required this.body,
    this.floatingActionButton,
    this.bottomBar,
  });

  /// The screen's title. Null means no app bar at all.
  final String? title;

  /// Trailing app-bar widgets, laid out at their intrinsic width (which is
  /// what Material does, and what the queue page's counts-and-buttons row
  /// already assumes).
  final List<Widget> actions;

  final Widget body;

  /// Rendered floating over the body, bottom-right. Material has
  /// `Scaffold.floatingActionButton` for this; the two other families do not,
  /// so they get a positioned overlay instead.
  final Widget? floatingActionButton;

  /// A tab strip or similar that sits below the body.
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    // SafeArea used to be applied inside every screen. Moving it here keeps it
    // in one place and gives Cupertino's and Fluent's full-bleed bars the same
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
    }
  }
}

/// The floating action button, in the family the OS asked for.
///
/// Material's is a filled circle; the Fluent equivalent is a circular icon
/// button; Cupertino has none, so it is a circle tinted with the theme's accent
/// — the shape a Mac user expects from a floating control.
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
    };
  }
}
