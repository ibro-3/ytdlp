import 'package:material_ui/material_ui.dart';

/// GTK-only: the shell's header bar shows the screen's title, so screens tell
/// the shell what that title is rather than drawing a bar of their own.
///
/// A [String], not a widget, so equality comparison is exact: the screen
/// publishes on every build, and the shell only repaints when the words
/// actually change. Actions are not pushed upward — the screen renders them
/// itself, in a slim row under the header.
class GtkHeaderController extends ChangeNotifier {
  String? title;

  void update(String? title) {
    if (title == this.title) return;
    this.title = title;
    notifyListeners();
  }
}

/// Publishes the controller to the screens below the shell's header.
class GtkHeaderScope extends InheritedWidget {
  const GtkHeaderScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final GtkHeaderController controller;

  /// Null when a screen is pumped without the GTK shell (tests, previews).
  static GtkHeaderController? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<GtkHeaderScope>()?.controller;

  @override
  bool updateShouldNotify(GtkHeaderScope oldWidget) =>
      controller != oldWidget.controller;
}
