import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/widgets/platform/platform_gtk.dart';

/// GTK is a desktop platform: its controls are operable from the keyboard,
/// not only by pointer. These tests walk each interactive control through
/// Tab-free activation on Enter and Space.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Future<void> focus(WidgetTester tester, Finder within) async {
    final focusFinder = find.descendant(
      of: within,
      matching: find.byType(Focus),
    );
    final focus = tester.widget<Focus>(focusFinder.first);
    focus.focusNode?.requestFocus();
    await tester.pump();
  }

  testWidgets('GtkPill activates on tap, Enter and Space', (tester) async {
    var taps = 0;
    await pump(
      tester,
      GtkPill(selected: false, onTap: () => taps++, child: const Text('Pill')),
    );
    await tester.tap(find.byType(GtkPill));
    expect(taps, 1);

    await focus(tester, find.byType(GtkPill));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 3);
  });

  testWidgets('GtkSwitch toggles on Space and Enter', (tester) async {
    var value = false;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => GtkSwitch(
          value: value,
          onChanged: (v) => setState(() => value = v),
          label: 'Hold downloads',
        ),
      ),
    );
    await focus(tester, find.byType(GtkSwitch));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(value, isFalse);
  });

  testWidgets('GtkIconButton activates on Enter', (tester) async {
    var pressed = 0;
    await pump(
      tester,
      GtkIconButton(
        icon: Icons.close,
        onPressed: () => pressed++,
        tooltip: 'Dismiss',
      ),
    );
    await focus(tester, find.byType(GtkIconButton));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(pressed, 1);
  });

  testWidgets('GtkFab activates on Space', (tester) async {
    var pressed = 0;
    await pump(
      tester,
      GtkFab(
        onPressed: () => pressed++,
        icon: Icons.download,
        tooltip: 'Download',
      ),
    );
    await focus(tester, find.byType(GtkFab));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(pressed, 1);
  });

  testWidgets('GtkListRow activates on Enter', (tester) async {
    var opened = 0;
    await pump(
      tester,
      GtkListRow(
        dense: false,
        leading: null,
        title: const Text('Row'),
        subtitle: null,
        trailing: null,
        onTap: () => opened++,
      ),
    );
    await focus(tester, find.byType(GtkListRow));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, 1);
  });

  testWidgets('GtkSegmentedItem selects on Enter', (tester) async {
    var picked = '';
    const segments = [
      (value: 'a', label: 'Audio', icon: null, enabled: true),
      (value: 'v', label: 'Video', icon: null, enabled: true),
    ];
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < segments.length; i++)
              GtkSegmentedItem<String>(
                segment: segments[i],
                selected: picked == segments[i].value,
                first: i == 0,
                last: i == segments.length - 1,
                onTap: () => setState(() => picked = segments[i].value),
              ),
          ],
        ),
      ),
    );
    await focus(tester, find.byType(GtkSegmentedItem<String>).last);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, 'v');
  });

  testWidgets('GtkDropdown opens its menu on Enter', (tester) async {
    String? picked;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => GtkDropdown<String>(
          value: 'one',
          items: const [
            (value: 'one', label: 'One'),
            (value: 'two', label: 'Two'),
          ],
          onChanged: (v) => setState(() => picked = v),
          label: 'Pick',
        ),
      ),
    );
    await focus(tester, find.byType(GtkDropdown<String>));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(GtkMenuRow), findsWidgets);

    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(picked, 'two');
  });

  testWidgets('a disabled GtkIconButton does not take focus or activate', (
    tester,
  ) async {
    await pump(tester, const GtkIconButton(icon: Icons.close, onPressed: null));
    final focusFinder = find.descendant(
      of: find.byType(GtkIconButton),
      matching: find.byType(Focus),
    );
    final focus = tester.widget<Focus>(focusFinder.first);
    expect(focus.canRequestFocus, isFalse);
  });
}
