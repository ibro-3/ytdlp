import 'package:flutter/cupertino.dart';
import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/material.dart';

import '../../core/platform_style.dart';
import '../../core/theme/app_theme.dart';
import 'platform_gtk.dart';
import '../../core/theme/app_theme_context.dart';

/// A confirmation dialog, in the family the OS asked for.
///
/// Returns whether the user confirmed. The three are not the same control with
/// different paint: Material centres a card over a scrim, Cupertino centres a
/// bubble sheet, and Fluent slides a content dialog up from the middle. Each is
/// what users of that OS expect when asked to confirm something destructive.
Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final confirmed = await switch (context.style) {
    PlatformStyle.material => showDialog<bool>(
      context: context,
      builder: (context) {
        final colors = context.colors;
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(cancelLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: colors.error)
                  : null,
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    ),
    PlatformStyle.cupertino => showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: destructive,
            isDefaultAction: !destructive,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
    PlatformStyle.fluent => fui.showDialog<bool>(
      context: context,
      builder: (context) => fui.ContentDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          fui.Button(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel),
          ),
          fui.FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
    // An Adwaita dialog: a rounded box with a title strip along the top, the
    // message under it, and the buttons in a row along the bottom with the
    // suggested action last — which is the opposite of Material's order.
    PlatformStyle.gtk => showDialog<bool>(
      context: context,
      builder: (context) => _GtkDialog(
        title: title,
        message: message,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        destructive: destructive,
      ),
    ),
  };
  // Dismissed rather than answered — the barrier tap — is a "no".
  return confirmed ?? false;
}

/// A choice of actions for a single row, in the family the OS asked for.
///
/// One item per [AppAction].
Future<void> showAppActionSheet({
  required BuildContext context,
  required List<AppAction> actions,
  String? title,
  String? message,
}) {
  if (actions.isEmpty) return Future.value();
  return switch (context.style) {
    PlatformStyle.material => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              ListTile(
                leading: action.icon == null
                    ? null
                    : Icon(
                        action.icon,
                        color: action.destructive ? _error(context) : null,
                      ),
                title: Text(
                  action.label,
                  style: TextStyle(
                    color: action.destructive ? _error(context) : null,
                  ),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  action.onPressed();
                },
              ),
          ],
        ),
      ),
    ),
    PlatformStyle.cupertino => showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final action in actions)
            CupertinoActionSheetAction(
              isDestructiveAction: action.destructive,
              onPressed: () {
                Navigator.of(context).pop();
                action.onPressed();
              },
              child: Text(action.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ),
    ),
    PlatformStyle.fluent => fui.showDialog<void>(
      context: context,
      builder: (context) => fui.ContentDialog(
        // Fluent's `ContentDialog` takes nullable title/content, but not the
        // "omit the row" shape Material and Cupertino do — so an absent title
        // collapses to an empty row rather than disappearing.
        title: Text(title ?? ''),
        content: message == null ? null : Text(message),
        actions: [
          for (final action in actions)
            fui.Button(
              onPressed: () {
                Navigator.of(context).pop();
                action.onPressed();
              },
              child: Text(action.label),
            ),
          fui.FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
    // GTK has no action sheet: what it has is a popover menu, so a choice of
    // actions for one row opens one of those.
    PlatformStyle.gtk => _showGtkMenu<void>(
      context: context,
      title: title,
      entries: [
        for (final action in actions)
          (label: action.label, onPressed: action.onPressed),
      ],
    ),
  };
}

/// One row in an [showAppActionSheet].
class AppAction {
  const AppAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool destructive;
}

/// A custom bottom sheet, in the family the OS asked for.
///
/// The Material sheet slides up with a rounded top and a drag handle; the
/// Cupertino one is a paged sheet with a grabber; the Fluent one is a dialog
/// that grows from the bottom of the window. The scrollable, tabbed picker that
/// uses this fits all three, so what changes is only the chrome around it.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext context) builder,
}) {
  return switch (context.style) {
    PlatformStyle.material => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: builder,
    ),
    PlatformStyle.cupertino => showCupertinoModalPopup<T>(
      context: context,
      builder: (context) => _CupertinoSheetBody(builder: builder),
    ),
    PlatformStyle.fluent => fui.showDialog<T>(
      context: context,
      builder: (context) => _FluentSheetBody(builder: builder),
    ),
    // GTK's sheet is a rounded surface attached to the bottom edge, with no
    // drag handle — it is dismissed by tapping outside or pressing Escape.
    PlatformStyle.gtk => showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.3),
      builder: (context) => Align(
        alignment: Alignment.bottomCenter,
        child: _GtkSheetBody(builder: builder),
      ),
    ),
  };
}

