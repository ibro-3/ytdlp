// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ytdlp/main.dart' as app;

/// Waits for [finder] (or [orElse]) to appear, printing a heartbeat so a CI
/// run that hangs is still diagnosable.
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(minutes: 3),
  Finder? orElse,
}) async {
  final end = DateTime.now().add(timeout);
  var lastBeat = DateTime.now();
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 2));
    if (finder.evaluate().isNotEmpty) return;
    if (orElse != null && orElse.evaluate().isNotEmpty) return;
    if (DateTime.now().difference(lastBeat).inSeconds >= 30) {
      lastBeat = DateTime.now();
      print(
        'HEARTBEAT loading=${find.byType(LinearProgressIndicator).evaluate().isNotEmpty} '
        'error=${find.text("Couldn't fetch video").evaluate().isNotEmpty} '
        'downloadBtn=${find.widgetWithText(FilledButton, 'Download').evaluate().isNotEmpty} '
        'm4a=${find.textContaining('M4A').evaluate().isNotEmpty} '
        'best=${find.textContaining('Best quality').evaluate().isNotEmpty} '
        'chips=${find.byType(ChoiceChip).evaluate().length} '
        'noVideoHint=${find.textContaining('No downloadable video streams').evaluate().isNotEmpty}',
      );
    }
  }
  fail('Timed out waiting for $finder');
}

String _errorText(WidgetTester tester) {
  final found = find.byType(SelectableText).evaluate();
  if (found.isEmpty) return '<no error text>';
  return (found.first.widget as SelectableText).data ?? '<empty>';
}

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
    await _waitFor(
      tester,
      find.widgetWithText(FilledButton, 'Download'),
      timeout: const Duration(minutes: 6),
      orElse: find.text("Couldn't fetch video"),
    );
    if (find.text("Couldn't fetch video").evaluate().isNotEmpty) {
      fail("fetch failed on device: ${_errorText(tester)}");
    }

    // Open the bottom-sheet format picker.
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The sheet is titled with the video's title and holds the format chips.
    await _waitFor(
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

    await _waitFor(
      tester,
      find.text('Added to the download queue'),
      timeout: const Duration(seconds: 30),
    );

    // The download runs on-device via the bundled runtime — wait for it in
    // the Queue tab. No pumpAndSettle: live progress never quiesces.
    await tester.tap(find.byTooltip('Queue'));
    await tester.pump(const Duration(seconds: 2));
    await _waitFor(
      tester,
      find.text('Completed'),
      timeout: const Duration(minutes: 6),
    );
  });
}
