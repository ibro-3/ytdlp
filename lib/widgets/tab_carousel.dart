import 'package:flutter/material.dart';

/// Gives a [PageView] the height of its tallest page.
///
/// A `PageView` is unbounded vertically unless told otherwise, and a carousel
/// whose pages differ in height has no single right answer: a fixed height
/// either clips the tall page or leaves a gap under the short one. So the pages
/// are laid out for real, and the tallest measurement seen so far is used.
///
/// Deliberately not a `LayoutBuilder`: that only reports the space *available*,
/// not how tall the child *wants* to be, which is the number that matters here.
///
/// The measurement rides on the *real* pages rather than on a hidden copy. A
/// copy would be simpler to lay out, but it would double the page subtree —
/// including any stateful widgets inside it, and duplicate nodes a screen reader
/// would read twice. Instead each page is wrapped in a scroll view whose child
/// is unbounded, so the child's laid-out size is its natural height.
///
/// A page that has not been shown yet is not measured, so the height is the
/// tallest page *visited*. That degrades to a small jump rather than a clipped
/// page, which is the failure that actually loses content.
class TabCarousel extends StatefulWidget {
  const TabCarousel({
    required this.pages,
    required this.controller,
    required this.onPageChanged,
    required this.fallbackHeight,
    this.maxHeight,
    super.key,
  });

  /// One entry per page, in order.
  final List<Widget> pages;

  final PageController controller;

  /// Reports which page is up, so a tab strip can follow a swipe.
  final ValueChanged<int> onPageChanged;

  /// Used until a page has been measured, so the first frame is not a
  /// zero-height box that then jumps.
  final double fallbackHeight;

  /// Caps the height, so a carousel inside a bounded parent (a bottom sheet,
  /// say) cannot ask for more room than exists. Each page scrolls itself, so
  /// the cap costs a scroll rather than clipping content.
  final double? maxHeight;

  @override
  State<TabCarousel> createState() => _TabCarouselState();
}

class _TabCarouselState extends State<TabCarousel> {
  /// Natural height per page, from the pages that have been laid out.
  final Map<int, double> _heights = {};

  @override
  Widget build(BuildContext context) {
    var tallest = 0.0;
    for (final h in _heights.values) {
      if (h > tallest) tallest = h;
    }
    final height = tallest > 0 ? tallest : widget.fallbackHeight;
    final cap = widget.maxHeight;

    return SizedBox(
      height: cap == null ? height : height.clamp(0, cap),
      child: PageView(
        controller: widget.controller,
        // A swipe moves the tab highlight, so the strip always shows which page
        // is up. Swiping stays enabled because on a phone it is the natural
        // gesture, and the strip is the discoverable fallback.
        onPageChanged: widget.onPageChanged,
        children: [
          for (var i = 0; i < widget.pages.length; i++)
            // Each page scrolls itself rather than dragging the whole enclosing
            // list, which is what makes a fixed-height carousel usable inside a
            // scrolling page. The child is unbounded here, so its laid-out
            // height is the content's real height.
            SingleChildScrollView(
              child: MeasuredHeight(
                onHeight: (h) {
                  if (h <= 0 || !h.isFinite) return;
                  final known = _heights[i];
                  // Sub-pixel changes are layout noise, not content.
                  if (known != null && (known - h).abs() < 0.5) return;
                  if (!mounted) return;
                  setState(() => _heights[i] = h);
                },
                child: widget.pages[i],
              ),
            ),
        ],
      ),
    );
  }
}

/// Reports its child's laid-out height after each frame.
///
/// A post-frame callback rather than a build-time read, because a size is only
/// known after layout, and calling back during build would set state in the
/// middle of a build.
class MeasuredHeight extends StatefulWidget {
  const MeasuredHeight({required this.child, required this.onHeight, super.key});

  final Widget child;
  final ValueChanged<double> onHeight;

  @override
  State<MeasuredHeight> createState() => _MeasuredHeightState();
}

class _MeasuredHeightState extends State<MeasuredHeight> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final h = context.size?.height ?? 0;
      if (h > 0) widget.onHeight(h);
    });
    return widget.child;
  }
}
