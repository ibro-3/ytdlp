import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_theme_context.dart';

/// A dismissed-able strip listing what failed at start-up.
///
/// Shown rather than thrown: everything before `runApp` used to take the
/// process down, and an optional subsystem failing to initialise meant no app
/// at all with nothing to report. The same widget is drawn in whichever family
/// the OS asked for — a Material banner, a Cupertino one, a Windows `InfoBar`.
class StartupBanner extends StatefulWidget {
  const StartupBanner({super.key, required this.problems});

  /// Failures from start-up, in the user's terms.
  final List<String> problems;

  @override
  State<StartupBanner> createState() => _StartupBannerState();
}

class _StartupBannerState extends State<StartupBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final colors = context.colors;
    final text = context.textStyles;
    final problems = widget.problems;
    return switch (context.style) {
      PlatformStyle.material => Material(
        color: colors.errorContainer,
        child: SafeArea(
          bottom: false,
          child: _BannerRow(
            problems: problems,
            textStyle: text.bodySmall?.copyWith(color: colors.onErrorContainer),
            titleStyle: text.titleSmall?.copyWith(
              color: colors.onErrorContainer,
            ),
            iconColor: colors.onErrorContainer,
            accent: colors.errorContainer,
            onAccent: colors.onErrorContainer,
            onDismiss: _dismiss,
            borderRadius: BorderRadius.zero,
          ),
        ),
      ),
      // GTK's banner is the in-app kind: a rounded card on the view
      // background, with the same wording.
      PlatformStyle.gtk => Material(
        color: colors.errorContainer,
        child: SafeArea(
          bottom: false,
          child: _BannerRow(
            problems: problems,
            textStyle: text.bodySmall?.copyWith(color: colors.onErrorContainer),
            titleStyle: text.titleSmall?.copyWith(
              color: colors.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
            iconColor: colors.onErrorContainer,
            accent: colors.errorContainer,
            onAccent: colors.onErrorContainer,
            onDismiss: _dismiss,
            borderRadius: BorderRadius.circular(AppTheme.gtkSurfaceRadius),
          ),
        ),
      ),
      PlatformStyle.cupertino => Material(
        // Cupertino has no container that takes an arbitrary background and
        // stays above the page, so the banner keeps the Material one and only
        // its text and shape change: a rounded, inset strip, half-opaque, the
        // way a Mac notification reads.
        color: colors.errorContainer.withValues(alpha: 0.95),
        child: SafeArea(
          bottom: false,
          child: _BannerRow(
            problems: problems,
            textStyle: text.bodySmall?.copyWith(color: colors.onErrorContainer),
            titleStyle: text.titleSmall?.copyWith(
              color: colors.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
            iconColor: colors.onErrorContainer,
            accent: colors.errorContainer,
            onAccent: colors.onErrorContainer,
            onDismiss: _dismiss,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      PlatformStyle.fluent => Material(
        // The Fluent `InfoBar` needs a `FluentTheme` ancestor, and this banner
        // is built above the `Navigator` where the app's theme lives — so the
        // colours are applied here and the severity icon is all InfoBar this is.
        color: colors.errorContainer,
        child: SafeArea(
          bottom: false,
          child: _BannerRow(
            problems: problems,
            textStyle: text.bodySmall?.copyWith(color: colors.onErrorContainer),
            titleStyle: text.titleSmall?.copyWith(
              color: colors.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
            iconColor: colors.onErrorContainer,
            accent: colors.errorContainer,
            onAccent: colors.onErrorContainer,
            onDismiss: _dismiss,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    };
  }

  void _dismiss() {
    setState(() => _dismissed = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('These will be retried the next time the app starts.'),
        ),
      );
  }
}

/// The strip itself, shared by all three families.
///
/// The Material [IconButton] deliberately carries no `Tooltip`: a `Tooltip`
/// needs an `Overlay` ancestor, and this banner is built in the root's
/// `builder` — above the `Navigator`, so there is none. Using one threw every
/// time the banner appeared, which is to say exactly when it was needed. The
/// `Semantics` wrapper gives assistive tech the same label without it.
class _BannerRow extends StatelessWidget {
  const _BannerRow({
    required this.problems,
    required this.textStyle,
    required this.titleStyle,
    required this.iconColor,
    required this.accent,
    required this.onAccent,
    required this.onDismiss,
    required this.borderRadius,
  });

  final List<String> problems;
  final TextStyle? textStyle;
  final TextStyle? titleStyle;
  final Color iconColor;
  final Color accent;
  final Color onAccent;
  final VoidCallback onDismiss;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: accent, borderRadius: borderRadius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    problems.length == 1
                        ? 'Part of the app did not start'
                        : '${problems.length} parts of the app did not start',
                    style: titleStyle,
                  ),
                  for (final problem in problems)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(problem, style: textStyle),
                    ),
                ],
              ),
            ),
            Semantics(
              button: true,
              label: 'Dismiss',
              child: IconButton(
                onPressed: onDismiss,
                icon: const Icon(Icons.close),
                color: onAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
