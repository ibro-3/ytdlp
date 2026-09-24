import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/video_info.dart';
import 'binary_manager.dart';
import 'bounded_capture.dart';
import 'json_payload.dart';

class YtdlpException implements Exception {
  const YtdlpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A running yt-dlp process. Kept as an interface so the download manager
/// can be tested with a fake process.
abstract interface class DownloadProcess {
  Stream<String> get lines;
  Future<int> get exitCode;
  void cancel();
}

/// Thin abstraction over starting a download so `DownloadManager` does not
/// depend directly on process spawning.
abstract interface class DownloadEngine {
  Future<DownloadProcess> startDownload({
    required String url,
    required Format format,
    required String outputDir,
    required String template,
    String? cookiesPath,
  });
}

class YtdlpProcess implements DownloadProcess {
  YtdlpProcess(this._process);
  final Process _process;

  @override
  Stream<String> get lines {
    final out = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final err = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    // Merge without extra dependency
    final controller = StreamController<String>();
    var doneOut = false;
    var doneErr = false;
    void checkDone() {
      if (doneOut && doneErr && !controller.isClosed) controller.close();
    }

    out.listen(
      controller.add,
      onDone: () {
        doneOut = true;
        checkDone();
      },
      onError: controller.addError,
    );
    err.listen(
      controller.add,
      onDone: () {
        doneErr = true;
        checkDone();
      },
      onError: controller.addError,
    );
    return controller.stream;
  }

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void cancel() {
    try {
      _process.kill(ProcessSignal.sigterm);
    } catch (_) {
      try {
        _process.kill();
      } catch (_) {}
    }
  }
}

class YtdlpService implements DownloadEngine {
  YtdlpService(this._binary);
  final BinaryManager _binary;

  static const _metadataTimeout = Duration(seconds: 90);

  Future<VideoInfo> fetchVideoInfo(String url) async {
    final r = await _binary.ensureRunner();
    final hasFfmpeg = await _binary.hasFfmpeg();

    final run = await _runCaptured(r, [
      '-J',
      '--no-warnings',
      '--no-playlist',
      url,
    ], timeout: _metadataTimeout);
    if (run.timedOut) {
      throw const YtdlpException(
        'Getting video info timed out. The site may be slow — try again.',
      );
    }
    // A payload this large is never a single video. A playlist URL makes
    // yt-dlp emit the whole collection and still exit 0, which used to
    // surface as the useless "produced too much output".
    if (run.stdoutOverflowed) {
      throw YtdlpException(_oversizeMessage(run));
    }
    if (run.code != 0) {
      throw YtdlpException(
        _extractError(run.stderr) ?? 'yt-dlp exited with code ${run.code}',
      );
    }
    try {
      final decoded = decodeYtdlpPayload(run.stdout);
      if (decoded == null) {
        throw YtdlpException(jsonFailureMessage(run.stdout));
      }
      if (decoded is! Map<String, dynamic>) {
        throw const YtdlpException('Unexpected yt-dlp response.');
      }
      return VideoInfo.fromYtdlpJson(decoded, hasFfmpeg: hasFfmpeg);
    } on FormatException {
      // Only reachable from fromYtdlpJson's parsing; a decode failure is
      // already turned into an actionable message above.
      throw const YtdlpException(
        'yt-dlp sent video details the app could not understand.\n'
        'Try updating yt-dlp in Settings.',
      );
    }
  }

  /// Explains an oversized metadata response, naming the most likely cause.
  static String _oversizeMessage(_CapturedRun run) {
    final size = formatBytesShort(run.stdoutBytes);
    if (BoundedCapture.looksLikePlaylist(run.stdout) ||
        run.stderr.toLowerCase().contains('playlist')) {
      return 'That link is a playlist, and this app downloads one video at a '
          'time.\nOpen the playlist and copy the link to a single video.';
    }
    return 'The site sent a very large response ($size) that the app could '
        'not read.\nTry a different link, or report it with the site name.';
  }

  /// Runs a command, capturing output under byte budgets and killing the
  /// process when it exceeds [timeout] or floods stdout.
  ///
  /// The two streams get separate budgets: the JSON payload on stdout is
  /// allowed to be large (and its head is kept so the caller can tell a
  /// playlist from a genuinely huge response), while stderr is a diagnostic
  /// stream whose *tail* is kept. Overflowing stderr never fails an otherwise
  /// successful command — chatty warnings are not a download error.
  Future<_CapturedRun> _runCaptured(
    ProcessRunner runner,
    List<String> args, {
    required Duration timeout,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        runner.executable,
        runner.args(args),
        environment: runner.env,
      );
    } catch (e) {
      throw YtdlpException(_spawnHint(e));
    }

