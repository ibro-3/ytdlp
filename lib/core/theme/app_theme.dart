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

  // --- GTK / Adwaita -------------------------------------------------------

  /// The GNOME UI font. Absent on many machines, in which case Flutter falls
  /// back to its bundled default and nothing else changes.
  static const String gtkFontFamily = 'Cantarell';

  /// A GTK header bar's height (42dp, the libadwaita default).
  static const double gtkHeaderHeight = 42;

  /// A GTK control's height. Adwaita's default is 32–34dp, not the 48dp touch
  /// target Android uses — this is a mouse-driven desktop.
  static const double gtkControlHeight = 34;

  /// Adwaita's corner radius for a button or an entry.
  static const double gtkRadius = 6;

  /// Adwaita's corner radius for a card, popover or dialog.
  static const double gtkSurfaceRadius = 12;

  /// Adwaita's switch: 52×24, with a knob that slides rather than fades.
  static const Size gtkSwitchSize = Size(52, 24);

  /// The Linux look: GTK4's Adwaita, derived from the same seed as the others.
  ///
  /// Adwaita's surfaces are *neutral* greys — a GTK app's window is grey whether
  /// its accent is blue, red or purple — so the seeded [ColorScheme] contributes
  /// the accent (the seed stays the user's choice) and the greys come from
  /// Adwaita's own named values. Everything else is metric: 34dp controls, a
  /// 42dp header bar, 6dp corners on controls and 12dp on surfaces. Not a single
  /// pixel of it is Material chrome, which is what makes a Linux window read as
  /// a GTK app rather than as an Android app that has been retinted.
  static ThemeData gtk({required Brightness brightness, Color? seedColor}) {
    final cs = ColorScheme.fromSeed(
      seedColor: seedColor ?? seed,
      brightness: brightness,
    );
    final isLight = brightness == Brightness.light;
    final greys = isLight
        ? const (
            window: Color(0xFFFAFAFA),
            view: Color(0xFFFFFFFF),
            header: Color(0xFFEBEBEB),
            hover: Color(0xFFEBEBEB),
            fill: Color(0xFFF2F2F2),
            border: Color(0xFFC0C0C0),
            text: Color(0xFF1A1A1A),
          )
        : const (
            window: Color(0xFF2B2B2B),
            view: Color(0xFF353535),
            header: Color(0xFF303030),
            hover: Color(0xFF3C3C3C),
            fill: Color(0xFF333333),
            border: Color(0xFF1B1B1B),
            text: Color(0xFFFFFFFF),
          );

    final scheme = cs.copyWith(
      surface: greys.window,
      surfaceContainerLowest: greys.view,
      surfaceContainerLow: greys.view,
      surfaceContainer: greys.window,
      surfaceContainerHigh: greys.header,
      surfaceContainerHighest: greys.header,
      onSurface: greys.text,
      onSurfaceVariant: greys.text.withValues(alpha: 0.7),
      outline: greys.border,
      outlineVariant: greys.border.withValues(alpha: 0.6),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: gtkFontFamily,
      // No ink anywhere: GTK has no ripple, and an InkSparkle on a GNOME
      // desktop is the single loudest "this is not a GTK app" signal.
      splashFactory: NoSplash.splashFactory,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: greys.header,
        foregroundColor: greys.text,
        scrolledUnderElevation: 0,
        // GTK's header bar carries the window's title, so its title is not
        // centred the way Android's is.
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: gtkFontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: greys.text,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: greys.view,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(gtkSurfaceRadius),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, gtkControlHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(gtkRadius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, gtkControlHeight),
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(gtkRadius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, gtkControlHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(gtkRadius),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        // An underline on focus, not a filled box: GTK's entry is a bordered
        // rectangle that lights its border, and it never grows a background.
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(gtkRadius)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(gtkRadius)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(gtkRadius)),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 4,
        // GTK's slider knob is a plain circle, 20dp.
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.all(12),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(gtkSurfaceRadius)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: greys.view,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(gtkSurfaceRadius)),
        ),
      ),
    );
  }

  /// The neutral greys [gtk] draws its surfaces from, named so the wrappers use
  /// the same ones rather than each picking its own.
  static ({
    Color window,
    Color view,
    Color header,
    Color hover,
    Color fill,
    Color border,
    Color text,
  })
  gtkGreys(Brightness brightness) => brightness == Brightness.light
      ? const (
          window: Color(0xFFFAFAFA),
          view: Color(0xFFFFFFFF),
          header: Color(0xFFEBEBEB),
          hover: Color(0xFFEBEBEB),
          fill: Color(0xFFF2F2F2),
          border: Color(0xFFC0C0C0),
          text: Color(0xFF1A1A1A),
        )
      : const (
          window: Color(0xFF2B2B2B),
          view: Color(0xFF353535),
          header: Color(0xFF303030),
          hover: Color(0xFF3C3C3C),
          fill: Color(0xFF333333),
          border: Color(0xFF1B1B1B),
          text: Color(0xFFFFFFFF),
        );
}
