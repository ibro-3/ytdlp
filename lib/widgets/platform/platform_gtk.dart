library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/app_theme_context.dart';

/// The GTK4 / Adwaita widgets the platform layer draws.
///
/// A file of their own because the other wrappers reference several of these,
/// and Dart's privacy is per library: they have to be public to be shared, and
/// naming them `Gtk…` keeps that honest.
///
/// Every one of them is built from Material widgets plus Adwaita's own metrics
/// and greys, because the pub `libadwaita` package pins `package_info_plus` and
/// `flutter_svg` to versions this app cannot use. What is here is the family's
/// shapes — the sliding switch, the pill, the popover, the bordered expander —
/// not a retint of Material's.
///
/// Not exported from `platform.dart`: these are the pieces the family is built
/// from, not the API a screen uses.
class GtkPill extends StatefulWidget {
  const GtkPill({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.showCheck = false,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  /// Whether a selected pill shows a check before its label.
  final bool showCheck;

  @override
  State<GtkPill> createState() => _GtkPillState();
}

class _GtkPillState extends State<GtkPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: AppTheme.gtkControlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.primary
                : _hovered
                ? colors.surfaceContainerHighest
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: widget.selected ? colors.primary : colors.outline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.selected && widget.showCheck) ...[
                Icon(Icons.check, size: 14, color: colors.onPrimary),
                const SizedBox(width: 6),
              ],
              DefaultTextStyle.merge(
                style: TextStyle(
                  fontSize: 13,
                  color: widget.selected ? colors.onPrimary : colors.onSurface,
                ),
                child: widget.child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GtkSwitch extends StatelessWidget {
  const GtkSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = AppTheme.gtkSwitchSize;
    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: size.width,
          height: size.height,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? colors.primary : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(size.height / 2),
            border: value ? null : Border.all(color: colors.outline),
          ),
          child: Align(
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: size.height - 10,
              height: size.height - 10,
              decoration: BoxDecoration(
                color: value ? colors.onPrimary : colors.onSurfaceVariant,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GtkListRow extends StatefulWidget {
  const GtkListRow({
    super.key,
    required this.dense,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });

  final bool dense;
  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  State<GtkListRow> createState() => _GtkListRowState();
}

class _GtkListRowState extends State<GtkListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: widget.dense ? 8 : 12,
          ),
          decoration: BoxDecoration(
            color: _hovered && widget.onTap != null
                ? colors.surfaceContainerHighest
                : Colors.transparent,
          ),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle.merge(
                      style: text.bodyMedium ?? const TextStyle(),
                      child: widget.title,
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      DefaultTextStyle.merge(
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        child: widget.subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 12),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class GtkExpander extends StatefulWidget {
  const GtkExpander({super.key, required this.title, required this.child});

  final Widget title;
  final Widget child;

  @override
  State<GtkExpander> createState() => _GtkExpanderState();
}

class _GtkExpanderState extends State<GtkExpander> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppTheme.gtkSurfaceRadius),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Container(
              height: AppTheme.gtkControlHeight,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(child: widget.title),
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: const Icon(Icons.expand_more, size: 20),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

class GtkSegmentedItem<T extends Object> extends StatelessWidget {
  const GtkSegmentedItem({
    super.key,
    required this.segment,
    required this.selected,
    required this.first,
    required this.last,
    required this.onTap,
  });

  final ({T value, String label, IconData? icon, bool enabled}) segment;
  final bool selected;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = selected ? colors.onPrimary : colors.onSurface;
    return GestureDetector(
      onTap: segment.enabled ? onTap : null,
      child: Container(
        height: AppTheme.gtkControlHeight,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? colors.primary : Colors.transparent,
          borderRadius: BorderRadius.horizontal(
            left: first
                ? const Radius.circular(AppTheme.gtkRadius)
                : Radius.zero,
            right: last
                ? const Radius.circular(AppTheme.gtkRadius)
                : Radius.zero,
          ),
        ),
        child: Opacity(
          opacity: segment.enabled ? 1 : 0.38,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(segment.icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                segment.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : null,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GtkTabStrip extends StatelessWidget {
  const GtkTabStrip({
    super.key,
    required this.tabs,
    required this.index,
    required this.onTap,
  });

  final List<String> tabs;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tabs.length; i++)
          InkWell(
            onTap: () => onTap(i),
            child: Container(
              height: AppTheme.gtkControlHeight,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: i == index ? colors.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Center(
                child: Text(
                  tabs[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: i == index ? FontWeight.w600 : null,
                    color: i == index
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class GtkDropdown<T> extends StatefulWidget {
  const GtkDropdown({
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
  final bool enabled;

  @override
  State<GtkDropdown<T>> createState() => _GtkDropdownState<T>();
}

class _GtkDropdownState<T> extends State<GtkDropdown<T>> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _close() {
    _entry?.remove();
    _entry = null;
  }

  void _open() {
    if (_entry != null || !widget.enabled) return;
    final colors = context.colors;
    final text = context.textStyles;
    _entry = OverlayEntry(
      builder: (context) => Positioned(
        top: 0,
        left: 0,
        child: CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Material(
                elevation: 8,
                color: colors.surfaceContainerLowest,
                shadowColor: Colors.black.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    AppTheme.gtkSurfaceRadius,
                  ),
                  side: BorderSide(color: colors.outline),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 200,
                    maxHeight: 320,
                  ),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    shrinkWrap: true,
                    children: [
                      for (final item in widget.items)
                        GtkMenuRow(
                          label: item.label,
                          selected: item.value == widget.value,
                          foreground: colors.onSurface,
                          textStyle: text.bodyMedium,
                          highlight: colors.surfaceContainerHighest,
                          onTap: () {
                            _close();
                            widget.onChanged(item.value);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    final selected = labelFor(widget.items, widget.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: text.labelMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        CompositedTransformTarget(
          link: _link,
          child: MouseRegion(
            cursor: widget.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              onTap: widget.enabled ? _open : null,
              child: Container(
                height: AppTheme.gtkControlHeight,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
                  border: Border.all(color: colors.outline),
                ),
                child: Opacity(
                  opacity: widget.enabled ? 1 : 0.38,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          selected,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.arrow_drop_down, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.helper != null) ...[
          const SizedBox(height: 4),
          Text(
            widget.helper!,
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class GtkMenuRow extends StatelessWidget {
  const GtkMenuRow({
    super.key,
    required this.label,
    required this.selected,
    required this.foreground,
    required this.textStyle,
    required this.highlight,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color foreground;
  final TextStyle? textStyle;
  final Color highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      hoverColor: highlight,
      child: Container(
        height: AppTheme.gtkControlHeight,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: (textStyle ?? const TextStyle()).copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 16, color: colors.primary),
          ],
        ),
      ),
    );
  }
}

class GtkIconButton extends StatefulWidget {
  const GtkIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  State<GtkIconButton> createState() => _GtkIconButtonState();
}

class _GtkIconButtonState extends State<GtkIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onPressed == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: AppTheme.gtkControlHeight,
          height: AppTheme.gtkControlHeight,
          decoration: BoxDecoration(
            color: _hovered
                ? colors.surfaceContainerHighest
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
          ),
          child: Icon(
            widget.icon,
            size: 18,
            color: colors.onSurface.withValues(
              alpha: widget.onPressed == null ? 0.38 : 1,
            ),
          ),
        ),
      ),
    );
    if (widget.tooltip == null) return button;
    return Tooltip(message: widget.tooltip!, child: button);
  }
}

class GtkFab extends StatelessWidget {
  const GtkFab({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(AppTheme.gtkRadius * 2),
          ),
          child: Icon(icon, color: colors.onPrimary, size: 20),
        ),
      ),
    );
  }
}

/// The label of the option matching [value], or an empty string.
String labelFor<T>(List<({T? value, String label})> items, T? value) {
  for (final item in items) {
    if (item.value == value) return item.label;
  }
  return '';
}
