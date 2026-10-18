import 'package:flutter/cupertino.dart'
    show
        CupertinoCheckbox,
        CupertinoPicker,
        CupertinoSlidingSegmentedControl,
        CupertinoSearchTextField,
        CupertinoSegmentedControl,
        CupertinoSlider,
        CupertinoSwitch,
        CupertinoTextField,
        FixedExtentScrollController;
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../core/platform_style.dart';
import 'platform_gtk.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_theme_context.dart';
import 'platform_controls.dart';
import 'platform_feedback.dart';

/// A single-choice row of options, in the family the OS asked for.
///
/// Material's `SegmentedButton` is a connected pill; Cupertino's is a segmented
/// control with a moving thumb; Fluent's is a toggle button group. The app feeds
/// this from `AppSettings`-style label+icon pairs, so the wrapper owns the
/// mapping and the screens keep naming their options once.
class AppSegmented<T extends Object> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
  });

  /// One option per segment, in order.
  ///
  /// `enabled` is the app's way of saying the option cannot be picked (no
  /// audio streams to choose from, say). Material greys a disabled
  /// `ButtonSegment`; Cupertino and Fluent have no per-segment disabled state,
  /// so they get a dimmed, inert one.
  final List<({T value, String label, IconData? icon, bool enabled})> segments;

  /// The selected value, or null when nothing is.
  final T? selected;

  final ValueChanged<T> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    switch (context.style) {
      case PlatformStyle.material:
        return SegmentedButton<T>(
          segments: [
            for (final s in segments)
              ButtonSegment<T>(
                value: s.value,
                enabled: s.enabled,
                label: Text(s.label),
                icon: s.icon == null ? null : Icon(s.icon),
              ),
          ],
          selected: selected == null ? <T>{} : {selected!},
          onSelectionChanged: (s) => onSelectionChanged(s.first),
        );

      case PlatformStyle.cupertino:
        return CupertinoSegmentedControl<T>(
          children: {
            for (final s in segments)
              s.value: _SegmentedLabel(
                label: s.label,
                icon: s.icon,
                enabled: s.enabled,
              ),
          },
          groupValue: selected,
          onValueChanged: (v) {
            // A disabled segment is drawn but does not select: neither of the
            // other two families can disable a segment, so the control stays
            // one piece and the option is refused here.
            final segment = segments.firstWhere((x) => x.value == v);
            if (!segment.enabled) return;
            onSelectionChanged(v);
          },
          // The thumb is the accent; the unselected part stays the stock grey,
          // because a segmented control is chrome, not an accent surface.
          unselectedColor: colors.surfaceContainerHighest,
          selectedColor: colors.primary,
        );
      case PlatformStyle.fluent:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in segments)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: fui.ToggleButton(
                  checked: s.value == selected,
                  // Null onChanged is Fluent's disabled toggle.
                  onChanged: s.enabled
                      ? (_) => onSelectionChanged(s.value)
                      : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (s.icon != null) ...[
                        Icon(s.icon, size: 16),
                        const SizedBox(width: 6),
                      ],
                      Text(s.label),
                    ],
                  ),
                ),
              ),
          ],
        );
      case PlatformStyle.gtk:
        // GTK4's linked box: one bordered control with a divider between the
        // options and the current one filled — no pill, no gap.
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
            border: Border.all(color: colors.outline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < segments.length; i++)
                GtkSegmentedItem<T>(
                  segment: segments[i],
                  selected: segments[i].value == selected,
                  first: i == 0,
                  last: i == segments.length - 1,
                  onTap: () => onSelectionChanged(segments[i].value),
                ),
            ],
          ),
        );
    }
  }
}

