import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/playlist_info.dart';
import '../../features/home/home_page.dart';
import '../../features/library/library_page.dart';
import '../../features/playlist/playlist_page.dart';
import '../../features/queue/batch_queue_page.dart';
import '../../features/queue/queue_page.dart';
import '../../features/settings/cookie_domains_page.dart';
import '../../features/settings/settings_page.dart';
import '../../widgets/app_shell.dart';

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
              builder: (context, state) => const HomePage(),
              routes: [
                // A playlist the user picked from the Download tab. The
                // playlist rides in `extra` because it only exists as the
                // result of a fetch; there is no URL to deep-link to.
                GoRoute(
                  path: 'playlist',
                  builder: (context, state) {
                    final playlist = state.extra;
                    if (playlist is! PlaylistInfo) {
                      return const _PlaylistUnavailable();
                    }
                    return PlaylistPage(playlist: playlist);
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
              builder: (context, state) => const QueuePage(),
              routes: [
                GoRoute(
                  path: 'batch',
                  builder: (context, state) => const BatchQueuePage(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              builder: (context, state) => const LibraryPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsPage(),
              routes: [
                // A real route rather than a `Navigator.push` with a
                // MaterialPageRoute: every other navigation goes through the
                // router, and an imperative push sits outside it — so system
                // back, a state restore and any future redirect have no idea
                // this page exists.
                GoRoute(
                  path: 'cookies',
                  builder: (context, state) => const CookieDomainsPage(),
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Not here')),
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
                style: Theme.of(context).textTheme.titleSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/download'),
                icon: const Icon(Icons.home_outlined),
                label: const Text('Back to Download'),
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Playlist')),
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
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                'Fetch the playlist link again to pick videos from it.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/download'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back to Download'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
