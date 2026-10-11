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
/// Each family has its own answer for both. Android and Linux get Material's
/// `NavigationBar`/`NavigationRail`; macOS gets a `CupertinoTabScaffold`, whose
/// bottom bar is the one a Mac user already knows from Mail and Music; Windows
/// gets a Fluent `NavigationView`, which is the pane the OS itself uses
/// everywhere — down the left when the window is wide, across the top when it
/// is not.
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
