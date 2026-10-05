// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ytdlp/main.dart' as app;

import 'support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fetch shows the format sheet and enqueues a download', (
    tester,
  ) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    await tester.enterText(
      find.byType(SearchBar),
      'https://www.youtube.com/watch?v=jNQXAC9IVRw',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Fetch details'));

    // The page shows the video card plus a single Download button. Devices
    // without ffmpeg only get audio rows (no merged video), so accept either.
    await waitFor(
      tester,
      find.widgetWithText(FilledButton, 'Download'),
      timeout: const Duration(minutes: 6),
      orElse: find.text("Couldn't fetch video"),
    );
    if (find.text("Couldn't fetch video").evaluate().isNotEmpty) {
      fail("fetch failed on device: ${errorText(tester)}");
    }

    // Open the bottom-sheet format picker.
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The sheet is titled with the video's title and holds the format chips.
    await waitFor(
      tester,
      find.textContaining('Best quality'),
      timeout: const Duration(minutes: 1),
      orElse: find.textContaining('M4A'),
    );
    expect(find.byType(ChoiceChip), findsWidgets);

    // Pick the first available quality, then confirm in the sheet.
    await tester.tap(find.byType(ChoiceChip).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pump();

    await waitFor(
      tester,
      find.text('Added to the download queue'),
      timeout: const Duration(seconds: 30),
    );

    // The download runs on-device via the bundled runtime — wait for it in
    // the Queue tab. No pumpAndSettle: live progress never quiesces.
    await tester.tap(find.byTooltip('Queue'));
    await tester.pump(const Duration(seconds: 2));
    await waitFor(
      tester,
      find.text('Completed'),
      timeout: const Duration(minutes: 6),
    );
  });
}
