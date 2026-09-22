// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ytdlp/main.dart' as app;

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
        'selectFormat=${find.text('Select a format').evaluate().isNotEmpty} '
        'm4a=${find.textContaining('M4A').evaluate().isNotEmpty} '
        'best=${find.textContaining('Best quality').evaluate().isNotEmpty} '
        'dlVideo=${find.widgetWithText(FilledButton, 'Download video').evaluate().isNotEmpty} '
        'dlAudio=${find.widgetWithText(FilledButton, 'Download audio').evaluate().isNotEmpty} '
        'chips=${find.byType(ChoiceChip).evaluate().length} '
        'noVideoHint=${find.textContaining('No downloadable').evaluate().isNotEmpty}',
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

  testWidgets('fetch shows quality options and enqueues a download', (
    tester,
  ) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Enter the sample URL and fetch.
    await tester.enterText(
      find.byType(SearchBar),
      'https://www.youtube.com/watch?v=jNQXAC9IVRw',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Fetch details'));

    // Wait for the quality rows (the original bug: these never appeared),
    // or surface the fetch error if that's what happened instead.
    // Note: devices without ffmpeg only get audio rows (no merged video).
    await _waitFor(
      tester,
      find.textContaining('Best quality'),
      timeout: const Duration(minutes: 6),
      orElse: find.textContaining('M4A'),
    );
    if (find.text("Couldn't fetch video").evaluate().isNotEmpty) {
      fail("fetch failed on device: ${_errorText(tester)}");
    }
    final hasVideo = find.textContaining('Best quality').evaluate().isNotEmpty;
    // The post-frame auto-pick has settled by now (rows are rendered), so
    // the button label reflects the selection — but the button sits below
    // the fold in a lazy ListView and may not be built yet. Scroll it into
    // view (resolve label from what's actually selected on-device).
    await tester.scrollUntilVisible(
      hasVideo
          ? find.widgetWithText(FilledButton, 'Download video')
          : find.widgetWithText(FilledButton, 'Download audio'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible stops as soon as the widget is built (cacheExtent),
    // which can still be just off-screen — nudge it fully into the viewport.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -160));
    await tester.pump(const Duration(milliseconds: 400));

    final dlLabel =
        find
            .widgetWithText(FilledButton, 'Download video')
            .evaluate()
            .isNotEmpty
        ? 'Download video'
        : 'Download audio';
    expect(hasVideo, dlLabel == 'Download video');

    // Download button enabled → bottom-sheet picker (ask-each-time default).
    await tester.tap(find.widgetWithText(FilledButton, dlLabel));
    await tester.pumpAndSettle();
    expect(find.text('Choose quality'), findsOneWidget);

    // Confirm in the sheet → queued snackbar.
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pump();
    await _waitFor(
      tester,
      find.text('Added to the download queue'),
      timeout: const Duration(seconds: 30),
    );

    // The download itself runs on-device via the bundled runtime —
    // wait for it to finish in the Queue tab. No pumpAndSettle here:
    // live progress rebuilds never quiesce.
    await tester.tap(find.byTooltip('Queue'));
    await tester.pump(const Duration(seconds: 2));
    await _waitFor(
      tester,
      find.text('Completed'),
      timeout: const Duration(minutes: 6),
    );
  });
}
