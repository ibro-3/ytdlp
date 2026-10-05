import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/settings/cookie_domains_page.dart';
import 'package:ytdlp/services/cookies/cookie_domains.dart';
import 'package:ytdlp/services/cookies/cookie_jar.dart';
import 'package:ytdlp/services/cookies/cookie_jar_service.dart';
import 'package:ytdlp/services/settings/settings_service.dart';

import '../../support/memory_box.dart';
import '../../support/pump.dart';

/// A jar shaped like a real browser export: the site yt-dlp needs, an analytics
/// host nobody meant to hand over, a long-dead login, and one host whose cookies
/// only live as long as the browser does.
const _jar = '''
# Netscape HTTP Cookie File
.youtube.com\tTRUE\t/\tTRUE\t4102444800\tSID\tone
.youtube.com\tTRUE\t/\tTRUE\t0\tHSID\ttwo
.example.test\tTRUE\t/\tFALSE\t1798761600\tTOKEN\tthree
.stale.test\tTRUE\t/\tFALSE\t1000000000\tOLD\tfour
.session.test\tTRUE\t/\tFALSE\t0\tLIVE\tfive
''';

Set<String> _hostsIn(String path) =>
    CookieJar.parse(File(path).readAsStringSync()).entries
        .map((e) => cookieHostKey(e.domain))
        .toSet();

