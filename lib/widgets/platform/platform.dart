/// The platform UI layer.
///
/// One barrel so screens import a single file and get the family switch for
/// free; the individual files exist because a screen that only ever needed
/// `AppScaffold` should not have to pull in `fluent_ui` to get it.
library;

export 'platform_controls.dart';
export 'platform_content.dart';
export 'platform_feedback.dart';
export 'platform_inputs.dart';
export 'platform_scaffold.dart';
export 'platform_toast.dart';
