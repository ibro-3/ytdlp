// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Waits for [finder] (or [orElse]) to appear, printing a heartbeat so a CI
/// run that hangs is still diagnosable.
Future<void> waitFor(
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
        'best=${find.textContaining('Best quality').evaluate().isNotEmpty} '
        'chips=${find.byType(ChoiceChip).evaluate().length}',
      );
    }
  }
  fail('Timed out waiting for $finder');
}

/// The first [SelectableText] on screen — where the app surfaces a fetch error.
String errorText(WidgetTester tester) {
  final found = find.byType(SelectableText).evaluate();
  if (found.isEmpty) return '<no error text>';
  return (found.first.widget as SelectableText).data ?? '<empty>';
}
