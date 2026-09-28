import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/models/download_options.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/video_info.dart';
import '../../core/models/yt_prefs.dart';
import 'binary_manager.dart';
import 'bounded_capture.dart';
import 'json_payload.dart';

/// Builds the yt-dlp command line for one download.
///
/// Embed and conversion flags are gated on `hasFfmpeg` (bundled on Android, on
/// PATH on desktop). Those flags make yt-dlp run postprocessing, which probes
/// the output with **ffprobe** — so this should only be true when ffprobe is
/// reachable too, or the download fails with "ffprobe not found". On Android
/// [androidFfmpegPath] is prepended so yt-dlp finds the bundled binary, and it
/// looks for ffprobe in the same directory.
List<String> buildDownloadArgs({
  required String url,
  required Format format,
  required DownloadOptions options,
  required String outputDir,
  required String template,
  String? cookiesPath,
  bool hasFfmpeg = true,
  String? androidFfmpegPath,
  List<String> extraArgs = const [],
  YtPrefs prefs = const YtPrefs(),
  String? archivePath,
}) {
  final args = <String>[
    '--newline',
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
  ];

  // User flags go in *between* the app's groups.
  //
  // For a single-valued option yt-dlp lets the last occurrence win, so every
  // flag the app owns has to be stated after this block: a user-supplied -o
  // or -f would otherwise redirect the staging path and break the
  // finalise/move step, and --yes-playlist would expand one task into a whole
  // collection. The first-class preference flags are part of the managed group
  // for the same reason — a raw `-x --audio-format wav` in the extra-args
  // field must not silently outrank the picker.
  //
  // validateExtraArgs reports the conflicting flags in the UI rather than
  // dropping them silently.
  args.addAll(extraArgs);

  args.addAll(
    _prefsArgs(prefs, hasFfmpeg: hasFfmpeg, archivePath: archivePath),
  );

  args.addAll([
    '--no-playlist',
    '-o',
    '$outputDir/$template',
    '-f',
    format.selector,
  ]);

  if (cookiesPath != null && cookiesPath.isNotEmpty) {
    args.addAll(['--cookies', cookiesPath]);
  }

  // Subtitles: the format sheet already prevents embedding into audio files,
  // but the builder re-checks so a restored/retried task can never ask for
  // an impossible embed.
  final embedSubs = options.embedSubs && format.kind == FormatKind.video;
  if (options.writeSubs || embedSubs) {
    args.add('--write-subs');
    if (options.includeAutoSubs) args.add('--write-auto-subs');
    args.addAll(['--sub-langs', options.subLangsTarget]);
  }
  if (embedSubs) {
    // MP4/M4A text tracks must be srt (auto captions are vtt-only), and the
    // conversion is harmless for MKV/WebM. Sidecars keep yt-dlp's default
    // format so the sidecar path works without ffmpeg.
    if (hasFfmpeg) args.addAll(['--convert-subs', 'srt']);
    args.add('--embed-subs');
  }

  if (options.writeThumb) {
    args.addAll(['--write-thumbnail', '--convert-thumbnails', 'jpg']);
  }
  // Embedding is skipped when the postprocessing the user configured cannot
  // hold a cover image (e.g. `--extract-audio` into WAV), which yt-dlp would
  // otherwise drop silently. The format sheet disables the toggle in that
  // case; this is the backstop for a task that was queued before the change.
  if (options.embedThumb && prefs.canEmbedThumbnail) {
    args.add('--embed-thumbnail');
  }

  if (androidFfmpegPath != null) {
    args.insertAll(0, ['--ffmpeg-location', androidFfmpegPath]);
  }
  args.add(url);
  return args;
}

