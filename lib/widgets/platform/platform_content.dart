import 'package:flutter/cupertino.dart'
    show CupertinoColors, CupertinoExpansionTile, CupertinoListTile;
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
import 'platform_gtk.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_theme_context.dart';
import 'platform_controls.dart';

/// A settings-style row: an optional icon, a title, a subtitle, and a trailing
/// control or a tap target.
///
/// Settings and the format sheet are assembled out of this, and the three
/// families disagree about almost every part of it: Material keeps its rows on
/// a card, Cupertino groups them in an inset list section with chevron-less
/// disclosure, and Fluent puts them on a flat card with a divider between rows.
/// The wrapper hands the row a flat canvas (`contentPadding: zero`) and lets the
/// section it sits in draw the group around it.
class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.contentPaddingZero = true,
    this.dense = false,
  });

  /// Tighter vertical padding, for a row that sits inside a group.
  final bool dense;

  final Widget? leading;
  final Widget title;

  /// A plain subtitle, styled per family. A [String] is the common case; a
  /// [Widget] is for the rows whose subtitle is itself a row of buttons or a
  /// progress bar, which [subtitleWidget] then holds.
  final Object? subtitle;

  final Widget? trailing;
  final VoidCallback? onTap;

  /// Set false where a call site wants the family's own row padding back.
  final bool contentPaddingZero;

  /// The subtitle as the families expect it: a styled [Text] for a string, the
  /// widget itself otherwise.
  Widget? subtitleFor(TextTheme text, Color onVariant) {
    if (subtitle case final String text2) {
      return Text(text2, style: text.bodySmall?.copyWith(color: onVariant));
    }
    if (subtitle case final Widget widget) return widget;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final subtitle = subtitleFor(text, colors.onSurfaceVariant);
    return switch (context.style) {
      PlatformStyle.material => ListTile(
        dense: dense,
        contentPadding: contentPaddingZero ? EdgeInsets.zero : null,
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: onTap,
      ),
      PlatformStyle.cupertino => CupertinoListTile(
        padding: contentPaddingZero
            ? EdgeInsets.zero
            : EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 8 : 12),
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: onTap,
      ),
      PlatformStyle.fluent => fui.ListTile(
        contentPadding: contentPaddingZero
            ? EdgeInsets.zero
            : EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 8 : 10),
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onPressed: onTap == null ? null : () => onTap!(),
      ),
      // GTK4's list row is flat and full-width, separated by a hairline rather
      // than by a card — a bordered group of rows, not a stack of them.
      PlatformStyle.gtk => GtkListRow(
        dense: dense,
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        onTap: onTap,
      ),
    };
  }
}

/// A titled group of settings.
///
/// Material draws a card with a rounded corner, Cupertino an inset-grouped
/// section with its own header, and Fluent a card with the standard square
/// corners. The header text is what the family uses for it, which is why the
/// section widget exists rather than each page styling a `Card` itself.
class AppSection extends StatelessWidget {
  const AppSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    // Material keeps the title as written; the other two families use their
    // own upper-case section header, which is what their settings screens do.
    final header = switch (context.style) {
      PlatformStyle.material => Text(title, style: text.titleSmall),
      _ => Text(
        title.toUpperCase(),
        style: text.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w700,
        ),
      ),
    };
    return switch (context.style) {
      PlatformStyle.material => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [header, const SizedBox(height: 12), child],
          ),
        ),
      ),
      // Adwaita's preferences group: a small title, then one bordered box
      // holding the rows.
      PlatformStyle.gtk => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6, top: 4),
              child: header,
            ),
            Container(
              decoration: BoxDecoration(
                color: colors.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(AppTheme.gtkSurfaceRadius),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            ),
          ],
        ),
      ),
      PlatformStyle.cupertino => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: header,
          ),
          Container(
            color: CupertinoColors.systemGroupedBackground,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: child,
            ),
          ),
        ],
      ),
      PlatformStyle.fluent => fui.Card(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DefaultTextStyle.merge(
              style: text.titleSmall ?? const TextStyle(),
              child: Text(title),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    };
  }
}

/// A standalone card, in the family the OS asked for.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.color, this.padding});

  final Widget child;
  final Color? color;

  /// Defaults to the family's own.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return switch (context.style) {
      PlatformStyle.material => Card(
        color: color,
        child: Padding(
          padding: padding ?? const EdgeInsets.all(16),
          child: child,
        ),
      ),
      PlatformStyle.cupertino => Container(
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color ?? CupertinoColors.systemGroupedBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
      PlatformStyle.fluent => fui.Card(
        backgroundColor: color ?? colors.surfaceContainerLow,
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      ),
      // A GTK card is a bordered box on the view background, not a raised
      // surface: 12dp corners, one hairline, no shadow.
      PlatformStyle.gtk => Container(
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color ?? colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppTheme.gtkSurfaceRadius),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: child,
      ),
    };
  }
}