    const maxStdout = 16 * 1024 * 1024;
    const maxStderr = 64 * 1024;
    final out = BoundedCapture(maxBytes: maxStdout, keep: CaptureKeep.head);
    final err = BoundedCapture(
      maxBytes: maxStderr,
      keep: CaptureKeep.tail,
      windowChars: 16 * 1024,
    );

    void kill() {
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {
        try {
          process.kill();
        } catch (_) {}
      }
    }

    // A payload that blows the budget is never useful to us — stop reading and
    // stop the process rather than letting it write into the void.
    var killedForFlood = false;
    final outSub = process.stdout.transform(lenientDecoder).listen((chunk) {
      if (!out.add(chunk) && !killedForFlood) {
        killedForFlood = true;
        kill();
      }
    });
    final errSub = process.stderr.transform(lenientDecoder).listen((chunk) {
      err.add(chunk);
    });

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      kill();
    });

    final code = await process.exitCode;
    timer.cancel();
    await outSub.cancel();
    await errSub.cancel();

    return _CapturedRun(
      code: code,
      stdout: out.text,
      stderr: err.text,
      timedOut: timedOut,
      stdoutBytes: out.bytes,
      stdoutOverflowed: out.overflowed,
      stderrOverflowed: err.overflowed,
      killedForFlood: killedForFlood,
    );
  }

  @override
  Future<YtdlpProcess> startDownload({
    required String url,
    required Format format,
    required String outputDir,
    required String template,
    String? cookiesPath,
  }) async {
    final bin = await _binary.ensureRunner();
    final args = <String>[
      '--newline',
      '--no-playlist',
      '--no-mtime',
      // Resume a partially downloaded .part file instead of starting over.
      // Enabled by default in yt-dlp, but stated here because the manager
      // deliberately keeps staging directories around for retries.
      '--continue',
      // yt-dlp's defaults are 10/10; spelled out so the intent survives a
      // future upstream change. --retry-sleep adds a capped linear backoff
      // (none by default), which matters a lot on flaky mobile networks.
      '--retries',
      '10',
      '--fragment-retries',
      '10',
      '--retry-sleep',
      'linear=1:5:2',
      '--force-overwrites',
      '-o',
      '$outputDir/$template',
      '-f',
      format.selector,
    ];
    if (cookiesPath != null && cookiesPath.isNotEmpty) {
      args.addAll(['--cookies', cookiesPath]);
    }
    args.add(url);
    final ffmpeg = await _binary.androidFfmpegLocation();
    if (ffmpeg != null) {
      args.insertAll(0, ['--ffmpeg-location', ffmpeg]);
    }

    final YtdlpProcess process;
    try {
      process = YtdlpProcess(
        await Process.start(
          bin.executable,
          bin.args(args),
          environment: bin.env,
        ),
      );
    } catch (e) {
      throw YtdlpException(_spawnHint(e));
    }
    return process;
  }

  /// The location of the bundled Android ffmpeg, or null when unavailable.
  Future<String?> androidFfmpeg() => _binary.androidFfmpegLocation();

  /// Turns a failed process spawn into an actionable message. On Android the
  /// usual culprit is Android 14+ SELinux denying `execute` on the app's own
  /// files (`avc: denied { execute_no_trans }`) when targetSdk >= 34.
  static String _spawnHint(Object error) {
    final detail = error is ProcessException && error.message.isNotEmpty
        ? error.message
        : error.toString();
    if (!Platform.isAndroid) {
      return 'Could not start yt-dlp ($detail).';
    }
    return 'Could not start the bundled yt-dlp runtime ($detail).\n'
        'On Android this usually means SELinux is blocking execution of app '
        'files — build with targetSdk 28 or lower (see README "Android notes").';
  }

  static String? _extractError(String stderr) {
    final text = stderr;
    final lines = const LineSplitter().convert(text);
    for (final line in lines.reversed) {
      final idx = line.indexOf('ERROR:');
      if (idx >= 0) return line.substring(idx + 6).trim();
    }
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed.split('\n').last.trim();
  }
}

/// Result of a captured run, with enough context to explain a failure.
class _CapturedRun {
  const _CapturedRun({
    required this.code,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
    required this.stdoutBytes,
    required this.stdoutOverflowed,
    required this.stderrOverflowed,
    required this.killedForFlood,
  });

  final int code;
  final String stdout;
  final String stderr;
  final bool timedOut;

  /// Bytes seen on stdout, including any dropped after the budget was hit.
  final int stdoutBytes;

  final bool stdoutOverflowed;

  /// Only a diagnostic hint: stderr overflow never fails a successful command.
  final bool stderrOverflowed;

  final bool killedForFlood;
}
