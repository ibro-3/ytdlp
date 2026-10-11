import 'package:flutter/cupertino.dart' show CupertinoPage;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/playlist_info.dart';
import '../../core/platform_style.dart';
import '../../core/theme/app_theme_context.dart';
import '../../features/home/home_page.dart';
import '../../features/library/library_page.dart';
import '../../features/playlist/playlist_page.dart';
import '../../features/queue/batch_queue_page.dart';
import '../../features/queue/queue_page.dart';
import '../../features/settings/cookie_domains_page.dart';
import '../../features/settings/settings_page.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/platform/platform.dart';

/// Pushes [child] with the page transition the OS uses.
///
/// Material's default is a fade-through, which is what `builder` produces. iOS
/// slides from the right instead, and that slide is what a pushed screen *is* on
/// a Mac — a Material page sliding onto a Cupertino screen reads as a foreign
/// overlay. Every pushed route goes through here so the choice is made once.
Page<void> _page(BuildContext context, GoRouterState state, Widget child) {
  return switch (context.style) {
    PlatformStyle.material => MaterialPage<void>(
      key: state.pageKey,
      child: child,
    ),
    PlatformStyle.cupertino => CupertinoPage<void>(
      key: state.pageKey,
      child: child,
    ),
    PlatformStyle.fluent => MaterialPage<void>(
      key: state.pageKey,
      child: child,
    ),
  };
}

final appRouter = GoRouter(
  initialLocation: '/download',
  // A route the app cannot show renders as go_router's own error page, in
  // whatever locale and theme it happens to pick. This is what an Android
  // share-intent deep link with a path the app does not have lands on.
  errorBuilder: (context, state) => const _RouteNotFound(),
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/download',
              pageBuilder: (context, state) =>
                  _page(context, state, const HomePage()),
              routes: [
                // A playlist the user picked from the Download tab. The
                // playlist rides in `extra` because it only exists as the
                // result of a fetch; there is no URL to deep-link to.
                GoRoute(
                  path: 'playlist',
                  pageBuilder: (context, state) {
                    final playlist = state.extra;
                    if (playlist is! PlaylistInfo) {
                      return _page(
                        context,
                        state,
                        const _PlaylistUnavailable(),
                      );
                    }
                    return _page(
                      context,
                      state,
                      PlaylistPage(playlist: playlist),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/queue',
              pageBuilder: (context, state) =>
                  _page(context, state, const QueuePage()),
              routes: [
                GoRoute(
                  path: 'batch',
                  pageBuilder: (context, state) =>
                      _page(context, state, const BatchQueuePage()),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              pageBuilder: (context, state) =>
                  _page(context, state, const LibraryPage()),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              pageBuilder: (context, state) =>
                  _page(context, state, const SettingsPage()),
              routes: [
                // A real route rather than a `Navigator.push` with a
                // `MaterialPageRoute`: every other navigation goes through the
                // router, and an imperative push sits outside it — so system
                // back, a state restore and any future redirect have no idea
                // this page exists.
                GoRoute(
                  path: 'cookies',
                  pageBuilder: (context, state) =>
                      _page(context, state, const CookieDomainsPage()),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

/// Shown for a path the app has no route for.
class _RouteNotFound extends StatelessWidget {
  const _RouteNotFound();

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return AppScaffold(
      title: 'Not here',
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.explore_off_outlined,
                size: 56,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'That link does not open anywhere in this app',
                style: context.textStyles.titleSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              AppButton.icon(
                onPressed: () => context.go('/download'),
                icon: Icons.home_outlined,
                label: const Text('Back to Download'),
                variant: AppButtonVariant.tonal,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when `/download/playlist` is reached without a playlist in `extra` —
/// for example by restoring a route from a stale deep link, since the
/// collection only exists as the result of a metadata fetch.
class _PlaylistUnavailable extends StatelessWidget {
  const _PlaylistUnavailable();

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    return AppScaffold(
      title: 'Playlist',
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.playlist_remove,
                size: 56,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'That playlist is no longer loaded',
                style: context.textStyles.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Fetch the playlist link again to pick videos from it.',
                textAlign: TextAlign.center,
                style: context.textStyles.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              AppButton.icon(
                onPressed: () => context.go('/download'),
                icon: Icons.arrow_back,
                label: const Text('Back to Download'),
                variant: AppButtonVariant.tonal,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
