import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/cookies/cookie_domains.dart';
import 'package:ytdlp/services/cookies/cookie_jar.dart';
import 'package:ytdlp/services/cookies/cookie_jar_service.dart';

/// A jar with two hosts, the shape a browser export actually has: the site's
/// real cookies plus a handful of analytics domains the user never meant to
/// hand over.
const _twoSites = '''
# Netscape HTTP Cookie File
.youtube.com\tTRUE\t/\tTRUE\t1798761600\tSID\tone
.youtube.com\tTRUE\t/\tTRUE\t0\tHSID\ttwo
.example.test\tTRUE\t/\tFALSE\t1798761600\tTOKEN\tthree
''';

List<String> _domainsIn(String path) =>
    CookieJar.parse(File(path).readAsStringSync()).entries
        .map((e) => cookieHostKey(e.domain))
        .toList();

void main() {
  late Directory tempRoot;
  late CookieJarService service;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-cookiejar-');
    service = CookieJarService(supportDir: tempRoot.path);
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('an import writes both files and names the source', () async {
    final result = await service.importSource(_twoSites);

    expect(result.wroteSomething, isTrue);
    expect(result.kept, 3);
    expect(result.withheld, 0);
    expect(File(service.sourcePath).existsSync(), isTrue);
    expect(File(service.generatedPath).existsSync(), isTrue);
  });

  test('counts sites separately from cookies', () async {
    // The confirmation says how many *sites* were imported. Reporting the
    // cookie count there instead would be a plausible-looking miscount, and one
    // this jar makes easy to make: 3 cookies across 2 sites.
    final result = await service.importSource(_twoSites);

    expect(result.sites, 2);
    expect(result.kept, 3);
  });

  test('the site count drops a host that is switched off', () async {
    await service.importSource(_twoSites);
    final result = await service.buildGenerated(disabled: {'example.test'});

    expect(result.sites, 1);
    expect(result.kept, 2);
    expect(result.withheld, 1);
  });

  test('a refusal reports no sites rather than guessing', () async {
    await service.importSource(_twoSites);
    final result = await service.buildGenerated(
      disabled: {'youtube.com', 'example.test'},
    );

    expect(result.sites, 0);
  });

  test('the source is the import byte for byte', () async {
    // The source is what makes a switch reversible. A round-trip through the
    // parser would reorder or drop lines, and the user's original would be
    // gone the first time they switched a site off.
    await service.importSource(_twoSites);
    expect(File(service.sourcePath).readAsStringSync(), _twoSites);
  });

  test('switching a site off rewrites only the generated jar', () async {
    await service.importSource(_twoSites);

    final result = await service.buildGenerated(disabled: {'example.test'});

    expect(result.withheld, 1);
    expect(result.kept, 2);
    expect(_domainsIn(service.generatedPath), ['youtube.com', 'youtube.com']);
    // Untouched, so the site can come back.
    expect(_domainsIn(service.sourcePath).toSet(), {
      'youtube.com',
      'example.test',
    });
  });

  test('switching a site back on restores it from the source', () async {
    await service.importSource(_twoSites);
    await service.buildGenerated(disabled: {'example.test'});
    await service.buildGenerated(disabled: const {});

    expect(_domainsIn(service.generatedPath).toSet(), {
      'youtube.com',
      'example.test',
    });
  });

  test('repeated switches do not compound', () async {
    // Rewriting the import in place would make each switch filter an already
    // filtered jar, and the withheld cookies could never return.
    await service.importSource(_twoSites);
    for (var i = 0; i < 5; i++) {
      await service.buildGenerated(disabled: {'example.test'});
      await service.buildGenerated(disabled: const {});
    }

    expect(_domainsIn(service.generatedPath), hasLength(3));
    expect(_domainsIn(service.sourcePath), hasLength(3));
  });

  test('a stale disabled host is pruned on the next import', () async {
    await service.importSource(_twoSites);

    final result = await service.importSource(
      _twoSites,
      disabled: {'gone.test'},
    );

    // Nothing was withheld, so the stale key never took effect — and it is not
    // carried into the new jar either, so it cannot bite later.
    expect(result.withheld, 0);
  });

  test('a real switch survives an import of the same jar', () async {
    await service.importSource(_twoSites, disabled: {'example.test'});
    final result = await service.importSource(
      _twoSites,
      disabled: {'example.test'},
    );

    expect(
      result.withheld,
      1,
      reason: 'the user chose this; keep honouring it',
    );
  });

  test('refuses to write a jar with nothing left in it', () async {
    // The one outcome that must not happen quietly: yt-dlp handed a valid file
    // containing no cookies, and every request failing with a 403 the user
    // cannot connect to the switch they made.
    await service.importSource(_twoSites);

    final result = await service.buildGenerated(
      disabled: {'youtube.com', 'example.test'},
    );

    expect(result.wroteSomething, isFalse);
    expect(result.reason, contains('switched off'));
  });

  test('a refusal leaves the previous jar intact', () async {
    await service.importSource(_twoSites);
    final before = File(service.generatedPath).readAsStringSync();

    await service.buildGenerated(disabled: {'youtube.com', 'example.test'});

    expect(File(service.generatedPath).readAsStringSync(), before);
  });

  test('blames an empty source rather than the switches', () async {
    // The two refusals are different problems with different fixes, so the
    // message must not send the user off to re-export a jar that is perfectly
    // fine.
    await service.importSource('# only a comment\n');

    final empty = await service.buildGenerated(disabled: const {});

    expect(empty.wroteSomething, isFalse);
    expect(empty.reason, contains('no cookies'));
    expect(empty.reason, isNot(contains('switched off')));
  });

  test('reads a missing source as empty instead of throwing', () async {
    // A jar the user deleted behind the app's back is a state the UI explains,
    // not a crash.
    final parsed = await service.readSource('/nowhere/cookies-source.txt');
    expect(parsed.entries, isEmpty);
  });

  test('reads a legacy jar that predates the source file', () async {
    // An install upgrading from a build with a single file has its jar at the
    // generated path and no source; the settings point at the old one.
    File(service.generatedPath).writeAsStringSync(_twoSites);

    final parsed = await service.readSource(service.generatedPath);

    expect(parsed.entries, hasLength(3));
  });

  test('removing cookies deletes both files', () async {
    await service.importSource(_twoSites);

    await service.remove();

    // A withdrawn login left on disk is a credential the user believes they
    // removed.
    expect(File(service.sourcePath).existsSync(), isFalse);
    expect(File(service.generatedPath).existsSync(), isFalse);
  });

  test('removing cookies that were never imported does not throw', () async {
    await expectLater(service.remove(), completes);
  });

  test(
    'both files are written owner-only',
    () async {
      // These are session credentials. `writeAsString` defaults to 0644, so on a
      // desktop install any other process able to read the support directory
      // could read the login.
      await service.importSource(_twoSites);

      for (final path in [service.sourcePath, service.generatedPath]) {
        final mode = File(path).statSync().mode & 0x1FF;
        expect(
          mode,
          0x180, // 0600: rw-------
          reason:
              '$path holds session cookies and must not be group or world '
              'readable',
        );
      }
    },
    // No POSIX mode bits on Windows, and `chmod` is not present. The Android
    // sandbox is what protects these there.
    skip: Platform.isWindows,
  );
}
