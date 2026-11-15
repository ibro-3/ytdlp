import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:ytdlp/core/theme/app_theme.dart';
import 'package:ytdlp/widgets/app_shell.dart';
import 'package:ytdlp/widgets/platform/platform.dart';

import 'support/pump.dart';

/// The Linux shell is the *only* frame on a GTK desktop: it carries the
/// window-controls spacer, the screen's own title and the view switcher —
/// screens contribute their actions in a slim row. This walks a real shell
/// route so the "one header, no duplicate frame" rule is tested end to end.
void main() {
  testWidgets(
    "the screen's title shows in the shell's single header, with its actions in a slim row",
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      const screenTitle = 'Queue links';
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (context, state, navigationShell) =>
                AppShell(navigationShell: navigationShell),
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/',
                    builder: (_, _) => AppScaffold(
                      title: screenTitle,
                      actions: [
                        AppIconButton(
                          icon: Icons.clear_all,
                          tooltip: 'Clear the list',
                          onPressed: () {},
                        ),
                      ],
                      body: const Center(child: Text('body')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: AppTheme.gtk(brightness: Brightness.light),
            routerConfig: router,
          ),
        ),
      );
      await settleIo(tester);

      // The screen's own title, published upward into the one bar — not a
      // per-screen frame of its own.
      expect(find.text(screenTitle), findsWidgets);

      // Exactly one 42px header, not the shell's plus a per-screen one.
      final bars = find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.constraints?.maxHeight == AppTheme.gtkHeaderHeight,
      );
      expect(bars, findsOneWidget);

      // The screen's action lives in a slim row, reachable and present.
      expect(find.byTooltip('Clear the list'), findsOneWidget);

      // The shell's view switcher is present with the four destinations.
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    },
  );
}
