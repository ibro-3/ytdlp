import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/video_info.dart';
import 'binary_manager.dart';

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

    final (code, stdout, stderr, timedOut) = await _runCaptured(r, [
      '-J',
      '--no-warnings',
      '--no-playlist',
      url,
    ], timeout: _metadataTimeout);
    if (timedOut) {
      throw const YtdlpException(
        'Getting video info timed out. The site may be slow — try again.',
      );
    }
    if (code != 0) {
      throw YtdlpException(
        _extractError(stderr) ?? 'yt-dlp exited with code $code',
      );
    }
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is! Map<String, dynamic>) {
        throw const YtdlpException('Unexpected yt-dlp response.');
      }
      return VideoInfo.fromYtdlpJson(decoded, hasFfmpeg: hasFfmpeg);
    } on FormatException {
      throw const YtdlpException('yt-dlp returned invalid JSON.');
    }
  }

  /// Runs a command, capturing stdout/stderr and killing the process when it
  /// exceeds [timeout].
  Future<(int, String, String, bool)> _runCaptured(
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

    final out = StringBuffer();
    final err = StringBuffer();
    const maxCapture = 8 * 1024 * 1024;
    bool tooMuchOutput = false;

    final outSub = process.stdout.transform(utf8.decoder).listen((chunk) {
      if (out.length < maxCapture) {
        out.write(chunk);
      } else {
        tooMuchOutput = true;
      }
    });
    final errSub = process.stderr.transform(utf8.decoder).listen((chunk) {
      if (err.length < maxCapture) {
        err.write(chunk);
      } else {
        tooMuchOutput = true;
      }
    });

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {
        try {
          process.kill();
        } catch (_) {}
      }
    });

    final code = await process.exitCode;
    timer.cancel();
    await outSub.cancel();
    await errSub.cancel();

    if (tooMuchOutput && code == 0) {
      throw const YtdlpException('yt-dlp produced too much output.');
    }
    return (code, out.toString(), err.toString(), timedOut);
  }

  @override
  Future<YtdlpProcess> startDownload({
    required String url,
    required Format format,
    required String outputDir,
    required String template,
  }) async {
    final bin = await _binary.ensureRunner();
    final args = <String>[
      '--newline',
      '--no-playlist',
      '--no-mtime',
      '--force-overwrites',
      '-o',
      '$outputDir/$template',
      '-f',
      format.selector,
      url,
    ];
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