/// The grabber top and rounded corners of an iOS sheet.
class _CupertinoSheetBody extends StatelessWidget {
  const _CupertinoSheetBody({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
        margin: const EdgeInsets.only(top: 24),
        decoration: const BoxDecoration(
          color: Color(0xFFF2F2F7),
          borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 5,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Flexible(
              child: Material(
                type: MaterialType.transparency,
                child: builder(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Fluent sheet: a content dialog pinned to the bottom of the window.
class _FluentSheetBody extends StatelessWidget {
  const _FluentSheetBody({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
            child: fui.Card(
              padding: EdgeInsets.zero,
              borderRadius: BorderRadius.circular(8),
              child: Material(
                type: MaterialType.transparency,
                child: builder(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An overlay menu of choices, in the family the OS asked for.
///
/// The app's menus are all icon-triggered (copy, pause/cancel, filter), which
/// is why this is a button rather than a "show a menu at this position" call:
/// Material's popup takes a position, Cupertino's and Fluent's are anchored to
/// a target, so the anchor is the thing all three can express.
class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
  });

  final IconData icon;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return switch (context.style) {
      PlatformStyle.material => PopupMenuButton<T>(
        icon: Icon(icon),
        tooltip: tooltip,
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final item in items)
            PopupMenuItem<T>(
              value: item.value,
              child: _MenuItemLabel(item: item),
            ),
        ],
      ),
      PlatformStyle.cupertino => _CupertinoMenuButton<T>(
        icon: icon,
        items: items,
        onSelected: onSelected,
        tooltip: tooltip,
      ),
      PlatformStyle.fluent => _FluentMenuButton<T>(
        icon: icon,
        items: items,
        onSelected: onSelected,
        tooltip: tooltip,
      ),
      PlatformStyle.gtk => _GtkMenuButton<T>(
        icon: icon,
        items: items,
        onSelected: onSelected,
        tooltip: tooltip,
      ),
    };
  }
}

/// One row in an [AppMenuButton].
class AppMenuItem<T> {
  const AppMenuItem({required this.value, required this.label, this.checked});

  final T value;
  final String label;

  /// When set, the row shows a check on its leading edge (or the Fluent
  /// check glyph) instead of an icon.
  final bool? checked;
}

class _MenuItemLabel<T> extends StatelessWidget {
  const _MenuItemLabel({required this.item});

  final AppMenuItem<T> item;

  @override
  Widget build(BuildContext context) {
    return Text(
      item.label,
      style: TextStyle(
        color: item.checked == true ? context.colors.primary : null,
        fontWeight: item.checked == true ? FontWeight.w600 : null,
      ),
    );
  }
}

/// Cupertino's menu is the OS's own context menu, and it is a *pull-down*
/// rather than a popup: this anchors one to the button and adds the "checked"
/// mark by writing a check glyph into the label, because `CupertinoContextMenu`
/// is a long-press gesture that does not map onto a tap target.
class _CupertinoMenuButton<T> extends StatelessWidget {
  const _CupertinoMenuButton({
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
  });

  final IconData icon;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return CupertinoButton(
      padding: const EdgeInsets.all(12),
      minimumSize: const Size(44, 44),
      onPressed: () => showAppActionSheet(
        context: context,
        actions: [
          for (final item in items)
            AppAction(
              label: item.checked == true ? '✓  ${item.label}' : item.label,
              onPressed: () => onSelected(item.value),
            ),
        ],
      ),
      child: Icon(icon, size: 22, color: colors.primary),
    );
  }
}

/// Fluent's menu is a `MenuFlyout` shown from the anchor button. It is the one
/// family where the right control exists as-is, so this is a straight
/// `MenuFlyoutItem` per row.
class _FluentMenuButton<T> extends StatelessWidget {
  const _FluentMenuButton({
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
  });

  final IconData icon;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final controller = fui.FlyoutController();
    return fui.FlyoutTarget(
      controller: controller,
      child: fui.IconButton(
        icon: Icon(icon),
        onPressed: () => controller.showFlyout<void>(
          builder: (context) => fui.MenuFlyout(
            items: [
              for (final item in items)
                fui.MenuFlyoutItem(
                  text: Text(
                    item.checked == true ? '✓  ${item.label}' : item.label,
                  ),
                  onPressed: () {
                    controller.close();
                    onSelected(item.value);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An indeterminate spinner, in the family the OS asked for.
class AppCircularProgress extends StatelessWidget {
  const AppCircularProgress({super.key, this.strokeWidth});

  final double? strokeWidth;

  @override
  Widget build(BuildContext context) {
    return switch (context.style) {
      PlatformStyle.material => SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: strokeWidth ?? 2),
      ),
      PlatformStyle.cupertino => CupertinoActivityIndicator(
        radius: (strokeWidth ?? 9) + 1,
      ),
      // Fluent's ring is the only one with a determinate mode; the app's
      // spinner is always indeterminate, so the value stays null.
      PlatformStyle.fluent => SizedBox(
        width: 18,
        height: 18,
        child: fui.ProgressRing(strokeWidth: strokeWidth ?? 2),
      ),
      // GTK's spinner is the same idea as the others': a turning arc.
      PlatformStyle.gtk => SizedBox(
        width: AppTheme.gtkControlHeight,
        height: AppTheme.gtkControlHeight,
        child: CircularProgressIndicator(strokeWidth: strokeWidth ?? 2),
      ),
    };
  }
}

/// A progress bar, in the family the OS asked for.
class AppLinearProgress extends StatelessWidget {
  const AppLinearProgress({super.key, this.value, this.color});

  /// Null for the indeterminate case.
  final double? value;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final track = context.colors.surfaceContainerHighest;
    final fill = color ?? context.colors.primary;
    return switch (context.style) {
      PlatformStyle.material => ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: value,
          valueColor: AlwaysStoppedAnimation(fill),
          backgroundColor: track,
          minHeight: 6,
        ),
      ),
      PlatformStyle.cupertino => ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: _CupertinoBar(value: value, track: track, fill: fill),
      ),
      PlatformStyle.fluent => fui.ProgressBar(value: value),
      // GTK's bar is 4dp and its indeterminate state is a segment that
      // travels, not stripes that crawl.
      PlatformStyle.gtk => ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: value,
          minHeight: 4,
          backgroundColor: track,
          valueColor: AlwaysStoppedAnimation(fill),
        ),
      ),
    };
  }
}

/// Cupertino has no determinate bar — iOS uses a `UIProgressView` here, which
/// is exactly a rounded track with a fill, so this is that and nothing more.
class _CupertinoBar extends StatelessWidget {
  const _CupertinoBar({
    required this.value,
    required this.track,
    required this.fill,
  });

  final double? value;
  final Color track;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    final fraction = value?.clamp(0.0, 1.0);
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Container(
          height: 6,
          decoration: BoxDecoration(
            color: track,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        if (fraction != null)
          FractionallySizedBox(
            widthFactor: fraction,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              height: 6,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    );
  }
}

/// The theme's error colour, named once so the call sites read plainly.
Color _error(BuildContext context) => context.colors.error;

// --- GTK dialogs, sheets and menus ----------------------------------------

/// An Adwaita dialog.
///
/// GTK4's dialog is not a card over a scrim: it is a window with a title strip
/// along the top, the message under it, and a button row along the bottom whose
/// suggested action is on the *right* — the reverse of Material's order. A
/// destructive action is filled with the error colour rather than tinting its
/// label only.
class _GtkDialog extends StatelessWidget {
  const _GtkDialog({
    required this.title,
    required this.message,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.destructive,
  });

  final String title;
  final String message;
  final String cancelLabel;
  final String confirmLabel;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.gtkSurfaceRadius),
        side: BorderSide(color: colors.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, AppTheme.gtkControlHeight),
                    side: BorderSide(color: colors.outline),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
                    ),
                  ),
                  child: Text(cancelLabel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, AppTheme.gtkControlHeight),
                    backgroundColor: destructive ? colors.error : null,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.gtkRadius),
                    ),
                  ),
                  child: Text(confirmLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The rounded surface a GTK bottom sheet grows into: attached to the bottom
/// edge, no drag handle, dismissed by tapping outside or pressing Escape.
class _GtkSheetBody<T> extends StatelessWidget {
  const _GtkSheetBody({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(AppTheme.gtkSurfaceRadius),
          border: Border.all(color: colors.outline),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 24,
            ),
          ],
        ),
        // The picker that uses this scrolls itself, so the sheet must be able
        // to be as tall as the window allows.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: builder(context),
          ),
        ),
      ),
    );
  }
}

