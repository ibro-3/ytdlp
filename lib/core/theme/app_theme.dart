import 'package:flutter/material.dart';

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
  }) =>
      _build(brightness, scheme, seedColor);

  static ThemeData _build(Brightness brightness,
      [ColorScheme? scheme, Color? seedColor]) {
    final cs = scheme ??
        ColorScheme.fromSeed(
            seedColor: seedColor ?? seed, brightness: brightness);
    final base = ThemeData(
      colorScheme: cs,
      brightness: brightness,
      useMaterial3: true,
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: const AppBarTheme(scrolledUnderElevation: 0, centerTitle: false),
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
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
}
