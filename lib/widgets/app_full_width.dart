import 'package:flutter/material.dart';

/// Makes a page's body as wide as the window it is in.
///
/// The pages used to wrap their scroll view in `Center` +
/// `ConstrainedBox(maxWidth: 760)`. That reads well on a phone, where the
/// window is itself the cap, and it is a trap on a desktop: the scroll view
/// then only exists *inside* that capped column, so the mouse wheel does
/// nothing over the rest of the window and a scrollbar sits in the middle of
/// the screen instead of at its edge. A desktop window is scrolled by pointing
/// anywhere at it, so the body now spans the window and the wheel works
/// everywhere.
///
/// The child is given the incoming width as a *minimum*, not a cap, so a
/// scroll view inside it still decides its own height and scrolls. Without
/// something forcing the width, a child under a loose parent (a `Center`, an
/// `Align`) would shrink-wrap and stop filling the window.
class AppFullWidth extends StatelessWidget {
  const AppFullWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Nothing to fill if the parent is already tight or unbounded
        // horizontally: the child has no narrower choice to make.
        if (!width.isFinite || width <= constraints.minWidth) return child;
        return ConstrainedBox(
          constraints: BoxConstraints(minWidth: width),
          child: child,
        );
      },
    );
  }
}
