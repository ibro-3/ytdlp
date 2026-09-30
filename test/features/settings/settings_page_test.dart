import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/output_template.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/settings/settings_page.dart';
import 'package:ytdlp/services/settings/settings_service.dart';

/// Advances past the frames the carousel's measurement needs.
///
/// The height is read in a post-frame callback and applied with a rebuild, so
/// one `pumpAndSettle` is not always enough to see the settled value.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

/// The extra-args field, found by its hint.
///
/// Scoped by hint rather than by index: a PageView keeps the other page's
/// widgets built, so field order across the carousel is not stable.
Finder _argsField(WidgetTester tester) => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.hintText == '--concurrent-fragments 4 --embed-metadata',
);

/// The output template field, found by its hint.
Finder _templateField(WidgetTester tester) => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.hintText == OutputTemplate.defaultTemplate,
);

void main() {
  late Directory tempRoot;
  late Box<dynamic> settingsBox;
  late SettingsService service;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-settings-');
    Hive.init(tempRoot.path);
    settingsBox = await Hive.openBox<dynamic>('settings-page-test');
    service = SettingsService(settingsBox);
    await service.update(const AppSettings());
  });

  tearDown(() async {
    await settingsBox.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(500, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsBoxProvider.overrideWithValue(settingsBox)],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await settle(tester);
  }

  /// Opens the Advanced expansion and scrolls it into view.
  Future<void> openAdvanced(WidgetTester tester) async {
    await tester.dragUntilVisible(
      find.text('Advanced'),
      find.byType(Scrollable).first,
      const Offset(0, -260),
    );
    await settle(tester);
    await tester.tap(find.text('Advanced'));
    await settle(tester);
  }

  group('sections', () {
    testWidgets('the yt-dlp capabilities have their own top-level sections', (
      tester,
    ) async {
      // These lived inside the Advanced carousel, which made it over a thousand
      // pixels tall. They are common choices, so they must be findable without
      // expanding a collapsed escape hatch.
      await pump(tester);
      expect(find.text('Network'), findsOneWidget);
      expect(find.text('Post-processing'), findsOneWidget);
      expect(find.text('Queue'), findsOneWidget);
    });

    testWidgets('the network controls are not behind Advanced', (tester) async {
      await pump(tester);
      expect(find.text('Proxy'), findsOneWidget);
      expect(find.text('Rate limit'), findsOneWidget);
      expect(
        find.text('Parallel fragments: 1'),
        findsOneWidget,
        reason: 'the fragment slider, outside the carousel',
      );
    });

    testWidgets('the queue controls sit together', (tester) async {
      await pump(tester);
      expect(find.text('Simultaneous downloads'), findsOneWidget);
      expect(find.text('Remembered queue entries'), findsOneWidget);
      expect(find.text('Write without a .part file'), findsOneWidget);
    });
  });

  group('advanced carousel', () {
    testWidgets('both pages are reachable from the tab strip', (tester) async {
      await pump(tester);
      await openAdvanced(tester);

      // The strip is the affordance: a carousel with no visible tab is
      // undiscoverable, and it is what shows that the template moved rather
      // than disappeared.
      expect(find.widgetWithText(Tab, 'Flags'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'File name'), findsOneWidget);

      // Flags is the landing page.
      expect(find.text('Extra yt-dlp flags'), findsOneWidget);
      expect(find.text('File name template'), findsNothing);

      await tester.tap(find.widgetWithText(Tab, 'File name'));
      await settle(tester);

      expect(find.text('File name template'), findsOneWidget);
      expect(find.text('Extra yt-dlp flags'), findsNothing);
      // The strip follows the page.
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller?.index, 1);
    });

    testWidgets('every text field on the template page is that page\'s', (
      tester,
    ) async {
      await pump(tester);
      await openAdvanced(tester);
      await tester.tap(find.widgetWithText(Tab, 'File name'));
      await settle(tester);

      // A PageView keeps the neighbouring page built, so a bare
      // find.byType(TextField) would reach the flags page's fields. Identified
      // by the template's own hint for the same reason.
      expect(
        find.descendant(
          of: find.byType(PageView),
          matching: find.byType(TextField),
        ),
        findsAtLeast(1),
      );
      expect(_templateField(tester), findsOneWidget);
    });

    testWidgets('a swipe moves to the next page and the tab follows', (
      tester,
    ) async {
      await pump(tester);
      await openAdvanced(tester);

      // Dragged from a point that is actually on screen: the carousel is tall,
      // so its centre can be below the fold and a centre-based drag would hit
      // nothing at all.
      final origin = tester.getTopLeft(find.byType(PageView));
      await tester.dragFrom(
        origin + const Offset(250, 40),
        const Offset(-300, 0),
      );
      await settle(tester);

      expect(find.text('File name template'), findsOneWidget);
      final strip = tester.widget<TabBar>(find.byType(TabBar));
      expect(strip.controller?.index, 1);
    });

    testWidgets('neither page is clipped by the carousel height', (
      tester,
    ) async {
      await pump(tester);
      await openAdvanced(tester);

      // The flags page is much taller than the template page, and the
      // carousel has one height for both, so it must be sized to the taller.
      // A RenderFlex overflow inside either page would fail here.
      expect(tester.takeException(), isNull);

      await tester.tap(find.widgetWithText(Tab, 'File name'));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the template field is editable on its own page', (
      tester,
    ) async {
      await pump(tester);
      await openAdvanced(tester);
      await tester.tap(find.widgetWithText(Tab, 'File name'));
      await settle(tester);

      await tester.enterText(_templateField(tester), '%(title)s.%(ext)s');
      await settle(tester);
      // Settings prefixes the rendered example "Example:"; the format sheet
      // uses "Saves as", so the wording differs between the two screens.
      expect(find.textContaining('Example Video Title.mp4'), findsOneWidget);
    });

    testWidgets('one save button commits both pages', (tester) async {
      // A tall window, so the shared button below the carousel is already on
      // screen. Scrolling the settings list to reach it instead does not
      // terminate: the carousel's own scroll view is nested inside that list,
      // and a drag on the list lands inside the carousel rather than moving it.
      await pump(tester, size: const Size(500, 4200));
      await openAdvanced(tester);

      // Edit each page, then save once: the button is shared, so it has to be
      // outside the carousel. Each field is found by its own hint, because a
      // PageView keeps the other page's fields built and reachable.
      await tester.enterText(_argsField(tester), '--embed-metadata');
      await settle(tester);
      expect(
        tester.widget<TextField>(_argsField(tester)).controller!.text,
        '--embed-metadata',
        reason: 'the field really took the text before saving',
      );

      await tester.tap(find.widgetWithText(Tab, 'File name'));
      await settle(tester);
      await tester.enterText(_templateField(tester), '%(title)s.%(ext)s');
      await settle(tester);

      // `runAsync` because saving writes to a Hive box, which is real I/O the
      // test's fake-async zone will not drive — without it the test never
      // finishes rather than failing.
      await tester.runAsync(() async {
        await tester.tap(find.text('Save advanced settings'));
        await tester.pump();
      });
      await settle(tester);

      // Read the box rather than this test's own SettingsService: the provider
      // builds its own service over the same box, so this instance's cached
      // value would not have moved.
      final saved = AppSettings.fromMap(
        Map<String, dynamic>.from(
          settingsBox.get('app_settings') as Map? ?? const {},
        ),
      );
      expect(saved.extraArgs, '--embed-metadata');
      expect(saved.outputTemplate, '%(title)s.%(ext)s');
    });

    testWidgets('a malformed template is still reported on its own page', (
      tester,
    ) async {
      await pump(tester);
      await openAdvanced(tester);
      await tester.tap(find.widgetWithText(Tab, 'File name'));
      await settle(tester);

      await tester.enterText(_templateField(tester), '%(title)s');
      await settle(tester);

      expect(find.textContaining('Must include'), findsWidgets);
      // The save button is disabled, since the template would break the app's
      // ability to tell the media file from its sidecars.
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save advanced settings'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('a template field chip still inserts at the caret', (
      tester,
    ) async {
      await pump(tester);
      await openAdvanced(tester);
      await tester.tap(find.widgetWithText(Tab, 'File name'));
      await settle(tester);

      await tester.enterText(_templateField(tester), '%(title)s');
      await settle(tester);
      await tester.tap(
        find.widgetWithText(ActionChip, 'Video id (keeps names unique)'),
      );
      await settle(tester);

      expect(
        tester.widget<TextField>(_templateField(tester)).controller!.text,
        '%(title)s%(id)s',
      );
    });
  });

  group('no thumbnail option', () {
    testWidgets('neither thumbnail default is offered in Settings', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Embed thumbnail as cover art'), findsNothing);
      expect(find.text('Save thumbnail (.jpg)'), findsNothing);
    });
  });
}
