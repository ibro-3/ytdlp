import 'package:flutter/cupertino.dart'
    show
        BottomNavigationBarItem,
        CupertinoTabBar,
        CupertinoTabController,
        CupertinoTabScaffold;
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform_style.dart';
import '../../core/theme/app_theme.dart';

/// The four top-level destinations, in the order the tabs appear.
const _dests = [
  (label: 'Download', icon: Icons.download_outlined, selected: Icons.download),
  (
    label: 'Queue',
    icon: Icons.queue_music_outlined,
    selected: Icons.queue_music,
  ),
  (
    label: 'Library',
    icon: Icons.video_library_outlined,
    selected: Icons.video_library,
  ),
  (label: 'Settings', icon: Icons.settings_outlined, selected: Icons.settings),
];

/// The app's navigation frame: tabs on a narrow screen, a rail on a wide one.
///
/// Each family has its own answer for both. Android gets Material's
/// `NavigationBar`/`NavigationRail`; macOS gets a `CupertinoTabScaffold`, whose
/// bottom bar is the one a Mac user already knows from Mail and Music; Windows
/// gets a Fluent `NavigationView`, the pane the OS itself uses everywhere — down
/// the left when the window is wide, across the top when it is not; and Linux
/// gets GTK4's answer, which is a view switcher inside the header bar.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  void _go(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = navigationShell.currentIndex;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 760;
        switch (context.style) {
          case PlatformStyle.material:
            if (isWide) {
              return Scaffold(
                body: Row(
                  children: [
                    NavigationRail(
                      selectedIndex: index,
                      onDestinationSelected: _go,
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final d in _dests)
                          NavigationRailDestination(
                            icon: Icon(d.icon),
                            selectedIcon: Icon(d.selected),
                            label: Text(d.label),
                          ),
                      ],
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: navigationShell),
                  ],
                ),
              );
            }
            return Scaffold(
              body: navigationShell,
              bottomNavigationBar: NavigationBar(
                selectedIndex: index,
                onDestinationSelected: _go,
                destinations: [
                  for (final d in _dests)
                    NavigationDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selected),
                      label: d.label,
                    ),
                ],
              ),
            );
          case PlatformStyle.cupertino:
            return _CupertinoShell(
              index: index,
              onGo: _go,
              child: navigationShell,
            );
          case PlatformStyle.gtk:
            // GTK4's `AdwViewSwitcher` lives *in* the header bar: the four
            // destinations are a row of tabs beside the window's title, not a
            // bottom bar and not a rail. The wide/narrow rule still applies,
            // because a 600px window cannot fit four labels next to a title.
            return _GtkShell(
              index: index,
              onGo: _go,
              isWide: isWide,
              child: navigationShell,
            );
          case PlatformStyle.fluent:
            return fui.NavigationView(
              pane: fui.NavigationPane(
                selected: index,
                onChanged: _go,
                displayMode: isWide
                    ? fui.PaneDisplayMode.auto
                    : fui.PaneDisplayMode.top,
                items: [
                  for (final d in _dests)
                    fui.PaneItem(icon: Icon(d.icon), title: Text(d.label)),
                ],
              ),
              // The pane's body comes from the router, not from the pane item:
              // a deep link or a `context.go` changes the route without the
              // pane item ever being tapped, and the pane item's `body` would
              // then disagree with what is on screen.
              paneBodyBuilder: (_, _) => navigationShell,
            );
        }
      },
    );
  }
}

/// The macOS shell.
///
/// `CupertinoTabScaffold` keeps its own tab controller, and the router keeps
/// the route — so the two are wired both ways here. Without this, a deep link
/// or a `context.go('/library')` would show the Library behind a Download tab
/// highlight.
class _CupertinoShell extends StatefulWidget {
  const _CupertinoShell({
    required this.index,
    required this.onGo,
    required this.child,
  });

  /// The branch the router is currently on.
  final int index;

  /// Switches the router to [index].
  final ValueChanged<int> onGo;

  final Widget child;

  @override
  State<_CupertinoShell> createState() => _CupertinoShellState();
}

class _CupertinoShellState extends State<_CupertinoShell> {
  late final CupertinoTabController _controller = CupertinoTabController(
    initialIndex: widget.index,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.index != widget.index) {
      // After the frame, not during it: writing to the controller inside build
      // would mark it dirty mid-build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.index = widget.index;
      });
    }
    return CupertinoTabScaffold(
      controller: _controller,
      tabBar: CupertinoTabBar(
        currentIndex: _controller.index,
        onTap: (i) {
          if (_controller.index != i) _controller.index = i;
          widget.onGo(i);
        },
        items: [
          for (final d in _dests)
            BottomNavigationBarItem(
              icon: Icon(d.icon),
              activeIcon: Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
      // The route, not the tab: the tab bar only picks which branch is up.
      tabBuilder: (_, _) => widget.child,
    );
  }
}

/// The Linux shell: GTK4's view switcher inside a header bar.
///
/// The header bar the [AppScaffold] draws is per screen, so this one is the
/// shell's own: the app's name in place of a screen title, and the four
/// destinations beside it as a view switcher. On a narrow window the switcher
/// moves to its own row under the header, the way GTK collapses it.
class _GtkShell extends StatelessWidget {
  const _GtkShell({
    required this.index,
    required this.onGo,
    required this.isWide,
    required this.child,
  });

  final int index;
  final ValueChanged<int> onGo;

  /// Whether the window is wide enough for labels beside the title.
  final bool isWide;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final greys = AppTheme.gtkGreys(Theme.of(context).brightness);
    final text = Theme.of(context).textTheme;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: AppTheme.gtkHeaderHeight,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: greys.header,
              border: Border(bottom: BorderSide(color: greys.border)),
            ),
            child: Row(
              children: [
                // The runner's client-side window controls sit here, outside
                // the Flutter view.
                const SizedBox(width: 60),
                Text(
                  'YTDL',
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                _GtkViewSwitcher(index: index, onGo: onGo, showLabels: isWide),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The GTK view switcher: a row of tabs with an underline under the current
/// one, the way `AdwViewSwitcher`'s bar reads. Without room for labels it
/// becomes icons only, still underlined.
class _GtkViewSwitcher extends StatelessWidget {
  const _GtkViewSwitcher({
    required this.index,
    required this.onGo,
    required this.showLabels,
  });

  final int index;
  final ValueChanged<int> onGo;
  final bool showLabels;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _dests.length; i++)
          _GtkViewSwitchTab(
            label: _dests[i].label,
            icon: _dests[i].icon,
            selected: i == index,
            showLabel: showLabels,
            foreground: i == index ? colors.primary : colors.onSurfaceVariant,
            labelStyle: text.labelLarge,
            onTap: () => onGo(i),
          ),
      ],
    );
  }
}

class _GtkViewSwitchTab extends StatelessWidget {
  const _GtkViewSwitchTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.showLabel,
    required this.foreground,
    required this.labelStyle,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool showLabel;
  final Color foreground;
  final TextStyle? labelStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // The underline is the only thing that says "current", which is what GTK's
    // view switcher does: no pill, no fill, no ripple.
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: foreground),
              if (showLabel) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: (labelStyle ?? const TextStyle()).copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