void main() {
  late Directory tempRoot;
  late Box<dynamic> settingsBox;
  late SettingsService settings;
  late CookieJarService jar;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-cookie-domains-');
    // A real box would need closing, and closing it deadlocks once a toggle has
    // left a write in flight — see [MemoryBox].
    settingsBox = MemoryBox();
    settings = SettingsService(settingsBox);
    settings.init();
    jar = CookieJarService(supportDir: '${tempRoot.path}/support');
    // Seeded outside the fake-async zone: a write started inside a widget test
    // never completes there, so it has to be in `setUp`.
    await jar.importSource(_jar);
    // The real paths, because the page reads the source through settings: a
    // placeholder here renders an empty list and every assertion below would
    // pass for the wrong reason.
    await settings.update(
      const AppSettings().copyWith(
        cookiesPath: '/unused',
        cookieSourcePath: '/unused',
      ),
    );
    await settings.update(
      settings.settings.copyWith(
        cookiesPath: jar.generatedPath,
        cookieSourcePath: jar.sourcePath,
      ),
    );
  });

  // No `settingsBox.close()` anywhere in this file, on purpose.
  //
  // Switching a site off persists a setting, so every toggle test leaves a Hive
  // write in flight when the body ends. Closing the box flushes it, and that
  // flush is scheduled against the test's fake clock, which only advances while
  // frames are pumped. `tearDown` pumps nothing, so the close never returns and
  // the run times out rather than failing; moving it into `addTearDown` does not
  // help either, because `runAsync` is unavailable once the body has ended.
  //
  // [_MemoryBox] below is a real `Box<dynamic>` — the provider is typed to one,
  // and the code under test calls nothing else — so the writes land in memory
  // and there is no flush to wait for. Each test also gets its own box, so
  // nothing carries over.
  // A fallback for the tests that never call [pump], which is where the box
  // close is registered.
  tearDown(() async {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(WidgetTester tester) async {
    // Tall enough for every row. A `ListView` only builds what is on screen, so
    // a switch that has not been scrolled to is not merely off-screen, it does
    // not exist — and `tester.tap` on it would silently report success.
    tester.view.physicalSize = const Size(500, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsBoxProvider.overrideWithValue(settingsBox),
          cookieSupportDirProvider.overrideWithValue(
            () async => jar.supportDir,
          ),
        ],
        child: const MaterialApp(home: CookieDomainsPage()),
      ),
    );
    await settleIo(tester);
  }

  Finder switchFor(String domain) =>
      find.widgetWithText(SwitchListTile, domain);

  /// The hosts withheld according to the box the provider writes to.
  ///
  /// The box is shared, so unlike a `SettingsService` instance it does see the
  /// page's writes.
  List<String> storedDisabled() => [
    for (final d
        in (settingsBox.get('app_settings') as Map?)?['cookieDisabledDomains']
                as List? ??
            const [])
      if (d is String) d,
  ];

  /// Taps a switch and waits for everything the tap sets off: the file rewrite,
  /// the settings write, and the rebuild.
  ///
  /// The wait condition reads the *generated file*, and only the file. Two
  /// things it must not read:
  ///
  /// - the settings box. [pumpUntil] evaluates its condition inside
  ///   `runAsync`, and a Hive read there blocks against the write the tap
  ///   started — the condition never completes and the test times out rather
  ///   than failing. Read the box after settling instead, via
  ///   [storedDisabled].
  /// - the widget tree. `tester.widget` inside `runAsync` does not settle
  ///   either.
  Future<void> toggleAndSettle(
    WidgetTester tester,
    String domain, {
    required bool endsUpSent,
  }) async {
    await tester.tap(switchFor(domain));
    await pumpUntil(
      tester,
      () => _hostsIn(jar.generatedPath).contains(domain) == endsUpSent,
      rounds: 40,
    );
    await settleIo(tester);
    expect(
      _hostsIn(jar.generatedPath).contains(domain),
      endsUpSent,
      reason:
          'the switch asked for the host to be '
          '${endsUpSent ? "sent" : "withheld"}',
    );
  }

  /// Taps the switch that would empty the jar, and waits for the refusal.
  ///
  /// Deliberately not [toggleAndSettle]: that waits for the file to change, and
  /// the whole point of this case is that it must not. The refusal is observable
  /// through the banner, so that is what settles.
  Future<void> toggleExpectingRefusal(
    WidgetTester tester,
    String domain, {
    required String because,
  }) async {
    await tester.tap(switchFor(domain));
    await pumpUntil(
      tester,
      () => find.textContaining(because).evaluate().isNotEmpty,
      rounds: 40,
    );
  }

  group('listing', () {
    testWidgets('names every host in the jar', (tester) async {
      await pump(tester);

      expect(find.text('youtube.com'), findsOneWidget);
      expect(find.text('example.test'), findsOneWidget);
      expect(find.text('stale.test'), findsOneWidget);
      expect(find.text('session.test'), findsOneWidget);
    });

    testWidgets('shows how many cookies each host carries', (tester) async {
      await pump(tester);

      expect(find.textContaining('2 cookies ·'), findsOneWidget);
      // Only the hosts whose label is a date; stale.test's is "Expired", and
      // counting it here would make this assertion depend on the other test.
      expect(
        find.textContaining('1 cookie · Expires'),
        findsOneWidget,
        reason: 'example.test, whose single cookie is dated',
      );
      expect(find.textContaining('1 cookie · Expired'), findsOneWidget);
      expect(find.textContaining('1 cookie · Session'), findsOneWidget);
    });

    testWidgets('flags a host whose cookies have all expired', (tester) async {
      // A jar of dead cookies is one of the common reasons a login "stopped
      // working" with nothing visible to explain it.
      await pump(tester);

      expect(find.textContaining('needs re-exporting'), findsOneWidget);
    });

    testWidgets('describes a session-only host as one', (tester) async {
      await pump(tester);

      expect(find.textContaining('browser closes'), findsOneWidget);
    });

    testWidgets('says what switching a site off actually does', (tester) async {
      // The whole point of this page is that omission is invisible from the
      // download log, so the consequence has to be on screen before the user
      // acts on it rather than discovered afterwards.
      await pump(tester);

      expect(find.textContaining('are not sent to it'), findsOneWidget);
    });

    testWidgets('offers no restore-all while everything is on', (tester) async {
      await pump(tester);

      expect(find.text('Turn all on'), findsNothing);
    });
  });

  group('switching a site off', () {
    testWidgets('takes its cookies out of the file yt-dlp reads', (
      tester,
    ) async {
      await pump(tester);

      await toggleAndSettle(tester, 'example.test', endsUpSent: false);

      expect(_hostsIn(jar.generatedPath), isNot(contains('example.test')));
      expect(_hostsIn(jar.generatedPath), contains('youtube.com'));
    });

    testWidgets('leaves the source intact so the site can come back', (
      tester,
    ) async {
      await pump(tester);

      await toggleAndSettle(tester, 'example.test', endsUpSent: false);

      expect(_hostsIn(jar.sourcePath), contains('example.test'));
    });

    testWidgets('persists the choice', (tester) async {
      await pump(tester);

      await toggleAndSettle(tester, 'example.test', endsUpSent: false);

      expect(storedDisabled(), ['example.test']);
    });

    testWidgets('shows the switch as off', (tester) async {
      await pump(tester);

      await toggleAndSettle(tester, 'example.test', endsUpSent: false);

      expect(
        tester.widget<SwitchListTile>(switchFor('example.test')).value,
        isFalse,
      );
    });

    testWidgets('strikes the row through', (tester) async {
      await pump(tester);

      await toggleAndSettle(tester, 'example.test', endsUpSent: false);

      // Dimming alone is easy to miss on a long list, and this row's entire
      // point is that its cookies are not going anywhere.
      final title =
          tester.widget<SwitchListTile>(switchFor('example.test')).title!
              as Text;
      expect(title.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('says how many cookies are being withheld', (tester) async {
      await pump(tester);

      await toggleAndSettle(tester, 'example.test', endsUpSent: false);

      // Knowing a site is off does not tell the user how much of their login
      // is still working, so the count is stated rather than left to infer.
      expect(find.textContaining('1 cookie is not being sent'), findsOneWidget);
      expect(find.text('Turn all on'), findsOneWidget);
    });

    testWidgets('restores the site when switched back on', (tester) async {
      await pump(tester);

      await toggleAndSettle(tester, 'example.test', endsUpSent: false);
      await toggleAndSettle(tester, 'example.test', endsUpSent: true);

      expect(_hostsIn(jar.generatedPath), contains('example.test'));
      expect(storedDisabled(), isEmpty);
    });
  });

  group('switching everything off', () {
    testWidgets('refuses rather than writing an empty jar', (tester) async {
      await pump(tester);

      for (final host in ['youtube.com', 'example.test', 'stale.test']) {
        await toggleAndSettle(tester, host, endsUpSent: false);
      }
      await toggleExpectingRefusal(
        tester,
        'session.test',
        because: 'Every site is switched off',
      );

      // yt-dlp handed a valid file with no cookies in it would make every
      // download fail with a 403 the user cannot connect back to a switch. What
      // survives the refusal is the previous, working jar — which at this point
      // holds only the one host left, since each accepted switch narrowed it.
      expect(find.textContaining('Every site is switched off'), findsOneWidget);
      expect(_hostsIn(jar.generatedPath), isNotEmpty);
      expect(storedDisabled(), isNot(contains('session.test')));
    });

    testWidgets('a refused switch stays on rather than lying', (tester) async {
      await pump(tester);
      for (final host in ['youtube.com', 'example.test', 'stale.test']) {
        await toggleAndSettle(tester, host, endsUpSent: false);
      }

      await toggleExpectingRefusal(
        tester,
        'session.test',
        because: 'Every site is switched off',
      );

      // Showing a switch as off when its cookies are still being sent would be
      // the same silent-omission problem in the other direction: the user
      // believes the site is withdrawn and it is not.
      expect(
        tester.widget<SwitchListTile>(switchFor('session.test')).value,
        isTrue,
      );
      expect(storedDisabled(), isNot(contains('session.test')));
    });
  });

  group('a browser source overrides the whole page', () {
    testWidgets('says the switches are not in effect', (tester) async {
      await settings.update(
        settings.settings.copyWith(cookieBrowser: 'firefox'),
      );
      await pump(tester);

      // The switches below still work and still persist — they are preparing
      // the jar for when the browser is turned off. What must not happen is the
      // page presenting them as governing what is sent right now, because a
      // browser's store is read by yt-dlp directly and cannot be filtered.
      expect(find.textContaining('cannot filter a browser'), findsOneWidget);
      expect(find.textContaining('Not being sent right now'), findsOneWidget);
      expect(find.textContaining('Firefox'), findsWidgets);
    });

    testWidgets('says nothing when no browser is configured', (tester) async {
      await pump(tester);

      // A permanent banner would train the reader to stop reading it.
      expect(find.textContaining('cannot filter a browser'), findsNothing);
      expect(find.textContaining('Not being sent right now'), findsNothing);
    });

    testWidgets('ignores an unrecognised browser name', (tester) async {
      // `resolveCookieSource` treats it as no browser, and so must the banner.
      await settings.update(settings.settings.copyWith(cookieBrowser: 'moz'));
      await pump(tester);

      expect(find.textContaining('cannot filter a browser'), findsNothing);
    });
  });

  group('two taps in a row', () {
    testWidgets('the second is ignored rather than interleaved', (
      tester,
    ) async {
      await pump(tester);

      // Tapped twice with no settle in between. Both would read the same
      // starting list of withheld hosts, and whichever wrote last would win —
      // so a user double-tapping "turn this site off" on a fast machine could
      // end up with the site on.
      await tester.tap(switchFor('example.test'));
      await tester.tap(switchFor('example.test'));
      await settleIo(tester);

      expect(storedDisabled(), ['example.test']);
      expect(_hostsIn(jar.generatedPath), isNot(contains('example.test')));
    });

    testWidgets('the controls go dead while the write is in flight', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(switchFor('example.test'));
      await tester.pump();

      // Not a spinner in place of the list — that would hide the row the user
      // just pressed, for a write that takes milliseconds. Only the controls
      // are disabled.
      expect(find.byType(SwitchListTile), findsWidgets);
      expect(
        tester.widget<SwitchListTile>(switchFor('youtube.com')).onChanged,
        isNull,
      );

      await settleIo(tester);
      expect(
        tester.widget<SwitchListTile>(switchFor('youtube.com')).onChanged,
        isNotNull,
        reason: 'and they come back once the write lands',
      );
    });
  });

  group('turning everything back on', () {
    testWidgets('restores every withheld host at once', (tester) async {
      await pump(tester);
      await toggleAndSettle(tester, 'example.test', endsUpSent: false);

      await tester.tap(find.text('Turn all on'));
      await pumpUntil(tester, () => storedDisabled().isEmpty);

      expect(_hostsIn(jar.generatedPath), contains('example.test'));
      expect(
        tester.widget<SwitchListTile>(switchFor('example.test')).value,
        isTrue,
      );
    });
  });

  group('no cookies loaded', () {
    testWidgets('says so rather than showing a blank list', (tester) async {
      // Cleared *before* the first frame, because that is the state a user
      // actually reaches this page in — the tile that opens it is only offered
      // once a jar is loaded. Settings changing afterwards do not rebuild the
      // page, which reads them once in `initState`.
      await tester.runAsync(() => settings.update(const AppSettings()));
      await pump(tester);

      expect(find.text('No cookies are loaded.'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
    });
  });

  group('an unreadable jar', () {
    testWidgets('explains itself and asks for a re-import', (tester) async {
      await tester.runAsync(
        () => File(jar.sourcePath).writeAsString('# gone\n'),
      );
      await pump(tester);

      expect(find.textContaining("couldn't be read"), findsOneWidget);
    });
  });
}
