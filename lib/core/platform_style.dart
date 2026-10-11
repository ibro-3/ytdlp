import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Which of the three widget families the app draws itself with.
///
/// The app follows the host OS rather than carrying one look everywhere:
/// Material 3 on Android (and Linux, which has no Cupertino or Fluent
/// equivalent), Cupertino on Apple platforms, and Fluent UI on Windows.
/// There is no user setting that overrides this — the OS decides, which is the
/// point.
///
/// Derived from [defaultTargetPlatform] rather than [Platform] from `dart:io`
/// so the same value is available in tests through
/// `debugDefaultTargetPlatformOverride`: that is what lets every style be
/// exercised from one test host.
enum PlatformStyle {
  /// Material 3. Android, and Linux as the nearest desktop equivalent.
  material,

  /// Cupertino. Apple platforms.
  cupertino,

  /// Fluent UI. Windows.
  fluent,
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
  TargetPlatform.android ||
  TargetPlatform.fuchsia ||
  TargetPlatform.linux => PlatformStyle.material,
};

/// True when the current style draws Apple-style widgets.
bool get isCupertinoStyle =>
    platformStyleOf(defaultTargetPlatform) == PlatformStyle.cupertino;
