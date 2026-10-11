import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Which of the four widget families the app draws itself with.
///
/// The app follows the host OS rather than carrying one look everywhere:
/// Material 3 on Android, Cupertino on Apple platforms, Fluent UI on Windows,
/// and the GTK4/Adwaita look on Linux. There is no user setting that overrides
/// this — the OS decides, which is the point.
///
/// Derived from [defaultTargetPlatform] rather than [Platform] from `dart:io`
/// so the same value is available in tests through
/// `debugDefaultTargetPlatformOverride`: that is what lets every style be
/// exercised from one test host.
enum PlatformStyle {
  /// Material 3. Android.
  material,

  /// Cupertino. Apple platforms.
  cupertino,

  /// Fluent UI. Windows.
  fluent,

  /// GTK4's Adwaita. Linux.
  ///
  /// Drawn in the wrapper layer rather than by a package: the pub `libadwaita`
  /// package pins `package_info_plus` below 5 and `flutter_svg` below 3, both
  /// of which this app needs much newer versions of, so the family is built
  /// from the same Material widgets the app already uses plus Adwaita's own
  /// metrics and colours. The window itself is still the GTK3 embedder Flutter
  /// ships for Linux — GTK4 is the look, not the toolkit underneath.
  gtk,
}

/// The style the current platform gets.
extension PlatformStyleContext on BuildContext {
  PlatformStyle get style => platformStyleOf(defaultTargetPlatform);
}

/// Maps a Flutter platform onto [PlatformStyle].
///
/// [TargetPlatform.iOS] is mapped even though the app does not build for iOS
/// (README records it as dropped): mapping it costs nothing, and a lone
/// simulator run then checks out as Apple rather than as Android.
PlatformStyle platformStyleOf(TargetPlatform platform) => switch (platform) {
  TargetPlatform.iOS || TargetPlatform.macOS => PlatformStyle.cupertino,
  TargetPlatform.windows => PlatformStyle.fluent,
  TargetPlatform.linux => PlatformStyle.gtk,
  TargetPlatform.android || TargetPlatform.fuchsia => PlatformStyle.material,
};