/// The flags implied by the first-class preference controls.
///
/// Split out from [buildDownloadArgs] so the mapping is unit-testable on its
/// own, and emitted in the app-owned group so a raw `-x` or `-r` typed into the
/// extra-args field cannot outrank the picker for the last-word-wins rule.
List<String> _prefsArgs(
  YtPrefs prefs, {
  required bool hasFfmpeg,
  String? archivePath,
}) {
  final args = <String>[];

  // Throughput. Left at 1 (yt-dlp's default) unless asked, so nothing changes
  // for a user who never touches the control.
  if (prefs.concurrentFragments > 1) {
    args.addAll(['-N', '${prefs.concurrentFragments}']);
  }
  if (prefs.limitRate.trim().isNotEmpty) {
    args.addAll(['-r', prefs.limitRate.trim()]);
  }
  if (prefs.sleepRequests > 0) {
    args.addAll(['--sleep-requests', '${prefs.sleepRequests}']);
  }
  if (prefs.proxy.trim().isNotEmpty) {
    args.addAll(['--proxy', prefs.proxy.trim()]);
  }
  if (prefs.referer.trim().isNotEmpty) {
    args.addAll(['--referer', prefs.referer.trim()]);
  }
  if (prefs.liveFromStart) args.add('--live-from-start');

  // --no-part opts out of the .part file the manager relies on to resume a
  // failed download, so it is only passed when explicitly requested.
  if (prefs.noPart) args.add('--no-part');

  if (prefs.downloadArchive && archivePath != null && archivePath.isNotEmpty) {
    args.addAll(['--download-archive', archivePath]);
  }

  // Everything below runs through yt-dlp's postprocessor, which needs ffmpeg
  // to remux or re-encode and ffprobe to inspect the output. Without them
  // yt-dlp fails with "Postprocessing: ffprobe not found", so the flags are
  // omitted rather than passed through to fail late.
  if (prefs.extractAudio && hasFfmpeg) {
    args.add('-x');
    args.addAll(['--audio-format', prefs.audioFormat]);
  }
  if (prefs.remuxVideo.trim().isNotEmpty && hasFfmpeg) {
    args.addAll(['--remux-video', prefs.remuxVideo.trim()]);
  }
  if (prefs.embedMetadata && hasFfmpeg) args.add('--embed-metadata');
  if (prefs.embedChapters && hasFfmpeg) args.add('--embed-chapters');
  if (prefs.sponsorblockRemove && hasFfmpeg) {
    args.addAll(['--sponsorblock-remove', 'default']);
  }

  return args;
}

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
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
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

/// What a metadata fetch resolved to: either one video, or a playlist whose
/// entries the user can pick from.
///
/// The distinction matters because a playlist has to go through a selection UI
/// before anything is downloaded, while a video goes straight to the format
/// sheet. Both carry the device's ffmpeg/ffprobe capability so the picking UI
/// can gate embed options the same way in both cases.
sealed class FetchResult {
  const FetchResult();
}

class VideoResult extends FetchResult {
  const VideoResult(this.video);
  final VideoInfo video;
}

class PlaylistResult extends FetchResult {
  const PlaylistResult(this.playlist);
  final PlaylistInfo playlist;
}

class YtdlpService implements DownloadEngine {
  YtdlpService(this._binary);
  final BinaryManager _binary;

  static const _metadataTimeout = Duration(seconds: 90);

