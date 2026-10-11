import 'package:flutter/material.dart';

/// The palette and type ramp the screens read, in whichever root is running.
///
/// `Theme.of(context)` works under all three roots — [PlatformApp] installs a
/// Material `Theme` under the Cupertino and Fluent ones precisely so the
/// per-family widgets cannot render three different palettes. These accessors
/// exist so the screens say what they mean (`context.colors.onSurfaceVariant`)
/// instead of repeating the lookup, and so the day the Material fallback does
/// go away there is one place to change.
extension AppThemeContext on BuildContext {
  /// The colour roles for the current brightness.
  ColorScheme get colors => Theme.of(this).colorScheme;

  /// The type ramp for the current brightness.
  TextTheme get textStyles => Theme.of(this).textTheme;
}
