import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class App extends ConsumerWidget {
  const App({super.key});

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
    );
  }
}