  /// Fetches metadata for [url], resolving it to either a single video or a
  /// playlist.
  ///
  /// The first request is the ordinary single-video one, so the common case is
  /// unchanged: one `-J --no-playlist` call. Only when that call turns out to
  /// be a playlist is a second, cheaper request made with `--flat-playlist` to
  /// enumerate the entries — flat entries carry no stream data, which keeps
  /// even a large collection inside the metadata byte budget.
  Future<FetchResult> fetch(String url) async {
    final r = await _binary.ensureRunner();
    final hasFfmpeg = await _binary.hasFfmpeg();
    // Embedding/conversion also needs ffprobe, which is not implied by ffmpeg.
    final canPostprocess = await _binary.hasFfprobe();

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

    // A playlist URL either errors out (because --no-playlist forbids
    // expanding it) or, on extractors that do not honour the flag, comes back
    // as a full playlist payload. Both mean "ask again, differently".
    if (_looksLikePlaylist(run)) {
      return _fetchPlaylistEntries(
        r,
        url: url,
        hasFfmpeg: hasFfmpeg,
        canPostprocess: canPostprocess,
      );
    }

    // A payload this large is never a single video. The playlist case is
    // handled above, so this is a site genuinely flooding the app.
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
      return VideoResult(
        VideoInfo.fromYtdlpJson(
          decoded,
          hasFfmpeg: hasFfmpeg,
          canPostprocess: canPostprocess,
        ),
      );
    } on FormatException {
      // Only reachable from fromYtdlpJson's parsing; a decode failure is
      // already turned into an actionable message above.
      throw const YtdlpException(
        'yt-dlp sent video details the app could not understand.\n'
        'Try updating yt-dlp in Settings.',
      );
    }
  }

  /// Second-stage fetch: enumerate a playlist's entries without pulling stream
  /// data for each of them.
  Future<FetchResult> _fetchPlaylistEntries(
    ProcessRunner r, {
    required String url,
    required bool hasFfmpeg,
    required bool canPostprocess,
  }) async {
    final run = await _runCaptured(r, [
      '-J',
      '--flat-playlist',
      '--no-warnings',
      url,
    ], timeout: _metadataTimeout);
    if (run.timedOut) {
      throw const YtdlpException(
        'Listing the playlist timed out. The site may be slow — try again.',
      );
    }
    if (run.stdoutOverflowed) {
      throw YtdlpException(
        'That playlist is too large to list '
        '(${formatBytesShort(run.stdoutBytes)}).\n'
        'Try opening it on the site and picking a few videos instead.',
      );
    }
    if (run.code != 0) {
      throw YtdlpException(
        _extractError(run.stderr) ??
            'Could not list that playlist (yt-dlp exited with code '
                '${run.code}).',
      );
    }
    try {
      final decoded = decodeYtdlpPayload(run.stdout);
      if (decoded is! Map<String, dynamic>) {
        throw YtdlpException(jsonFailureMessage(run.stdout));
      }
      final playlist = PlaylistInfo.fromYtdlpJson(
        decoded,
        hasFfmpeg: hasFfmpeg,
        canPostprocess: canPostprocess,
      );
      if (playlist.isEmpty) {
        throw const YtdlpException(
          'That playlist has no videos available to download.\n'
          'They may be private, region-locked, or need a different extractor.',
        );
      }
      return PlaylistResult(playlist);
    } on FormatException {
      throw const YtdlpException(
        'yt-dlp sent playlist details the app could not understand.\n'
        'Try updating yt-dlp in Settings.',
      );
    }
  }

  /// Whether a run resolved to a playlist rather than a video.
  ///
  /// Two shapes have to be accepted. Some extractors honour `--no-playlist`
  /// and fail with "This is a playlist, use --yes-playlist"; others ignore
  /// the flag and return the whole collection as a payload with
  /// `_type: playlist`, still exiting 0. A successful run whose *stdout* names
  /// a playlist is only ever a playlist, so that check needs no error
  /// heuristic; the stderr path applies only to a failed run.
  static bool _looksLikePlaylist(_CapturedRun run) => looksLikePlaylistOutput(
    stdout: run.stdout,
    stderr: run.stderr,
    exitCode: run.code,
  );

  /// Public form of the playlist heuristic, taking the three raw signals
  /// rather than a captured run so it can be pinned by unit tests.
  ///
  /// Over-detecting sends the user down the wrong path (a real "video is
  /// private" error would be retried as a playlist and reported as
  /// "no videos available"), and under-detecting dead-ends them with a message
  /// about downloading one video at a time. Both failure modes are worth a
  /// test, which is why this is separated from the process plumbing.
  @visibleForTesting
  static bool looksLikePlaylistOutput({
    required String stdout,
    required String stderr,
    required int exitCode,
  }) {
    // A payload that says `_type: playlist` is one regardless of exit code:
    // yt-dlp happily returns a whole collection and still exits 0.
    if (BoundedCapture.looksLikePlaylist(stdout)) return true;
    if (exitCode == 0) return false;
    final err = stderr.toLowerCase();
    return err.contains('is a playlist') || err.contains('use --yes-playlist');
  }

  /// Backwards-compatible single-video fetch. Callers that cannot show a
  /// playlist picker get a clear error instead of a wrong-shaped result.
  Future<VideoInfo> fetchVideoInfo(String url) async {
    final result = await fetch(url);
    if (result is VideoResult) return result.video;
    throw const YtdlpException(
      'That link is a playlist, not a single video.\n'
      'Use the Download tab to pick which videos to get.',
    );
  }

  /// Explains an oversized metadata response.
  static String _oversizeMessage(_CapturedRun run) {
    final size = formatBytesShort(run.stdoutBytes);
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
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
  }) async {
    final bin = await _binary.ensureRunner();
    final ffmpeg = await _binary.androidFfmpegLocation();
    final args = buildDownloadArgs(
      url: url,
      format: format,
      options: options,
      outputDir: outputDir,
      template: template,
      cookiesPath: cookiesPath,
      // This defaulted to true before, so embed/conversion flags were added
      // even on a desktop without ffmpeg — where yt-dlp then fails in
      // postprocessing. Probe the real capability instead.
      hasFfmpeg: await _binary.hasFfmpeg(),
      androidFfmpegPath: ffmpeg,
      extraArgs: extraArgs,
      prefs: prefs,
      archivePath: archivePath,
    );

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