/// A selectable pill, in the family the OS asked for.
///
/// Material has `Chip`/`ChoiceChip`; the other two have no chip, which is fine:
/// what the control communicates is "chosen", and a bordered toggle button reads
/// the same thing in both Fluent and Cupertino.
class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final border = _chipBorder(colors, selected);
    return switch (context.style) {
      PlatformStyle.material => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
        visualDensity: VisualDensity.compact,
      ),
      PlatformStyle.cupertino => GestureDetector(
        onTap: () => onSelected(!selected),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? colors.primary : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            border: border,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onPrimary : colors.onSurface,
              fontSize: 13,
            ),
          ),
        ),
      ),
      PlatformStyle.fluent => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: fui.ToggleButton(
          checked: selected,
          onChanged: onSelected,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(label),
          ),
        ),
      ),
      PlatformStyle.gtk => GtkPill(
        selected: selected,
        onTap: () => onSelected(true),
        child: Text(label),
      ),
    };
  }

  static Border? _chipBorder(ColorScheme colors, bool selected) =>
      selected ? null : Border.all(color: colors.outlineVariant);
}

/// An on/off control, in the family the OS asks for.
///
/// Material's is a rounded track with a thumb, Cupertino's is a rounded pill,
/// Fluent's is a square switch with a knob — three genuinely different controls
/// saying the same thing, which is the point of the wrapper.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return switch (context.style) {
      PlatformStyle.material => Switch(value: value, onChanged: onChanged),
      PlatformStyle.cupertino => CupertinoSwitch(
        value: value,
        onChanged: onChanged,
      ),
      PlatformStyle.fluent => fui.ToggleSwitch(
        checked: value,
        onChanged: (v) => onChanged(v),
      ),
      PlatformStyle.gtk => GtkSwitch(value: value, onChanged: onChanged),
    };
  }
}

/// A row that ends in an [AppSwitch].
///
/// Material's `SwitchListTile` is one widget; neither Cupertino nor Fluent
/// ships the equivalent, so the wrapper builds the row and puts a family control
/// on the right. Settings is built almost entirely out of this.
class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.dense = false,
    this.leading,
    this.enabled = true,
  });

  final Widget title;

  /// Plain text, or a widget when the subtitle is not plain text — a
  /// `Text('…')` carrying its own colour, say. The wrapper styles the former
  /// and passes the latter through untouched.
  final Object? subtitle;

  final Widget? leading;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool dense;

  /// When false the switch can be read but not moved. Material spells this as a
  /// null callback; the other two families need it said.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    // Named `subtitleRow` rather than `subtitle` so it does not shadow the
    // field it is derived from.
    final Widget? subtitleRow = switch (subtitle) {
      final String value => Text(
        value,
        style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
      ),
      final Widget value => value,
      _ => null,
    };
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle.merge(
                style: text.bodyLarge ?? const TextStyle(),
                child: title,
              ),
              if (subtitleRow != null) ...[
                const SizedBox(height: 2),
                subtitleRow,
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        AppSwitch(value: value, onChanged: onChanged),
      ],
    );
    final result = Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 4 : 8),
      child: row,
    );
    final disabled = enabled
        ? null
        : context.textStyles.bodySmall?.copyWith(
            color: context.colors.onSurface.withValues(alpha: 0.38),
          );
    final body = DefaultTextStyle.merge(style: disabled, child: result);
    if (context.style == PlatformStyle.material) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: dense,
        title: title,
        subtitle: subtitleRow,
        secondary: leading,
        value: value,
        onChanged: enabled ? onChanged : null,
      );
    }
    return body;
  }
}

/// A value slider, in the family the OS asked for.
class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 100,
    this.divisions,
    this.label,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return switch (context.style) {
      PlatformStyle.material => Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: onChanged,
      ),
      PlatformStyle.cupertino => CupertinoSlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
      PlatformStyle.fluent => fui.Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: onChanged,
      ),
      // GTK's slider is a 4dp track with a plain round knob; the theme already
      // sets the track height, and the knob shape is the only thing missing.
      PlatformStyle.gtk => SliderTheme(
        data: SliderThemeData(
          trackHeight: 4,
          thumbShape: const RoundSliderThumbShape(
            enabledThumbRadius: 10,
            elevation: 0,
          ),
          overlayShape: SliderComponentShape.noOverlay,
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
        ),
      ),
    };
  }
}

