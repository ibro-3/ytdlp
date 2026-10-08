import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

/// Points the service at a stand-in command instead of the real yt-dlp binary.
///
/// A `/bin/sh` script rather than a Dart program: under `flutter test`,
/// `Platform.resolvedExecutable` is the test runner itself, not the Dart VM, so
/// it cannot run a Dart script. A shell script is enough to produce any
/// stdout/stderr/exit-code combination a test needs.
class _ScriptBinaryManager extends BinaryManager {
  _ScriptBinaryManager(this.script);

  final String script;

  @override
  Future<ProcessRunner> ensureRunner() async =>
      ProcessRunner(executable: '/bin/sh', preArgs: [script]);

  @override
  Future<bool> hasFfmpeg() async => true;

  @override
  Future<bool> hasFfprobe() async => true;
}

void main() {
  late Directory tempRoot;

  setUp(() => tempRoot = Directory.systemTemp.createTempSync('ytdlp-proc-'));

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('captured output is not truncated', () {
    test('a payload larger than the pipe buffer arrives whole', () async {
      // The regression this guards: the pipe subscriptions were cancelled as
      // soon as the exit status came back, discarding bytes that had not been
      // delivered yet. Exit status and pipe output travel on separate channels,
      // so anything beyond the pipe buffer was routinely lost. That surfaced as
      // an intermittent "yt-dlp sent a response the app could not read" and, for
      // a large playlist, an intermittent failure to recognise the output as a
      // playlist at all.
      //
      // Reading the payload at all is the assertion: a truncated read is not
      // valid JSON, so it fails to decode.
      final payload = jsonEncode({
        'id': 'v1',
        'title': 'A video',
        'webpage_url': 'https://example.com/watch?v=v1',
        'duration': 10,
        'formats': [
          // Enough entries that the encoded payload clears 1 MB. 6000 was shy
          // of it (~827 KB), which left the assertion below failing on its own
          // fixture — the truncation it guards was never actually exercised.
          for (var i = 0; i < 9000; i++)
            {
              'format_id': 'f$i',
              'ext': 'mp4',
              'vcodec': 'h264',
              'height': 1080,
              'note': 'x' * 64,
            },
        ],
      });
      expect(
        payload.length,
        greaterThan(1024 * 1024),
        reason:
            'the fixture must exceed a pipe buffer for this to mean anything',
      );

      final service = _serviceThatEchoes(tempRoot, payload, exitCode: 0);

      final result = await service.fetch('https://example.com/watch?v=v1');

      // Parsing at all proves the closing braces arrived.
      expect(result, isA<VideoResult>());
      expect((result as VideoResult).video.id, 'v1');
      expect(result.video.title, 'A video');
      expect(result.video.videoFormats, isNotEmpty);
    });

    test('a large stderr is still readable when the run fails', () async {
      // Same failure mode on the diagnostic stream: cancelling early threw away
      // the tail of the error message, which is the part that says what went
      // wrong.
      final noise = 'chatty warning line ${'x' * 40}\n' * 4000;

      final service = _serviceThatEchoes(
        tempRoot,
        noise,
        stderr: 'ERROR: Video unavailable\n',
        exitCode: 1,
      );

      await expectLater(
        service.fetch('https://example.com/watch?v=v1'),
        throwsA(
          isA<YtdlpException>().having(
            (e) => e.message,
            'message',
            contains('Video unavailable'),
          ),
        ),
      );
    });
  });

  group('process failure handling', () {
    test('a non-zero exit surfaces the error', () async {
      final service = _serviceThatEchoes(
        tempRoot,
        '',
        stderr: 'ERROR: Video unavailable\n',
        exitCode: 1,
      );

      await expectLater(
        service.fetch('https://example.com/watch?v=v1'),
        throwsA(
          isA<YtdlpException>().having(
            (e) => e.message,
            'message',
            contains('Video unavailable'),
          ),
        ),
      );
    });

    test('a child that never exits is killed by the timeout', () async {
      // Without a timeout this fetch would hang for the life of the app.
      final script = File('${tempRoot.path}/hang.sh')
        ..writeAsStringSync('while true; do sleep 1; done\n');

      final service = YtdlpService(
        _ScriptBinaryManager(script.path),
        metadataTimeout: const Duration(seconds: 2),
      );

      await expectLater(
        service.fetch('https://example.com/watch?v=v1'),
        throwsA(
          isA<YtdlpException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
    });
  });
}

/// A service whose command writes [stdout] (and [stderr]), then exits.
///
/// The payload is written to its own file and streamed by `cat` rather than
/// embedded in the script, so the size of the fixture does not depend on shell
/// quoting or command-line length limits.
YtdlpService _serviceThatEchoes(
  Directory root,
  String stdout, {
  String stderr = '',
  int exitCode = 0,
}) {
  final outFile = File('${root.path}/stdout.txt')..writeAsStringSync(stdout);
  final errFile = File('${root.path}/stderr.txt')..writeAsStringSync(stderr);
  final script = File('${root.path}/emit.sh')
    ..writeAsStringSync('''
cat '${outFile.path}'
cat '${errFile.path}' >&2
exit $exitCode
''');

  return YtdlpService(_ScriptBinaryManager(script.path));
}