/// A disclosure section, in the family the OS asked for.
///
/// Material's `ExpansionTile` keeps a chevron on the right, Cupertino's chevron
/// sits with the title, and Fluent's `Expander` is its own card with a chevron
/// that turns. All three say "there is more", which is what Settings' advanced
/// group is.
class AppExpander extends StatelessWidget {
  const AppExpander({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.tilePadding,
  });

  final String title;
  final Object? subtitle;
  final List<Widget> children;

  /// Only used where a family gives the header its own padding to override.
  final EdgeInsetsGeometry? tilePadding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final titleWidget = DefaultTextStyle.merge(
      style: (text.titleSmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w600,
      ),
      child: Text(title),
    );
    final Widget? subtitleWidget = switch (subtitle) {
      final String value => Text(
        value,
        style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      ),
      final Widget value => value,
      _ => null,
    };
    switch (context.style) {
      case PlatformStyle.material:
        return ExpansionTile(
          tilePadding: tilePadding ?? EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: titleWidget,
          subtitle: subtitleWidget,
          children: children,
        );
      case PlatformStyle.cupertino:
        // Cupertino's expander takes one child, so the section's rows are
        // wrapped in a column here rather than at every call site.
        return CupertinoExpansionTile(
          title: titleWidget,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [?subtitleWidget, ...children],
          ),
        );
      // GTK's expander is a bordered box: the header is a row inside it, and
      // the chevron turns. Its own disclosure, so no `ExpansionTile`.
      case PlatformStyle.gtk:
        return GtkExpander(
          title: titleWidget,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [?subtitleWidget, ...children],
          ),
        );
      case PlatformStyle.fluent:
        return fui.Expander(
          header: titleWidget,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
    }
  }
}

/// A tappable pill carrying a value, with a way to delete it.
///
/// The application's only use is a saved argument template, which fills the
/// field when tapped and deletes when the X is tapped. Material has
/// `InputChip`; the other two families have no chip at all, so this is a
/// bordered pill with an explicit close button.
class AppInputChip extends StatelessWidget {
  const AppInputChip({
    super.key,
    required this.label,
    required this.onPressed,
    required this.onDeleted,
    this.deleteTooltip,
  });

  final String label;
  final VoidCallback onPressed;
  final VoidCallback onDeleted;
  final String? deleteTooltip;

  @override
  Widget build(BuildContext context) {
    if (context.style == PlatformStyle.material) {
      return InputChip(
        label: Text(label),
        onPressed: onPressed,
        onDeleted: onDeleted,
        deleteButtonTooltipMessage: deleteTooltip,
      );
    }
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Material's ripple needs a Material ancestor, which the Fluent and
          // Cupertino roots do not have — so the tap is a plain gesture here.
          GestureDetector(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(label),
            ),
          ),
          const SizedBox(width: 4),
          AppIconButton(
            icon: Icons.close,
            tooltip: deleteTooltip,
            onPressed: onDeleted,
          ),
        ],
      ),
    );
  }
}

/// A pill that performs an action, in the family the OS asked for.
///
/// The output-template page inserts a field token per chip, so this is a
/// one-tap action rather than a selection. Material has `ActionChip`; the
/// others do not, and get the same bordered pill.
class AppActionChip extends StatelessWidget {
  const AppActionChip({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return switch (context.style) {
      PlatformStyle.material => ActionChip(
        label: Text(label),
        onPressed: onPressed,
      ),
      PlatformStyle.cupertino => GestureDetector(
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colors.primary),
          ),
          child: Text(label, style: TextStyle(color: colors.primary)),
        ),
      ),
      PlatformStyle.fluent => fui.Button(
        onPressed: onPressed,
        child: Text(label),
      ),
      // A GTK action pill: the same shape, and the one thing it always does is
      // fill on hover, because GTK has no "tap" state to animate.
      PlatformStyle.gtk => GtkPill(
        selected: false,
        onTap: onPressed,
        child: Text(label),
      ),
    };
  }
}

/// A round colour swatch that picks a seed colour, in the family the OS asked
/// for.
///
/// Material draws the InkWell ripple, which needs a Material ancestor — and
/// neither of the other two roots has one, so the tap here is a plain gesture
/// and the selected ring is what carries the state.
class AppSeedSwatch extends StatelessWidget {
  const AppSeedSwatch({
    super.key,
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? context.colors.onSurface
                      : context.colors.outlineVariant,
                  width: selected ? 3 : 1,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 18, color: _onColor(color))
                  : null,
            ),
            const SizedBox(height: 4),
            Text(name, style: context.textStyles.labelSmall),
          ],
        ),
      ),
    );
  }

  /// Black or white, whichever the swatch is readable on.
  static Color _onColor(Color background) => background.computeLuminance() > 0.5
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);
}
