import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/app.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

/// Pumps [App] with [problems] as its start-up failures.
Future<void> pumpApp(
  WidgetTester tester, {
  required Box<dynamic> settingsBox,
  List<String> problems = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsBoxProvider.overrideWithValue(settingsBox),
        ytdlpServiceProvider.overrideWithValue(
          YtdlpService(BinaryManager()),
        ),
      ],
      child: App(startupProblems: problems),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory tempRoot;
  late Box<dynamic> settingsBox;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-app-');
    Hive.init(tempRoot.path);
    settingsBox = await Hive.openBox<dynamic>('app-test');
  });

  tearDown(() async {
    await settingsBox.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('start-up problems', () {
    testWidgets('a clean start shows no banner', (tester) async {
      await pumpApp(tester, settingsBox: settingsBox);

      expect(find.textContaining('did not start'), findsNothing);
    });

    testWidgets('are reported in the app rather than killing it', (
      tester,
    ) async {
      // Everything before `runApp` used to throw, which ended the process with a
      // blank screen — an optional subsystem failing to initialise meant no app
      // at all, and nothing to report about why.
      await pumpApp(tester, settingsBox: settingsBox, problems: [
        'Notifications could not be set up.',
      ]);

      expect(find.text('Part of the app did not start'), findsOneWidget);
      expect(find.text('Notifications could not be set up.'), findsOneWidget);
      // The app itself is still there underneath.
      expect(find.byType(AppBar), findsWidgets);
    });

    testWidgets('can be dismissed and stay dismissed', (tester) async {
      await pumpApp(tester, settingsBox: settingsBox, problems: [
        'The "queue" store could not be opened.',
      ]);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text('Part of the app did not start'), findsNothing);
      // A settings change rebuilds MaterialApp, which must not bring it back.
      await settingsBox.put('app_settings', {'themeSeed': 3});
      await tester.pumpAndSettle();
      expect(find.textContaining('did not start'), findsNothing);
    });

    testWidgets('several failures are counted, not listed as one', (
      tester,
    ) async {
      await pumpApp(tester, settingsBox: settingsBox, problems: [
        'The "history" store could not be opened.',
        'Notifications could not be set up.',
      ]);

      expect(find.text('2 parts of the app did not start'), findsOneWidget);
      expect(find.text('The "history" store could not be opened.'), findsOneWidget);
      expect(find.text('Notifications could not be set up.'), findsOneWidget);
    });
  });
}