/// A single-line text field, in the family the OS asked for.
///
/// The Material `TextField`, the Cupertino one and the Fluent `TextBox` have
/// different placeholder and border mechanics; the wrapper takes the app's
/// shape (a placeholder, a submit action) and maps it onto each.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.placeholder,
    this.onSubmitted,
    this.onChanged,
    this.obscureText = false,
    this.maxLines = 1,
    this.autofocus = false,
    this.enabled = true,
    this.prefix,
    this.suffix,
  });

  final TextEditingController? controller;
  final String? placeholder;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool obscureText;
  final int maxLines;
  final bool autofocus;
  final bool enabled;

  /// A leading icon or action, inset inside the field rather than outside it.
  final Widget? prefix;

  /// A trailing one — a clear button, say.
  final Widget? suffix;

  // The Material `TextField` takes its own `prefixIcon`/`suffixIcon`, the other
  // two families a widget before/after the field. Both spell it as this pair.
  List<Widget> get _suffixRow => suffix == null ? const [] : [suffix!];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return switch (context.style) {
      PlatformStyle.material => TextField(
        controller: controller,
        obscureText: obscureText,
        maxLines: obscureText ? 1 : maxLines,
        autofocus: autofocus,
        enabled: enabled,
        decoration: InputDecoration(
          hintText: placeholder,
          border: const OutlineInputBorder(),
          isDense: true,
          prefixIcon: prefix,
          suffixIcon: suffix,
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
      ),
      PlatformStyle.cupertino => Row(
        children: [
          if (prefix != null) ...[prefix!, const SizedBox(width: 8)],
          Expanded(
            child: CupertinoTextField(
              controller: controller,
              obscureText: obscureText,
              maxLines: obscureText ? 1 : maxLines,
              autofocus: autofocus,
              enabled: enabled,
              placeholder: placeholder,
              style: TextStyle(color: colors.onSurface),
              onSubmitted: onSubmitted,
              onChanged: onChanged,
            ),
          ),
          if (suffix != null) ...[const SizedBox(width: 8), suffix!],
        ],
      ),
      // A Material `TextField`, because the GTK look is an entry theme rather
      // than a different widget: `AppTheme.gtk`'s `inputDecorationTheme` is
      // what makes it a bordered box with a 2dp focused frame.
      PlatformStyle.gtk => TextField(
        controller: controller,
        obscureText: obscureText,
        maxLines: obscureText ? 1 : maxLines,
        autofocus: autofocus,
        enabled: enabled,
        decoration: InputDecoration(
          hintText: placeholder,
          prefixIcon: prefix,
          suffixIcon: suffix,
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
      ),
      PlatformStyle.fluent => fui.TextBox(
        controller: controller,
        obscureText: obscureText,
        maxLines: obscureText ? 1 : maxLines,
        autofocus: autofocus,
        enabled: enabled,
        placeholder: placeholder,
        prefix: prefix,
        suffix: suffix == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _suffixRow,
                ),
              ),
        onSubmitted: onSubmitted,
        onChanged: onChanged,
      ),
    };
  }
}

/// The URL bar on the Download screen: a search field, in the family the OS
/// asked for.
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    required this.controller,
    this.placeholder,
    this.trailing,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? placeholder;
  final List<Widget>? trailing;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    switch (context.style) {
      case PlatformStyle.material:
        return SearchBar(
          controller: controller,
          hintText: placeholder,
          leading: const Icon(Icons.link),
          trailing: trailing,
          onSubmitted: onSubmitted,
        );
      case PlatformStyle.cupertino:
        return CupertinoSearchTextField(
          controller: controller,
          placeholder: placeholder,
          style: TextStyle(color: colors.onSurface),
          onSubmitted: onSubmitted,
        );
      case PlatformStyle.gtk:
        // GTK's search entry is the same bordered box, with the icon inside it
        // and no fill.
        return TextField(
          controller: controller,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: placeholder,
            prefixIcon: const Icon(Icons.link, size: 18),
            suffixIcon: trailing == null
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: trailing!),
          ),
        );
      case PlatformStyle.fluent:
        return fui.TextBox(
          controller: controller,
          placeholder: placeholder,
          prefix: const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(Icons.link, size: 18),
          ),
          suffix: trailing == null
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: trailing!),
          onSubmitted: onSubmitted,
        );
    }
  }
}

