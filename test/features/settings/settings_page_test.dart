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
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Flushes any in-flight save, then closes the box.
  ///
  /// Registered per test rather than in `tearDown` because it needs the tester:
  /// both the Hive `put` and the `close` are real IO, and inside `testWidgets`
  /// — which runs in a fake-async zone — neither would ever complete. Without
  /// this, closing a box with a save still pending waits forever.
  void closeBoxWhenSettled(WidgetTester tester) {
    addTearDown(() async {
      // Unmount first: the page holds a `SettingsService` on the still-mounted
      // tree, and closing the box out from under it leaves a listener that can
      // issue another write. An unmounted tree is quiet, so the close below
      // cannot be followed by another save.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await service.pendingWrite;
        // Bounded: with the tree gone and the last write awaited, nothing should
        // still be in flight — but `close()` waiting on Hive's internal write
        // queue does not always settle here, and a hang would take the whole
        // suite down with it. The box is a per-test temp file that `tearDown`
        // deletes regardless, so giving up on the close costs nothing.
        await settingsBox.close().timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
      });
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(500, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    closeBoxWhenSettled(tester);
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

  group('post-processing capability', () {
    testWidgets('toggles stay enabled while typing in an unrelated field', (
      tester,
    ) async {
      // The capability probe was a FutureBuilder argument, so every rebuild of
      // the section restarted the probe and dropped the answer back to
      // "unavailable" — the switches visibly flickered greyed out on every
      // keystroke in the Proxy field above them.
      //
      // The tall viewport matches the suite's shared `pump`: at the default
      // 600px the post-processing section is below the fold, so a `ListView`
      // never builds it and the enabled-toggle counts describe only whatever
      // happened to be on screen.
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      closeBoxWhenSettled(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsBoxProvider.overrideWithValue(settingsBox),
            ffprobeAvailableProvider.overrideWith((ref) async => true),
          ],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await settle(tester);

      // Type into the Proxy field, which rebuilds this section on every change.
      // Located by hint rather than by `find.byType(TextField).first`, so the
      // lookup does not depend on how much of the page is built.
      final proxy = find.widgetWithText(
        TextField,
        'socks5://host:port — empty for none',
      );

      final enabledBefore = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .where((t) => t.onChanged != null)
          .length;
      expect(
        enabledBefore,
        greaterThan(0),
        reason: 'the toggles settled as enabled once the probe answered',
      );

      await tester.enterText(proxy, 'socks5://1.2.3.4');
      await tester.pump();
      await tester.pump();

      await settle(tester);

      final enabledAfter = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .where((t) => t.onChanged != null)
          .length;
      expect(
        find.textContaining('not available'),
        findsNothing,
        reason: 'the capability is not lost mid-edit',
      );
      expect(
        enabledAfter,
        enabledBefore,
        reason: 'the toggles did not lose their capability mid-edit',
      );
    });

    testWidgets('a device without ffprobe reports it instead of blinking', (
      tester,
    ) async {
      // Tall viewport, as above: the section is below the fold of the default
      // one, so nothing would be built to find.
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      closeBoxWhenSettled(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsBoxProvider.overrideWithValue(settingsBox),
            ffprobeAvailableProvider.overrideWith((ref) async => false),
          ],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await settle(tester);

      expect(
        find.text('ffprobe is not available here, so these are disabled.'),
        findsOneWidget,
      );
    });
  });

  group('restore', () {
    test('a restored backup updates the live app state', () async {
      // A restore rewrites the settings box behind the service. `init` did not
      // notify, so nothing downstream re-read it and the app kept showing the
      // pre-restore theme and defaults until it was restarted.
      final container = ProviderContainer(
        overrides: [settingsBoxProvider.overrideWithValue(settingsBox)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(settingsControllerProvider).maxConcurrency,
        isNull,
        reason: 'nothing has been written yet',
      );

      // Rewrite the box directly, as a restore does.
      await settingsBox.put(
        'app_settings',
        const AppSettings(maxConcurrency: 7).toMap(),
      );
      expect(
        container.read(settingsControllerProvider).maxConcurrency,
        isNull,
        reason: 'the controller still holds the old value',
      );

      container.read(settingsControllerProvider.notifier).reload();

      expect(
        container.read(settingsControllerProvider).maxConcurrency,
        7,
        reason: 'the restored value is now the one the app is using',
      );
    });
  });

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
      // The Queue section sits below the fold now that the network
      // controls grew, so scroll to it before asserting it exists.
      await tester.dragUntilVisible(
        find.text('Queue'),
        find.byType(Scrollable).first,
        const Offset(0, -260),
      );
      await settle(tester);
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

    testWidgets('retry and data-use controls are top-level too', (
      tester,
    ) async {
      await pump(tester);
      // Retry policy is a first-class control, not something to
      // hand-type into the raw-arguments field.
      expect(find.text('Request retries'), findsOneWidget);
      expect(find.text('Fragment retries'), findsOneWidget);
      // So is the data-use rule.
      expect(find.text('Unmetered connections only'), findsOneWidget);
    });

    testWidgets('the queue controls sit together', (tester) async {
      await pump(tester);
      await tester.dragUntilVisible(
        find.text('Simultaneous downloads'),
        find.byType(Scrollable).first,
        const Offset(0, -260),
      );
      await settle(tester);
      expect(find.text('Simultaneous downloads'), findsOneWidget);
      expect(find.text('Remembered queue entries'), findsOneWidget);
      expect(find.text('Write without a .part file'), findsOneWidget);
    });
  });

  group('browser cookies', () {
    // Every `service.update` below is wrapped in `tester.runAsync`. A test body
    // runs in a fake-async zone where the clock only advances while frames are
    // pumped, so a Hive write started there never completes and the test hangs
    // until the framework's timeout rather than failing. `runAsync` hands the
    // write to the real event loop.

    /// Scrolls the page down to the browser-cookie section.
    Future<void> reveal(WidgetTester tester) async {
      await tester.dragUntilVisible(
        find.text('Browser cookies (desktop)'),
        find.byType(Scrollable).first,
        const Offset(0, -260),
      );
      await settle(tester);
    }

    testWidgets('a desktop build offers the browser as a cookie source', (
      tester,
    ) async {
      // This suite runs on the host, so the desktop gate is the one in force.
      // If the gate ever inverts, the control disappears and the reason
      // disappears with it — which is the failure the pure-function tests in
      // cookie_browser_test.dart cannot catch on their own.
      await pump(tester);
      await reveal(tester);

      expect(find.text('Browser cookies (desktop)'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsWidgets);
    });

    testWidgets('with no browser chosen there is no profile picker', (
      tester,
    ) async {
      // Showing one before a browser is chosen would offer a list of profile
      // names that belong to no particular browser.
      await pump(tester);
      await reveal(tester);

      expect(find.text('Profile folder'), findsOneWidget);
      expect(find.text('Profile'), findsNothing);
      // The row is disabled, so it has to say why rather than just going grey.
      expect(find.text('Choose a browser first'), findsOneWidget);
    });

    testWidgets('the cookie tile says a set-aside jar is not being used', (
      tester,
    ) async {
      await tester.runAsync(
        () => service.update(
          const AppSettings(
            cookiesPath: '/x/cookies.txt',
            cookieBrowser: 'chrome',
          ),
        ),
      );
      await pump(tester);
      await reveal(tester);

      // "On — every site in the file is sent" would be a straight lie here.
      expect(
        find.text('Set aside — the browser is the source now'),
        findsOneWidget,
      );
    });

    testWidgets('says what happens to the withheld sites', (tester) async {
      await tester.runAsync(
        () => service.update(
          const AppSettings(
            cookiesPath: '/x/cookies.txt',
            cookieBrowser: 'chrome',
            cookieDisabledDomains: ['analytics.example', 'ads.example'],
          ),
        ),
      );
      await pump(tester);
      await reveal(tester);

      // Without this, the per-site page's switches look like they still
      // govern what is sent.
      expect(
        find.textContaining('2 sites you switched off are still stored'),
        findsOneWidget,
      );
      expect(
        find.textContaining('those switches have no effect'),
        findsOneWidget,
      );
    });

    testWidgets('does not warn about withheld sites when none are stored', (
      tester,
    ) async {
      await tester.runAsync(
        () => service.update(
          const AppSettings(
            cookiesPath: '/x/cookies.txt',
            cookieBrowser: 'chrome',
          ),
        ),
      );
      await pump(tester);
      await reveal(tester);

      expect(
        find.textContaining('switched off are still stored'),
        findsNothing,
      );
    });

    testWidgets('warns that Safari cannot be read off macOS', (tester) async {
      await tester.runAsync(
        () => service.update(const AppSettings(cookieBrowser: 'safari')),
      );
      await pump(tester);
      await reveal(tester);

      // True on the Linux host running this suite, and the reason it is spelled
      // out rather than left for a failed download to explain.
      expect(find.textContaining('can only be read on macOS'), findsOneWidget);
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
