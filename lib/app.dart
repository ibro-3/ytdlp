import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'widgets/platform/platform_app.dart';

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
    // The root chooses its own widget family: Material on Android and Linux,
    // Cupertino on macOS, Fluent on Windows. Which screen is showing is a
    // platform fact, so there is no way to pick one from here.
    return PlatformApp(startupProblems: startupProblems);
  }
}