/// A checkbox, in the family the OS asked for.
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({super.key, required this.value, required this.onChanged});

  /// A checkbox the user cannot interact with, painted the way the OS paints
  /// disabled controls — as opposed to an active-looking box whose taps are
  /// swallowed, which reads as a broken checkbox.
  const AppCheckbox.disabled({super.key, required this.value})
    : onChanged = null;

  final bool value;

  /// Null when disabled, so the underlying control greys itself out.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return switch (context.style) {
      PlatformStyle.material => Checkbox(
        value: value,
        onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
      ),
      PlatformStyle.cupertino => CupertinoCheckbox(
        value: value,
        onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
      ),
      PlatformStyle.fluent => fui.Checkbox(
        checked: value,
        onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
      ),
      // Adwaita's checkbox is a rounded square that fills with the accent, so
      // Material's own is already the right shape.
      PlatformStyle.gtk => Checkbox(
        value: value,
        onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
      ),
    };
  }
}

/// A read-only label, in the family the OS asked for.
///
/// Not tappable, and not a choice: this is the "1080p · 3:24 · uploader" pill
/// the playlist card shows. Material has `Chip` for it, and neither of the
/// other families has anything at all — so this draws the pill each family
/// uses for static text.
class AppLabelChip extends StatelessWidget {
  const AppLabelChip({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles.labelMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return switch (context.style) {
      PlatformStyle.material => Chip(
        label: Text(label, style: text),
        avatar: icon == null ? null : Icon(icon, size: 16),
        visualDensity: VisualDensity.compact,
      ),
      PlatformStyle.cupertino => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: colors.onSurfaceVariant),
              const SizedBox(width: 4),
            ],
            Text(label, style: text),
          ],
        ),
      ),
      PlatformStyle.fluent => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: colors.onSurfaceVariant),
              const SizedBox(width: 6),
            ],
            Text(label, style: text),
          ],
        ),
      ),
      // GTK4 has no chip. What it has for a non-interactive tag is a pill on
      // the neutral fill — which is the same shape, minus the tap.
      PlatformStyle.gtk => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: colors.onSurfaceVariant),
              const SizedBox(width: 6),
            ],
            Text(label, style: text),
          ],
        ),
      ),
    };
  }
}

/// A selectable, multi-choice pill, in the family the OS asked for.
///
/// The language chips in the format sheet are the only multi-select pills the
/// app has: several languages can be on at once, and deselecting must work, so
/// this is a `FilterChip` under Material rather than the single-choice
/// [AppChoiceChip]. The other two families have neither chip, and get a toggle
/// that stays lit while selected — the same on/off reading a checkbox has.
class AppFilterChip extends StatelessWidget {
  const AppFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles.labelLarge?.copyWith(
      color: selected ? colors.onPrimary : colors.onSurface,
    );
    return switch (context.style) {
      PlatformStyle.material => FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
        visualDensity: VisualDensity.compact,
      ),
      PlatformStyle.cupertino => GestureDetector(
        onTap: () => onSelected(!selected),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? colors.primary : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            border: selected ? null : Border.all(color: colors.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check, size: 14, color: colors.onPrimary),
                const SizedBox(width: 4),
              ],
              Text(label, style: text),
            ],
          ),
        ),
      ),
      PlatformStyle.fluent => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: fui.ToggleButton(
          checked: selected,
          onChanged: onSelected,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(label),
          ),
        ),
      ),
      // The same pill, but a toggle: selected fills with the accent, the way
      // GTK's toggle button does.
      PlatformStyle.gtk => GtkPill(
        selected: selected,
        onTap: () => onSelected(!selected),
        showCheck: true,
        child: Text(label),
      ),
    };
  }
}

