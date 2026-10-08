import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class App extends ConsumerWidget {
  const App({super.key, this.startupProblems = const []});

  /// Failures from start-up, in the user's terms.
  ///
  /// Shown rather than thrown: everything that happens before `runApp` used to
  /// take the process down with a blank screen, so an optional subsystem failing
  /// to initialise meant no app at all and nothing to report.
  final List<String> startupProblems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return MaterialApp.router(
      title: 'YTDL',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(settings.seed),
      darkTheme: AppTheme.dark(settings.seed),
      themeMode: settings.themeMode,
      routerConfig: appRouter,
      builder: (context, child) {
        if (startupProblems.isEmpty) return child ?? const SizedBox.shrink();
        // Above the app rather than in place of it: the failed subsystem may be
        // the only thing broken, so the rest stays usable.
        return Stack(
          children: [
            ?child,
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              // Stateful so the dismissal actually sticks. MaterialApp's builder
              // result is cached against the settings it was built from, so a
              // plain callback here would have nowhere to record that the user
              // closed it.
              child: _StartupBanner(problems: startupProblems),
            ),
          ],
        );
      },
    );
  }
}

/// Reports what failed to start, until the user dismisses it.
///
/// Dismissal is remembered because the notice is not actionable: the remedies
/// are a restart for all of these, and a banner the user cannot get rid of would
/// sit over the app for the rest of the session.
class _StartupBanner extends StatefulWidget {
  const _StartupBanner({required this.problems});

  final List<String> problems;

  @override
  State<_StartupBanner> createState() => _StartupBannerState();
}

class _StartupBannerState extends State<_StartupBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final problems = widget.problems;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      problems.length == 1
                          ? 'Part of the app did not start'
                          : '${problems.length} parts of the app did not start',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    for (final problem in problems)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          problem,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Semantics(
                button: true,
                label: 'Dismiss',
                child: IconButton(
                  onPressed: () {
                    setState(() => _dismissed = true);
                    messenger
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text(
                            'These will be retried the next time the app starts.',
                          ),
                        ),
                      );
                  },
                  icon: const Icon(Icons.close),
                  // A `Tooltip` needs an `Overlay` ancestor, and this banner is
                  // built in `MaterialApp.builder` — above the `Navigator`, so
                  // there is none. Using one threw every time the banner
                  // appeared, which is to say exactly when it was needed. The
                  // `Semantics` wrapper above gives assistive tech the same
                  // label without needing the overlay.
                  color: scheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
