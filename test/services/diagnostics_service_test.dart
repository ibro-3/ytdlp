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