/// A row that leads with a checkbox, in the family the OS asked for.
///
/// The playlist picker's entry list. Material's `CheckboxListTile` is one
/// widget; the other two families have no such row, so this builds one around
/// the family's own checkbox.
class AppCheckboxTile extends StatelessWidget {
  const AppCheckboxTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.trailing,
    this.dense = false,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    if (context.style == PlatformStyle.material) {
      return CheckboxListTile(
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        dense: dense,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: title,
        subtitle: subtitle,
        secondary: trailing,
      );
    }
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AppCheckbox(value: value, onChanged: onChanged),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DefaultTextStyle.merge(
                style: text.bodyMedium ?? const TextStyle(),
                child: title,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                DefaultTextStyle.merge(
                  style: text.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  child: subtitle!,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
    // A gesture rather than an InkWell: the Material ripple needs a Material
    // ancestor, and neither the Cupertino nor the Fluent root provides one.
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 4 : 8),
        child: row,
      ),
    );
  }
}

/// A choose-one drop-down, in the family the OS asked for.
///
/// Material's `DropdownButtonFormField`, a wheel in a sheet on iOS, and a
/// Fluent `ComboBox`. The three settings screens feed this the same shape — an
/// option's value, its label, and occasionally a line of helper text.
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.helper,
    this.enabled = true,
  });

  final T? value;
  final List<({T? value, String label})> items;
  final ValueChanged<T?> onChanged;
  final String? label;
  final String? helper;

  /// When false the control reads the current value but cannot be changed.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return switch (context.style) {
      PlatformStyle.material => DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final item in items)
            DropdownMenuItem<T>(value: item.value, child: Text(item.label)),
        ],
        onChanged: enabled ? onChanged : null,
      ),
      PlatformStyle.cupertino => _CupertinoDropdown<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        label: label,
        helper: helper,
        enabled: enabled,
      ),
      PlatformStyle.fluent => _FluentDropdown<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        label: label,
        helper: helper,
        enabled: enabled,
      ),
      PlatformStyle.gtk => GtkDropdown<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        label: label,
        helper: helper,
        enabled: enabled,
      ),
    };
  }
}

