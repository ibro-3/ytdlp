import 'package:flutter/cupertino.dart' show CupertinoApp;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluent_ui/fluent_ui.dart' as fui;

import '../../core/platform_style.dart';
import '../../core/providers.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../startup_banner.dart';

/// The app's root: one of the four OS widget families, chosen once.
///
/// The alternative — one Material app retinted three ways — is what this
/// replaced, and it is why the previous build looked like an Android app
/// wherever it ran. Every screen below this point is built from the wrappers in
/// `lib/widgets/platform/`, which each render the family the OS asked for.
///
/// Two invariants hold under all three roots, and they are what keep the tree
/// alive during a partially converted screen:
///
///  1. All three localization delegate sets are registered. `CupertinoApp` and
///     `FluentApp` only register their own, so a Material widget that has not
///     been converted yet would throw `No MaterialLocalizations found` — i.e.
///     exactly when it is needed to render.
///  2. A Material `Theme` is installed under every root. It supplies the
///     `colorScheme`/`textTheme` that `Theme.of(context)` resolves to, so
///     colours read the same wherever the app runs while the *widgets* around
///     them differ.
class PlatformApp extends ConsumerWidget {
  const PlatformApp({super.key, required this.startupProblems});

  /// Failures from start-up, in the user's terms. Shown above the app rather
  /// than in place of it: the failed subsystem may be the only thing broken.
  final List<String> startupProblems;

  /// All three, not each root's own. See invariant 1.
  static final _localizationsDelegates = <LocalizationsDelegate<Object?>>[
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final style = context.style;

    // CupertinoApp has no `themeMode`: it takes a single `CupertinoThemeData`
    // and falls back to `MediaQuery.platformBrightnessOf(context)`. The
    // system/light/dark setting is therefore resolved here, once, rather than
    // left to each root to interpret.
    final resolved = _resolveBrightness(context, settings.themeMode);

    Widget buildUnderRoot(BuildContext context, Widget? child) {
      var content = child ?? const SizedBox.shrink();
      if (style != PlatformStyle.material) {
        content = _materialFallback(content, style, resolved, settings.seed);
      }
      if (startupProblems.isEmpty) return content;
      // Above the app rather than in place of it: the failed subsystem may be
      // the only thing broken, so the rest stays usable.
      return Stack(
        children: [
          content,
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: StartupBanner(problems: startupProblems),
          ),
        ],
      );
    }

    switch (style) {
      case PlatformStyle.material:
        return MaterialApp.router(
          title: 'YTDL',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(settings.seed),
          darkTheme: AppTheme.dark(settings.seed),
          themeMode: settings.themeMode,
          routerConfig: appRouter,
          builder: buildUnderRoot,
        );
      case PlatformStyle.cupertino:
        return CupertinoApp.router(
          title: 'YTDL',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.cupertino(
            brightness: resolved,
            seedColor: settings.seed,
          ),
          routerConfig: appRouter,
          localizationsDelegates: _localizationsDelegates,
          builder: buildUnderRoot,
        );
      case PlatformStyle.gtk:
        // A Material root, because the family is drawn from Material widgets
        // plus Adwaita's own metrics and greys: there is no GTK package whose
        // theme the way Fluent's would have to be provided.
        return MaterialApp.router(
          title: 'YTDL',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.gtk(brightness: resolved, seedColor: settings.seed),
          // A MaterialApp takes a theme *pair*, so this is the other half of
          // the same light/dark choice rather than a second derivation.
          darkTheme: AppTheme.gtk(
            brightness: resolved == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            seedColor: settings.seed,
          ),
          themeMode: settings.themeMode,
          routerConfig: appRouter,
          builder: buildUnderRoot,
        );
      case PlatformStyle.fluent:
        return fui.FluentApp.router(
          title: 'YTDL',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.fluent(
            brightness: resolved,
            seedColor: settings.seed,
          ),
          darkTheme: AppTheme.fluent(
            brightness: resolved == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            seedColor: settings.seed,
          ),
          themeMode: settings.themeMode,
          routerConfig: appRouter,
          localizationsDelegates: _localizationsDelegates,
          builder: buildUnderRoot,
        );
    }
  }

  /// Installs the Material fallback (invariant 2) and a family-appropriate
  /// default text style, which the two non-Material roots do not supply.
  Widget _materialFallback(
    Widget child,
    PlatformStyle style,
    Brightness brightness,
    Color seed,
  ) {
    final material = AppTheme.themed(brightness: brightness, seedColor: seed);
    final TextStyle? familyDefault = style == PlatformStyle.cupertino
        ? AppTheme.cupertino(
            brightness: brightness,
            seedColor: seed,
          ).textTheme.textStyle
        : AppTheme.fluent(
            brightness: brightness,
            seedColor: seed,
          ).typography.body;
    return Theme(
      data: material,
      // `WidgetsApp` only sets a `DefaultTextStyle` when `textStyle` is passed,
      // and `MaterialApp` passes one while the other two roots do not — so a
      // bare `Text` would otherwise render 14sp black under both.
      child: DefaultTextStyle(
        style:
            familyDefault ?? material.textTheme.bodyMedium ?? const TextStyle(),
        child: child,
      ),
    );
  }

  /// The light/dark setting, resolved against the platform preference when it
  /// is "system".
  static Brightness _resolveBrightness(BuildContext context, ThemeMode mode) =>
      switch (mode) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system => MediaQuery.platformBrightnessOf(context),
      };
}
