import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/services/diagnostics/diagnostics_service.dart';
import 'package:ytdlp/services/settings/settings_service.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';

/// Stands in for the real engine so no process is ever spawned.
class _StubBinary extends BinaryManager {
  _StubBinary({
    this.version = '2026.09.1',
    this.ffmpeg = true,
    this.ffprobe = true,
    this.versionThrows = false,
  });

  final String version;
  final bool ffmpeg;
  final bool ffprobe;
  final bool versionThrows;

  @override
  Future<String> ytdlpVersion() async {
    if (versionThrows) throw const FormatException('no binary');
    return version;
  }

  @override
  Future<bool> hasFfmpeg() async => ffmpeg;

  @override
  Future<bool> hasFfprobe() async => ffprobe;
}

void main() {
  late Directory tempRoot;
  late Box<dynamic> box;
  late SettingsService settings;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-diag-');
    Hive.init(tempRoot.path);
    box = await Hive.openBox<dynamic>('diag');
    settings = SettingsService(box);
    // main() does this at startup; the service reads whatever init() loaded.
    settings.init();
  });

  tearDown(() async {
    await box.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<DiagnosticsReport> build({BinaryManager? binary}) =>
      DiagnosticsService(
        binary: binary ?? _StubBinary(),
        settings: settings,
      ).build();

  group('report contents', () {
    test('includes the engine versions', () async {
      final report = await build(binary: _StubBinary(version: '2026.09.1'));
      expect(report.text, contains('2026.09.1'));
      expect(report.text, contains('ffmpeg: true'));
      expect(report.text, contains('ffprobe: true'));
    });

    test('reports a missing ffprobe rather than failing', () async {
      final report = await build(binary: _StubBinary(ffprobe: false));
      expect(report.text, contains('ffprobe: false'));
    });

    test('reports a missing ffmpeg rather than failing', () async {
      final report = await build(binary: _StubBinary(ffmpeg: false));
      expect(report.text, contains('ffmpeg: false'));
    });

    test('a failing version probe does not lose the rest', () async {
      // The report is still useful without a version, so the failure is
      // inlined rather than thrown.
      final report = await build(binary: _StubBinary(versionThrows: true));
      expect(report.text, contains('unavailable'));
      expect(report.text, contains('## App'));
      expect(report.text, contains('## Settings'));
    });

    test('never includes the cookie jar path', () async {
      // A path can contain a username, so only the fact is reported.
      await settings.update(
        const AppSettings(cookiesPath: '/secret/cookies.txt'),
      );
      final report = await build();
      expect(report.text, contains('cookies configured: true'));
      expect(report.text, isNot(contains('/secret/cookies.txt')));
    });

    test('names the sites switched off', () async {
      // A report saying only "3 sites disabled" leaves a user whose downloads
      // 403 to bisect it by hand. Host names are safe to include: they are
      // already in the cookie file, in the URL, and in any yt-dlp error.
      await settings.update(
        const AppSettings(
          cookiesPath: '/secret/cookies.txt',
          cookieDisabledDomains: ['youtube.com', 'analytics.example'],
        ),
      );
      final report = await build();
      expect(report.text, contains('## Cookies'));
      expect(report.text, contains('sites switched off: 2'));
      expect(report.text, contains('youtube.com, analytics.example'));
    });

    test('says plainly when no site is switched off', () async {
      // "none" rather than an empty line, so the reader is not left wondering
      // whether the section failed to load.
      await settings.update(
        const AppSettings(cookiesPath: '/secret/cookies.txt'),
      );
      final report = await build();
      expect(report.text, contains('switched off: none'));
    });

    test('names the browser and its profile', () async {
      // Both are safe to include — a fixed word and a directory name, both
      // already visible in the user's own browser UI — and without them a
      // report cannot tell "no cookies" from "cookies from the wrong profile".
      await settings.update(
        const AppSettings(
          cookieBrowser: 'chrome',
          cookieBrowserProfile: 'Profile 2',
        ),
      );
      final report = await build();
      expect(report.text, contains('browser source: chrome:Profile 2'));
    });

    test('says plainly when there is no browser source', () async {
      final report = await build();
      expect(report.text, contains('browser source: none'));
    });

    test('never prints the browser profile folder', () async {
      // Same reason as the jar path: a folder can carry a username.
      await settings.update(
        const AppSettings(
          cookieBrowser: 'firefox',
          cookieBrowserRootPath: '/home/someone/.mozilla/firefox',
        ),
      );
      final report = await build();
      expect(report.text, contains('browser source: firefox'));
      expect(report.text, isNot(contains('/home/someone')));
      expect(report.text, isNot(contains('.mozilla')));
    });

    test('flags withheld sites that a browser store makes moot', () async {
      // The one case where the withheld list is stored but *not* enforced.
      // Reporting the count without this would read as "1 site is off",
      // which is false while the browser is the source.
      await settings.update(
        const AppSettings(
          cookiesPath: '/x/cookies.txt',
          cookieBrowser: 'chrome',
          cookieDisabledDomains: ['analytics.example'],
        ),
      );
      final report = await build();
      expect(report.text, contains('withheld sites not in effect: 1'));
      expect(report.text, contains('the browser store is not filtered'));
    });

    test(
      'says no withheld site is moot when no browser is configured',
      () async {
        await settings.update(
          const AppSettings(
            cookiesPath: '/x/cookies.txt',
            cookieDisabledDomains: ['analytics.example'],
          ),
        );
        final report = await build();
        expect(report.text, contains('withheld sites not in effect: none'));
      },
    );

    test('an unrecognised browser name does not reach the report', () async {
      // A hand-edited box could hold anything; a report that echoed it would
      // be quoting an unvalidated value as if it were a configuration.
      await settings.update(const AppSettings(cookieBrowser: 'chrom'));
      final report = await build();
      expect(report.text, contains('browser source: none'));
      expect(report.text, isNot(contains('chrom')));
    });

    test('truncates a long free-text setting', () async {
      await settings.update(AppSettings(extraArgs: '--x ${'y' * 300}'));
      final report = await build();
      expect(report.text, contains('truncated'));
      expect(report.text, isNot(contains('y' * 200)));
    });

    test('only the first line of a multi-line setting is reported', () async {
      await settings.update(const AppSettings(extraArgs: '--first\n--second'));
      final report = await build();
      expect(report.text, contains('--first'));
      expect(report.text, isNot(contains('--second')));
    });

    test('an empty setting is marked rather than blank', () async {
      final report = await build();
      expect(report.text, contains('(not set)'));
    });

    test('the file name carries the date', () async {
      final report = await build();
      expect(report.fileName, startsWith('ytdlp-diag'));
      expect(report.fileName, matches(RegExp(r'\d{4}-\d{2}-\d{2}\.txt$')));
    });
  });

  group('writing', () {
    test('writes the report to the given directory', () async {
      final dir = Directory.systemTemp.createTempSync('ytdlp-diag-out-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final file = await DiagnosticsReport(
        text: 'hello',
        fileName: 'r.txt',
      ).write(directory: dir);
      expect(file, isNotNull);
      expect(await file!.readAsString(), 'hello');
    });

    test('falls back to the temp dir when the target refuses', () async {
      // An unwritable location must not lose the report.
      final file = await DiagnosticsReport(
        text: 'x',
        fileName: 'r2.txt',
      ).write(directory: Directory('/proc/nonexistent-cannot-write'));
      expect(file, isNotNull);
      expect(file!.path, contains('r2.txt'));
      await file.delete();
    });
  });
}