/// A GTK popover menu, anchored to its own trigger.
///
/// Material's popup and Fluent's `MenuFlyout` both anchor to the button; GTK's
/// does too, and the [AppMenuButton] wrapper gives it the trigger.
Future<T?> _showGtkMenu<T extends Object?>({
  required BuildContext context,
  String? title,
  List<({String label, VoidCallback onPressed})> entries = const [],
}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => _GtkMenuCard(title: title, entries: entries),
  );
}

/// The rounded, shadowed card the GTK menu opens as.
class _GtkMenuCard extends StatelessWidget {
  const _GtkMenuCard({required this.title, required this.entries});

  final String? title;
  final List<({String label, VoidCallback onPressed})> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.textStyles;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
        child: Material(
          color: colors.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.gtkSurfaceRadius),
            side: BorderSide(color: colors.outline),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      title!,
                      style: text.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final entry in entries)
                  GtkMenuRow(
                    label: entry.label,
                    selected: false,
                    foreground: colors.onSurface,
                    textStyle: text.bodyMedium,
                    highlight: colors.surfaceContainerHighest,
                    onTap: () {
                      Navigator.of(context).pop();
                      entry.onPressed();
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The GTK menu button, anchored like the other families' are.
class _GtkMenuButton<T> extends StatefulWidget {
  const _GtkMenuButton({
    required this.icon,
    required this.items,
    required this.onSelected,
    this.tooltip,
  });

  final IconData icon;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;

  @override
  State<_GtkMenuButton<T>> createState() => _GtkMenuButtonState<T>();
}

class _GtkMenuButtonState<T> extends State<_GtkMenuButton<T>> {
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
    if (_entry != null) return;
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(
      builder: (context) => Positioned(
        top: 0,
        right: 0,
        child: CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _GtkMenuCard(
                title: null,
                entries: [
                  for (final item in widget.items)
                    (
                      label: item.checked == true
                          ? '✓  ${item.label}'
                          : item.label,
                      onPressed: () => widget.onSelected(item.value),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: GtkIconButton(
        icon: widget.icon,
        tooltip: widget.tooltip,
        onPressed: _open,
      ),
    );
  }
}