/// The iOS answer: a tappable row that lifts a wheel off the bottom.
class _CupertinoDropdown<T> extends StatelessWidget {
  const _CupertinoDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.helper,
    this.enabled = true,
  });

  final T? value;
  final List<({T? value, String label})> items;
  final ValueChanged<T?> onChanged;
  final String? label;
  final String? helper;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final current = _labelFor(items, value);
    final children = [
      if (label != null)
        Text(
          label!,
          style: text.labelMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      const SizedBox(height: 6),
      GestureDetector(
        onTap: enabled ? () => _openWheel(context) : null,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  current,
                  style: text.bodyLarge?.copyWith(
                    color: enabled
                        ? colors.onSurface
                        : colors.onSurface.withValues(alpha: 0.38),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.arrow_drop_down, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
      if (helper != null) ...[
        const SizedBox(height: 4),
        Text(
          helper!,
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Future<void> _openWheel(BuildContext context) async {
    final initial = items.indexWhere((i) => i.value == value);
    await showAppBottomSheet<void>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: CupertinoPicker(
              scrollController: initial > 0
                  ? FixedExtentScrollController(initialItem: initial)
                  : null,
              itemExtent: 40,
              onSelectedItemChanged: (i) => onChanged(items[i].value),
              children: [
                for (final item in items) Center(child: Text(item.label)),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: AppButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icons.check,
              label: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Fluent answer.
class _FluentDropdown<T> extends StatelessWidget {
  const _FluentDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.helper,
    this.enabled = true,
  });

  final T? value;
  final List<({T? value, String label})> items;
  final ValueChanged<T?> onChanged;
  final String? label;
  final String? helper;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final text = context.textStyles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: text.labelMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
        ],
        fui.ComboBox<T>(
          value: value,
          isExpanded: true,
          placeholder: enabled ? null : Text(currentLabel()),
          items: [
            for (final item in items)
              fui.ComboBoxItem(value: item.value, child: Text(item.label)),
          ],
          // A null `onChanged` is Fluent's disabled combo box.
          onChanged: enabled ? onChanged : null,
        ),
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(
            helper!,
            style: text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  String currentLabel() => _labelFor(items, value);
}

/// The label of the option matching [value], or an empty string.
String _labelFor<T>(List<({T? value, String label})> items, T? value) {
  for (final item in items) {
    if (item.value == value) return item.label;
  }
  return '';
}

/// The strip that switches between the tabs of a carousel.
///
/// Material's `TabBar` is a row of labels with an underline. The other two
/// families put its equivalent in the segmented-control family: iOS' sliding
/// control, Windows' toggle-button row. Both are the "which of these is up"
/// control their OS uses, and both read the same [TabController] the Material
/// one is driven by, so a swipe moves either strip exactly as it moved the
/// Material one.
class AppTabStrip extends StatelessWidget {
  const AppTabStrip({
    super.key,
    required this.tabs,
    required this.tabController,
    required this.onTap,
  });

  /// The tab labels, in order.
  final List<String> tabs;

  /// Owned by the caller: the Material strip and the carousel both hang off
  /// it, and the other two families read its index instead.
  final TabController tabController;

  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final tabBar = TabBar(
      controller: tabController,
      tabs: [for (final t in tabs) Tab(text: t)],
      onTap: onTap,
    );
    if (context.style == PlatformStyle.material) return tabBar;
    // AnimatedBuilder rather than a re-read per tap: the index moves on its
    // own when a swipe drives the carousel.
    return AnimatedBuilder(
      animation: tabController,
      builder: (context, _) => switch (context.style) {
        PlatformStyle.gtk => GtkTabStrip(
          tabs: tabs,
          index: tabController.index,
          onTap: onTap,
        ),
        PlatformStyle.cupertino => CupertinoSlidingSegmentedControl<int>(
          groupValue: tabController.index,
          onValueChanged: (v) {
            if (v != null) onTap(v);
          },
          children: {
            for (var i = 0; i < tabs.length; i++)
              i: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(tabs[i]),
              ),
          },
        ),
        PlatformStyle.fluent => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < tabs.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: fui.ToggleButton(
                  checked: tabController.index == i,
                  onChanged: (_) => onTap(i),
                  child: Text(tabs[i]),
                ),
              ),
          ],
        ),
        PlatformStyle.material => tabBar,
      },
    );
  }
}

/// A dense labelled text field, the one every free-text setting uses.
class AppPrefField extends StatelessWidget {
  const AppPrefField({
    super.key,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        initialValue: value,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

/// A whole-number text field, for the few values that have no sensible slider.
class AppPrefIntField extends StatelessWidget {
  const AppPrefIntField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        initialValue: '$value',
        keyboardType: TextInputType.number,
        // Non-digits never reach the field: an unparseable value used to be
        // *silently refused at the settings layer*, so a stray letter could sit
        // in the box next to a setting that was still using the old number — no
        // cue that the edit did not land.
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        // An unparseable value — a cleared field, mostly — falls back to the
        // current value rather than 0, so deleting the contents to retype does
        // not momentarily write a zero into the settings.
        onChanged: (v) {
          final parsed = int.tryParse(v.trim());
          if (parsed != null) onChanged(parsed);
        },
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

/// A chip row picking one of a fixed set of values.
class AppPrefChips extends StatelessWidget {
  const AppPrefChips({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: context.textStyles.bodySmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final o in options)
                AppChoiceChip(
                  label: o.toUpperCase(),
                  selected: selected == o,
                  onSelected: (_) => onChanged(o),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A slider whose current value is named in a label above it.
class AppPrefSlider extends StatelessWidget {
  const AppPrefSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.helper,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final String helper;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: $value', style: context.textStyles.bodyMedium),
        AppSlider(
          value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          onChanged: (v) => onChanged(v.round()),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            helper,
            style: context.textStyles.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _SegmentedLabel extends StatelessWidget {
  const _SegmentedLabel({
    required this.label,
    required this.icon,
    this.enabled = true,
  });

  final String label;
  final IconData? icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: enabled
                    ? colors.onSurface
                    : colors.onSurface.withValues(alpha: 0.38),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
