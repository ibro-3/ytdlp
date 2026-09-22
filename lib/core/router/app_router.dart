import 'package:go_router/go_router.dart';

import '../../features/home/home_page.dart';
import '../../features/library/library_page.dart';
import '../../features/queue/queue_page.dart';
import '../../widgets/app_shell.dart';

final appRouter = GoRouter(
  initialLocation: '/download',
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
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/queue',
              builder: (context, state) => const QueuePage(),
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
      ],
    ),
  ],
);
