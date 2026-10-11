import 'package:flutter/cupertino.dart' show CupertinoThemeData;
import 'package:flutter/material.dart';

// Aliased, and deliberately so: fluent_ui exports `Card`, `ListTile`, `Slider`,
// `IconButton`, `Divider`, `Checkbox` and `showDialog`, all of which collide by
// name with the Material widgets this theme still builds. An alias keeps both
// families readable in one file — and doubling as the `AppTheme.fluent` name
// would shadow the prefix, were it not aliased.
import 'package:fluent_ui/fluent_ui.dart' as fui;

class AppTheme {
  const AppTheme._();

  static const Color seed = Color(0xFFD32F2F);

  static ThemeData light([Color? seedColor]) =>
      _build(Brightness.light, null, seedColor);
  static ThemeData dark([Color? seedColor]) =>
      _build(Brightness.dark, null, seedColor);

  static ThemeData themed({
    required Brightness brightness,
    required Color seedColor,
    ColorScheme? scheme,
  }) => _build(brightness, scheme, seedColor);

  static ThemeData _build(
    Brightness brightness, [
    ColorScheme? scheme,
    Color? seedColor,
  ]) {
    final cs =
        scheme ??
        ColorScheme.fromSeed(
          seedColor: seedColor ?? seed,
          brightness: brightness,
        );
    final base = ThemeData(
      colorScheme: cs,
      brightness: brightness,
      useMaterial3: true,
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: const AppBarTheme(
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: cs.surfaceContainer,
        indicatorColor: cs.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        elevation: 0,
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
        side: WidgetStatePropertyAll(BorderSide(color: cs.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// The Apple look, derived from the same seed as [light]/[dark].
  ///
  /// Cupertino's surfaces are fixed greys rather than a tinted scheme, so only
  /// the accent, the bar background and the scaffold are taken from the
  /// seeded [ColorScheme]; the rest stays stock, because a red-tinted iOS
  /// switch reads as a bug rather than as a theme.
  static CupertinoThemeData cupertino({
    required Brightness brightness,
    Color? seedColor,
  }) {
    final cs = ColorScheme.fromSeed(
      seedColor: seedColor ?? seed,
      brightness: brightness,
    );
    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: cs.primary,
      primaryContrastingColor: cs.onPrimary,
      barBackgroundColor: cs.surfaceContainer,
      scaffoldBackgroundColor: cs.surface,
      // Left on purpose: the stock Cupertino text styles are the point of the
      // family — the iOS body text is not the Material `bodyMedium`.
    );
  }

  /// The Windows look, derived from the same seed as [light]/[dark].
  ///
  /// Only the accent is derived: Fluent's remaining surfaces come from its own
  /// resource dictionary greys, and seeding all of them would give a red-tinted
  /// Windows that no Windows app looks like. The 4px corner radius Fluent uses
  /// by default is left alone for the same reason.
  static fui.FluentThemeData fluent({
    required Brightness brightness,
    Color? seedColor,
  }) {
    final cs = ColorScheme.fromSeed(
      seedColor: seedColor ?? seed,
      brightness: brightness,
    );
    return fui.FluentThemeData(
      brightness: brightness,
      accentColor: (seedColor ?? seed).toAccentColor(),
      scaffoldBackgroundColor: cs.surface,
      micaBackgroundColor: cs.surface,
      acrylicBackgroundColor: cs.surfaceContainer,
      cardColor: cs.surfaceContainerLow,
      menuColor: cs.surfaceContainerHigh,
    );
  }
}
