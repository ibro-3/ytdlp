import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ytdlp_service.dart';

/// How to spawn yt-dlp: either a single self-contained binary (desktop,
/// custom Android builds) or `python <script>` with a runtime environment
/// (Android Termux-based runtime).
class ProcessRunner {
  const ProcessRunner({
    required this.executable,
    this.preArgs = const [],
    this.env = const <String, String>{},
  });

  final String executable;
  final List<String> preArgs;
  final Map<String, String> env;

  List<String> args(List<String> rest) => [...preArgs, ...rest];
}

/// The extracted Termux-based CPython runtime on Android, kept around so the
/// updater can run and replace the bundled yt-dlp script.
class _AndroidRuntime {
  const _AndroidRuntime({
    required this.python,
    required this.script,
    required this.env,
    required this.sitePackages,
  });

  /// `<usr>/bin/python3.14`
  final String python;

  /// `<usr>/bin/yt-dlp` — the script the runtime executes.
  final String script;

  final Map<String, String> env;

  /// `<usr>/lib/python3.14/site-packages`, taken from `PYTHONPATH`. A Python
  /// package installed here is importable by the runtime, which is how the
  /// YouTube JS runtime gets added without touching the interpreter itself.
  final String sitePackages;
}

/// A read-only view of the extracted Android runtime, for callers that need to
/// run the bundled interpreter — currently the YouTube JS-runtime installer.
///
/// The private [_AndroidRuntime] keeps the mutable extraction state to itself;
/// this exposes only what an outside caller legitimately needs.
class AndroidRuntimeHandle {
  const AndroidRuntimeHandle({
    required this.python,
    required this.script,
    required this.env,
    required this.sitePackages,
  });

  final String python;
  final String script;
  final Map<String, String> env;
  final String sitePackages;
}

/// Locates the `yt-dlp` binary:
///
/// Desktop:
/// 1. On PATH — `which` / `where`
/// 2. Bundled app asset — `assets/bin/<platform>/yt-dlp`
/// 3. Downloaded from GitHub releases into the app support dir
///
/// Android:
/// 1. Bundled CPython + yt-dlp runtime —
///    `assets/bin/android/<abi>/python.tar.gz`
///    (built by `tool/fetch_android_runtime.sh` from Termux packages)
///
/// There is deliberately no single-file fallback asset. An earlier revision
/// documented `assets/bin/android/yt-dlp` here, but no such file has ever been
/// committed, so the documented fallback could not resolve and the app only ever
/// produced the "not found" error.
class BinaryManager {
  String? _ytdlpPath;
  String? _ffmpegPath;

  /// Whether the bundled ffprobe was extracted. Distinguishes "ffmpeg is
  /// present but postprocessing is unavailable" from "ffmpeg is missing".
  ///
  /// The probe's own path is deliberately not tracked: yt-dlp derives it from
  /// the `--ffmpeg-location` directory we hand it, and both binaries are
  /// extracted side by side, so the location is never needed by callers.
  bool _probeExtracted = false;

  bool? _hasFfmpeg;
  bool _isSystem = false;
  bool _usingRuntime = false;
  String? _managedUrl;

  Future<String>? _ytdlpFuture;
  Future<ProcessRunner>? _runnerFuture;
  Future<String?>? _ffmpegFuture;
  _AndroidRuntime? _androidRuntime;

  Future<bool> hasFfmpeg() async {
    if (_hasFfmpeg != null) return _hasFfmpeg!;
    if (Platform.isAndroid) {
      final ffmpeg = await _ensureAndroidFfmpeg();
      return _hasFfmpeg = ffmpeg != null;
    }
    final onPath = await _findOnPath('ffmpeg');
    return _hasFfmpeg = onPath != null;
  }

  /// Location of the bundled minimal Android ffmpeg, if available.
  Future<String?> androidFfmpegLocation() {
    if (!Platform.isAndroid) return Future.value(null);
    return _ensureAndroidFfmpeg();
  }

  /// Whether yt-dlp can run postprocessing on this device.
  ///
  /// Embedding subtitles or a thumbnail cover goes through
  /// `FFmpegMetadataPP`, which probes the output with **ffprobe** — ffmpeg
  /// alone is enough to merge DASH streams but not to postprocess, and
  /// yt-dlp fails with "Postprocessing: ffprobe not found" when it is
  /// missing. Desktop installs report true whenever ffmpeg is on PATH, since
  /// a normal system ffmpeg package always ships ffprobe beside it.
  Future<bool> hasFfprobe() async {
    if (!Platform.isAndroid) return hasFfmpeg();
    await _ensureAndroidFfmpeg();
    return _probeExtracted;
  }

  Future<String?> _ensureAndroidFfmpeg() {
    if (_ffmpegPath != null) return Future.value(_ffmpegPath);
    final f = _ffmpegFuture ??= _initAndroidFfmpeg();
    unawaited(
      f.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_ffmpegFuture, f)) _ffmpegFuture = null;
        },
      ),
    );
    return f;
  }

  Future<String?> _initAndroidFfmpeg() async {
    if (_ffmpegPath != null) return _ffmpegPath;
    final support = await getApplicationSupportDirectory();
    final ffmpeg = File('${support.path}/bin/ffmpeg');
    final ffprobe = File('${support.path}/bin/ffprobe');
    final marker = File('${support.path}/bin/.ffmpeg-v');

    if (await ffmpeg.exists()) {
      try {
        if ((await marker.readAsString()).trim() == _ffmpegVersion) {
          await _ensureExecutable(ffmpeg.path);
          // A copy stamped by an older build predates ffprobe. Postprocessing
          // needs it, so re-extract rather than silently fail later.
          if (await ffprobe.exists()) {
            await _ensureExecutable(ffprobe.path);
            // Must be set on this path too. It used to be assigned only in the
            // extraction branch below, so on every launch after the first
            // hasFfprobe() reported false — and the format sheet permanently
            // hid the embed-subtitles / embed-thumbnail toggles for returning
            // Android users, even though ffprobe was sitting right there.
            _probeExtracted = true;
            return _ffmpegPath = ffmpeg.path;
          }
        }
      } catch (_) {}
      // Stale or unmarked copy from an older app install.
      for (final f in [ffmpeg, ffprobe]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    final extracted = await _extractAsset('ffmpeg');
    if (extracted != null) {
      // yt-dlp derives ffprobe's path from the --ffmpeg-location it is given,
      // so the probe must land beside ffmpeg or postprocessing fails with
      // "ffprobe not found". A missing ffprobe is not fatal: ffmpeg alone still
      // merges DASH streams, it just cannot postprocess.
      final probe = await _extractAsset('ffprobe');
      _probeExtracted = probe != null;
      try {
        await marker.writeAsString(_ffmpegVersion, flush: true);
      } catch (_) {}
      _ffmpegPath = extracted;
    }
    return _ffmpegPath;
  }

  // Bump whenever the bundled Android runtime or ffmpeg recipe changes.
  // Combined with the app version it invalidates previously extracted
  // runtimes, so an app upgrade re-extracts fresh assets.
  static const _runtimeBuild = 'py3.14-alpine-v1';
  // v2 added ffprobe alongside ffmpeg, which postprocessing requires.
  static const _ffmpegBuild = 'ffmpeg-8.1.3-static-v2-ffprobe';
  static const _toolVersion = '2026.09.1';

  /// The `yt-dlp-ejs` release the JS-runtime installer fetches. Pinned rather
  /// than tracking "latest" so an install is reproducible and a bad upstream
  /// release cannot break every user's YouTube downloads; bumped in step with
  /// [_toolVersion].
  static const ytEjsVersion = '2025.09.25';
  static const _runtimeVersion = '$_toolVersion-$_runtimeBuild';
  static const _ffmpegVersion = '$_toolVersion-$_ffmpegBuild';

  Future<ProcessRunner> ensureRunner() {
    // Memoize the running init future so two concurrent callers (e.g. a
    // metadata fetch and a download starting at the same time) never extract
    // or download the binary twice. A failed attempt is forgotten so a
    // subsequent call can retry.
    final f = _runnerFuture ??= _initRunner();
    unawaited(
      f.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_runnerFuture, f)) _runnerFuture = null;
        },
      ),
    );
    return f;
  }

  Future<ProcessRunner> _initRunner() async {
    if (Platform.isAndroid) {
      final runner = await _ensureAndroidRunner();
      _runnerFuture = Future.value(runner);
      return runner;
    }
    final bin = await ensureYtdlp();
    final runner = ProcessRunner(executable: bin);
    _runnerFuture = Future.value(runner);
    return runner;
  }

  Future<String> ensureYtdlp() {
    final f = _ytdlpFuture ??= _initYtdlp();
    unawaited(
      f.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_ytdlpFuture, f)) _ytdlpFuture = null;
        },
      ),
    );
    return f;
  }

  Future<String> _initYtdlp() async {
    if (_ytdlpPath != null) return _ytdlpPath!;
    final onPath = await _findOnPath(_ytdlpName);
    if (onPath != null) {
      _isSystem = true;
      return _ytdlpPath = onPath;
    }
    final bundled = await _extractAsset(_ytdlpName);
    if (bundled != null) {
      _isSystem = false;
      return _ytdlpPath = bundled;
    }
    if (!Platform.isAndroid) {
      final downloaded = await _downloadFromGithub();
      if (downloaded != null) return _ytdlpPath = downloaded;
      // The auto-download was attempted and failed. Reporting why beats the
      // generic "not found" hint, which sends the user to install a system
      // package when the actual problem was a 503 or a captive portal.
      final why = takeDownloadError();
      if (why != null) {
        throw YtdlpException(
          '${_missingHint()}\n\nDownloading yt-dlp did not work: $why',
        );
      }
    }
    throw YtdlpException(_missingHint());
  }

  Future<ProcessRunner> _ensureAndroidRunner() async {
    // Custom single-file bionic builds win when bundled.
    try {
      final bin = await ensureYtdlp();
      return ProcessRunner(executable: bin);
    } on YtdlpException {
      // Fall through to the bundled runtime.
    }
    final abi = await _androidAbi();
    final candidates = <String>[
      if (abi != null) 'assets/bin/android/$abi/python.tar.gz',
    ];
    for (final assetPath in candidates) {
      final dir = await _extractRuntime(assetPath);
      if (dir != null) {
        _usingRuntime = true;
        final usr = '${dir.path}/data/data/com.termux/files/usr';
        final support = await getApplicationSupportDirectory();
        final cache = await getTemporaryDirectory();
        await _ensureAndroidFfmpeg();
        final runtime = _AndroidRuntime(
          python: '$usr/bin/python3.14',
          script: '$usr/bin/yt-dlp',
          sitePackages: '$usr/lib/python3.14/site-packages',
          env: {
            'LD_LIBRARY_PATH': '$usr/lib',
            'PYTHONHOME': usr,
            'PYTHONPATH': '$usr/lib/python3.14/site-packages',
            'SSL_CERT_FILE': '$usr/etc/tls/cert.pem',
            'HOME': support.path,
            'TMPDIR': cache.path,
          },
        );
        _androidRuntime = runtime;
        return ProcessRunner(
          executable: runtime.python,
          preArgs: <String>[runtime.script],
          env: runtime.env,
        );
      }
    }
    throw YtdlpException(_missingHint());
  }

  /// Extracts a tar.gz asset into the app support dir, atomically.
  ///
  /// Extraction goes into a temp directory first and is swapped over the
  /// previous runtime only when the result verified (executable present,
  /// marker written). Entry names are validated so archive paths can never
  /// escape the runtime root, and symlinks that would point outside the
  /// runtime are skipped. A partial/corrupt extraction never replaces a
  /// working runtime.
  Future<Directory?> _extractRuntime(String assetPath) async {
    final support = await getApplicationSupportDirectory();
    final abi = assetPath.split('/').reversed.skip(1).first;
    final root = Directory('${support.path}/pyrt-$abi');
    final marker = File('${root.path}/.ready-$_runtimeVersion');
    final pythonBin = File(
      '${root.path}/data/data/com.termux/files/usr/bin/python3.14',
    );
    if (await marker.exists() && await pythonBin.exists()) {
      await _ensureExecutable(pythonBin.path);
      return root;
    }

    ByteData data;
    try {
      data = await rootBundle.load(assetPath);
    } catch (_) {
      return null;
    }
    final tmpRoot = Directory('${root.path}.tmp');
    try {
      final tarBytes = GZipDecoder().decodeBytes(
        data.buffer.asUint8List(),
        verify: true,
      );
      final archive = TarDecoder().decodeBytes(tarBytes);
      if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
      await tmpRoot.create(recursive: true);
      for (final entry in archive.files) {
        final outPath = _safeJoin(tmpRoot.path, entry.name);
        if (outPath == null) continue; // Path escapes the runtime root.
        if (entry.isDirectory) {
          await Directory(outPath).create(recursive: true);
        } else if (entry.isSymbolicLink) {
          final target = entry.symbolicLink;
          if (target == null || target.isEmpty) continue;
          final link = Link(outPath);
          await link.parent.create(recursive: true);
          if (await _pointsOutside(tmpRoot.path, outPath, target)) continue;
          try {
            if (await link.exists()) await link.delete();
          } catch (_) {}
          await link.create(target);
        } else if (entry.isFile) {
          final out = File(outPath);
          await out.parent.create(recursive: true);
          await out.writeAsBytes(entry.content as List<int>, flush: true);
        }
      }
      final tmpPython = File(
        '${tmpRoot.path}/data/data/com.termux/files/usr/bin/python3.14',
      );
      final script = File(
        '${tmpRoot.path}/data/data/com.termux/files/usr/bin/yt-dlp',
      );
      if (!await tmpPython.exists() || !await script.exists()) return null;
      await _chmodX(tmpPython.path);
      await File('${tmpRoot.path}/.ready-$_runtimeVersion')
          .writeAsString(_runtimeVersion, flush: true);
      await _swapDir(tmpRoot, root);
      return root;
    } on YtdlpException {
      rethrow;
    } catch (_) {
      try {
        if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
      } catch (_) {}
      return null;
    }
  }

  /// Joins [root] with a (possibly backslash or `..`-laden) archive name,
  /// returning null when the result would land outside [root].
  String? _safeJoin(String root, String name) {
    final normalized = p.normalize(
      p.joinAll([root, ...name.split(RegExp(r'[/\\]+'))]),
    );
    return p.isWithin(root, normalized) ? normalized : null;
  }

  /// Whether a symlink at [linkPath] pointing to [target] would resolve
  /// outside [root]. Relative targets are resolved from the link's parent;
  /// absolute targets must stay inside [root].
  Future<bool> _pointsOutside(
    String root,
    String linkPath,
    String target,
  ) async {
    try {
      final absolute = p.isAbsolute(target)
          ? target
          : p.join(p.dirname(linkPath), target);
      final normalized = p.normalize(absolute);
      return !p.isWithin(root, normalized);
    } catch (_) {
      return true;
    }
  }

  /// Swaps [src] directory over [dst], preserving the previous runtime on
  /// failure so the app is never left without one.
  Future<void> _swapDir(Directory src, Directory dst) async {
    final backup = Directory('${dst.path}.old');
    if (await backup.exists()) await backup.delete(recursive: true);
    if (await dst.exists()) await dst.rename(backup.path);
    try {
      await src.rename(dst.path);
      if (await backup.exists()) await backup.delete(recursive: true);
    } catch (e) {
      try {
        if (await backup.exists()) await backup.rename(dst.path);
      } catch (_) {}
      rethrow;
    }
  }

  /// Best-effort re-chmod on reuse (e.g. after backup restore); never throws.
  Future<void> _ensureExecutable(String path) async {
    try {
      // Awaited rather than `statSync`: this runs on the UI isolate, and a
      // stat there blocks a frame. `avoid_slow_async_io` wants exactly this.
      final stat = await FileStat.stat(path);
      if ((stat.mode & 0x40) != 0) return;
    } catch (_) {
      return;
    }
    try {
      await _chmodX(path);
    } catch (_) {}
  }

  /// Installed yt-dlp version string, e.g. `2026.08.19`.
  /// The extracted Android runtime, or null when this install does not use one.
  ///
  /// Memoized alongside the runner, so a caller can run the bundled
  /// interpreter without triggering a second extraction.
  Future<AndroidRuntimeHandle?> get androidRuntime async {
    // Triggers extraction if it has not happened yet, which is what makes the
    // runtime available to callers on first use.
    await ensureRunner();
    if (!_usingRuntime) return null;
    final runtime = _androidRuntime;
    if (runtime == null) return null;
    return AndroidRuntimeHandle(
      python: runtime.python,
      script: runtime.script,
      env: runtime.env,
      sitePackages: runtime.sitePackages,
    );
  }

  /// The app's private files directory, where downloaded engines and the
  /// YouTube JS runtime are kept.
  Future<Directory> get supportDirectory => getApplicationSupportDirectory();

  Future<String> ytdlpVersion() async {
    final r = await ensureRunner();
    try {
      final res = await Process.run(
        r.executable,
        r.args(['--version']),
        environment: r.env,
      );
      if (res.exitCode != 0) {
        throw YtdlpException('yt-dlp --version failed (exit ${res.exitCode})');
      }
      return (res.stdout as String).trim().split('\n').first.trim();
    } catch (e) {
      if (e is YtdlpException) rethrow;
      throw YtdlpException('Could not read yt-dlp version: $e');
    }
  }

  /// Updates yt-dlp in place and returns the new version.
  ///
  /// The source is fixed — there is nothing to configure:
  /// - System install: runs `yt-dlp -U`.
  /// - Desktop app-managed copy: re-downloads the official single-file build.
  /// - Android bundled runtime: replaces the yt-dlp script inside the
  ///   extracted CPython runtime with the official standalone release. The
  ///   interpreter, ffmpeg and native libs still come from the app bundle, so
  ///   refreshing those needs an app update.
  Future<String> updateYtdlp() async {
    await ensureRunner();
    if (_isSystem && _ytdlpPath != null) {
      final res = await Process.run(_ytdlpPath!, ['-U']);
      final out = '${res.stdout}${res.stderr}'.trim();
      if (res.exitCode != 0) {
        throw YtdlpException(
          out.isEmpty
              ? 'yt-dlp -U failed (exit ${res.exitCode})'
              : out.split('\n').last.trim(),
        );
      }
      return ytdlpVersion();
    }
    if (Platform.isAndroid) return _updateAndroidRuntime();

    final url =
        _managedUrl ??
        'https://github.com/yt-dlp/yt-dlp/releases/latest/download/$_officialFileName';
    final replaced = await _downloadFromUrl(url, force: true);
    if (replaced == null) {
      // The reason the download actually failed, not a generic one: it was
      // either an HTTP status or a body too small to be a build.
      final why = takeDownloadError();
      throw YtdlpException(
        why == null ? 'Download failed — check the connection.' : why,
      );
    }
    _ytdlpPath = replaced;
    _isSystem = false;
    _managedUrl = url;
    return ytdlpVersion();
  }

  /// Refreshes the yt-dlp script inside the bundled Android runtime.
  ///
  /// The download is verified by actually running `--version` with the
  /// runtime's interpreter before it replaces the working script, so a bad or
  /// incompatible download can never break a working engine.
  Future<String> _updateAndroidRuntime() async {
    final runtime = _androidRuntime;
    if (!_usingRuntime || runtime == null) {
      throw YtdlpException(
        'This install runs a custom yt-dlp binary, and custom build URLs are '
        'no longer configurable.\n'
        'Install a newer app build to get a refreshed engine.',
      );
    }
    final tmp = File('${runtime.script}.new');
    if (!await _downloadToFile(_ytDlpScriptUrl, tmp)) {
      final why = takeDownloadError();
      throw YtdlpException(
        why == null ? 'Download failed — check the connection.' : why,
      );
    }
    try {
      await _chmodX(tmp.path);
      final probe = await Process.run(runtime.python, [
        tmp.path,
        '--version',
      ], environment: runtime.env);
      if (probe.exitCode != 0) {
        final detail = '${probe.stdout}${probe.stderr}'.trim();
        throw YtdlpException(
          'The downloaded yt-dlp did not run on this device.\n'
          '${detail.isEmpty ? 'exit ${probe.exitCode}' : detail}',
        );
      }
      await _replaceWith(tmp, File(runtime.script));
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    return ytdlpVersion();
  }

  String get _ytdlpName => Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';

  /// Official standalone yt-dlp (a platform-independent Python zipapp).
  /// Android has no official *binary*, but the bundled CPython runtime can run
  /// this script, so it is the fixed update source everywhere.
  static const _ytDlpScriptUrl =
      'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp';

  String get _officialFileName => Platform.isWindows
      ? 'yt-dlp.exe'
      : (Platform.isMacOS ? 'yt-dlp_macos' : 'yt-dlp');

  String _missingHint() {
    if (Platform.isAndroid) {
      return 'yt-dlp runtime not found.\n'
          'Bundle it with tool/fetch_android_runtime.sh, which produces\n'
          'assets/bin/android/<abi>/python.tar.gz (e.g. x86_64 for this\n'
          'emulator, arm64-v8a for devices), then run\n'
          '"flutter clean && flutter run".\n'
          'See the README for details.';
    }
    return 'yt-dlp binary not found.\n'
        'Install it on your system (pip install -U yt-dlp, brew install '
        'yt-dlp, or apt install yt-dlp), or run tool/fetch_binaries.sh '
        'to bundle it.';
  }

  Future<String?> _findOnPath(String name) async {
    if (kIsWeb) return null;
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return null;
    }
    try {
      final which = Platform.isWindows ? 'where' : 'which';
      final res = await Process.run(which, [name]);
      if (res.exitCode == 0) {
        final first = (res.stdout as String).trim().split('\n').first.trim();
        if (first.isNotEmpty) return first;
      }
    } catch (_) {}
    return null;
  }

  /// Makes [path] executable. Uses an absolute toybox path because app
  /// processes on Android have (at best) a minimal PATH, so a bare
  /// `chmod` often fails to resolve. Verifies the result instead of
  /// failing later with an obscure "Permission denied" on exec.
  Future<void> _chmodX(String path) async {
    var done = false;
    for (final chmod in ['/system/bin/chmod', 'chmod']) {
      try {
        final res = await Process.run(chmod, ['755', path]);
        if (res.exitCode == 0) {
          done = true;
          break;
        }
      } catch (_) {}
    }
    if (done) {
      try {
        final stat = await FileStat.stat(path);
        if ((stat.mode & 0x40) != 0) return;
      } catch (_) {}
    }
    throw YtdlpException(
      'Could not make the yt-dlp runtime executable ($path).\n'
      'The app may lack permission to execute its own files on this device.',
    );
  }

  /// Copies a bundled binary from assets into the app support dir and
  /// makes it executable (deduplicated per app install). Writes are done to
  /// a temp file and renamed into place so an interrupted install never
  /// leaves a half-written binary behind.
  Future<String?> _extractAsset(String name) async {
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}/bin/$name');
    if (await target.exists()) {
      // Re-apply the exec bit on reuse (e.g. after a backup restore).
      if (!Platform.isWindows) {
        try {
          await _ensureExecutable(target.path);
        } catch (_) {}
      }
      return target.path;
    }

    final candidates = <String>[];
    if (Platform.isAndroid) {
      final abi = await _androidAbi();
      if (abi != null) candidates.add('assets/bin/android/$abi/$name');
      candidates.add('assets/bin/android/$name');
    } else {
      final p = _assetPath(name);
      if (p != null) candidates.add(p);
    }

    for (final assetPath in candidates) {
      try {
        final data = await rootBundle.load(assetPath);
        await target.parent.create(recursive: true);
        final tmp = File('${target.path}.tmp');
        if (await tmp.exists()) await tmp.delete();
        await tmp.writeAsBytes(data.buffer.asUint8List(), flush: true);
        if (!Platform.isWindows) {
          try {
            await _chmodX(tmp.path);
          } catch (_) {}
        }
        await _replaceWith(tmp, target);
        return target.path;
      } catch (_) {
        // Asset missing or corrupt — try the next candidate.
      }
    }
    return null;
  }

  /// Resolves the Android ABI (arm64-v8a / x86_64 / armeabi-v7a / x86)
  /// so the right bundled binary is picked up.
  Future<String?> _androidAbi() async {
    if (!Platform.isAndroid) return null;
    // Absolute toybox path first: app processes may have a minimal PATH.
    for (final uname in ['/system/bin/uname', 'uname']) {
      try {
        final res = await Process.run(uname, ['-m']);
        if (res.exitCode != 0) continue;
        final m = (res.stdout as String).trim().toLowerCase();
        if (m == 'aarch64' || m == 'arm64') return 'arm64-v8a';
        if (m == 'x86_64') return 'x86_64';
        if (m.startsWith('armv7') || m == 'armv8l') return 'armeabi-v7a';
        if (m == 'i686' || m == 'x86') return 'x86';
        return null;
      } catch (_) {}
    }
    return null;
  }

  String? _assetPath(String name) {
    if (Platform.isAndroid) return 'assets/bin/android/$name';
    if (Platform.isLinux) return 'assets/bin/linux/$name';
    if (Platform.isMacOS) return 'assets/bin/macos/$name';
    if (Platform.isWindows) return 'assets/bin/windows/$name';
    return null;
  }

  /// Desktop-only convenience: grab the official single-file build from
  /// GitHub releases into the app support dir (used only when neither a
  /// system install nor a bundled asset exists).
  Future<String?> _downloadFromGithub() async {
    if (kIsWeb) return null;
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return null;
    }
    final url =
        'https://github.com/yt-dlp/yt-dlp/releases/latest/download/$_officialFileName';
    final path = await _downloadFromUrl(url);
    if (path != null) {
      _isSystem = false;
      _managedUrl = url;
    }
    return path;
  }

  /// Downloads [url] into the app support `bin/` dir. With [force],
  /// replaces any existing copy (used by updates).
  ///
  /// The download lands in a temp file first and is only renamed into place
  /// after it finished and passed validation, so a failed or interrupted
  /// download never destroys the currently working binary.
  Future<String?> _downloadFromUrl(String url, {bool force = false}) async {
    if (kIsWeb) return null;
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}/bin/$_ytdlpName');
    if (!force && await target.exists()) return target.path;
    final ok = await _downloadToFile(url, target);
    return ok ? target.path : null;
  }

  /// Downloads [url] to [target] atomically: bytes land in a temp file first
  /// and are only renamed into place once the transfer finished and produced a
  /// non-empty file. Returns false — leaving [target] untouched — on any
  /// failure.
  Future<bool> _downloadToFile(String url, File target) async {
    if (kIsWeb) return false;
    final tmp = File('${target.path}.tmp');
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw YtdlpException('HTTP ${res.statusCode} from $url');
      }
      await target.parent.create(recursive: true);
      if (await tmp.exists()) await tmp.delete();
      final sink = tmp.openWrite();
      await res.pipe(sink);
      await sink.close();
      final size = await tmp.length();
      if (size == 0) {
        throw const YtdlpException('Downloaded file is empty.');
      }
      // A real yt-dlp build is megabytes. A few bytes means an error page, a
      // captive portal, or a truncated transfer that reported success — and the
      // next step is to chmod it and execute it.
      if (_ytdlpName == 'yt-dlp' || _ytdlpName == 'yt-dlp.exe') {
        if (size < _minPlausibleBinaryBytes) {
          throw YtdlpException(
            'Downloaded yt-dlp is only $size bytes, which cannot be a build.',
          );
        }
      }
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['755', tmp.path]);
        } catch (_) {}
      }
      await _replaceWith(tmp, target);
      return true;
    } catch (e) {
      try {
        await tmp.delete();
      } catch (_) {}
      // Surfaced rather than swallowed. Every caller turns a `false` here into
      // "yt-dlp was not found", so a 503 or an empty body was reported to the
      // user as a missing install — pointing them at a system package that was
      // never the problem.
      _lastDownloadError = e is YtdlpException ? e.message : e.toString();
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// Why the last download attempt failed, or null if it has not failed.
  String? _lastDownloadError;

  /// Message from the most recent failed download, cleared by a success.
  String? takeDownloadError() {
    final message = _lastDownloadError;
    _lastDownloadError = null;
    return message;
  }

  /// Floor for a plausible yt-dlp build, used only to catch an error page.
  ///
  /// Not an integrity check — see [takeDownloadError] and the module note about
  /// verification — just a sanity bound so a 2-byte "200 OK" is not executed.
  static const int _minPlausibleBinaryBytes = 64 * 1024;

  /// Renames [src] over [dst]. On failure the previous file (if any) is
  /// preserved via a backup rename.
  Future<void> _replaceWith(File src, File dst) async {
    final existed = await dst.exists();
    if (!existed) {
      await src.rename(dst.path);
      return;
    }
    final backup = File('${dst.path}.bak');
    if (await backup.exists()) await backup.delete();
    try {
      await dst.rename(backup.path);
    } catch (_) {
      // Destination may be open/locked — keep going with the backup dance.
    }
    try {
      await src.rename(dst.path);
      try {
        if (await backup.exists()) await backup.delete();
      } catch (_) {}
    } catch (_) {
      // Revert: put the previous binary back.
      try {
        if (await backup.exists()) await backup.rename(dst.path);
      } catch (_) {}
      rethrow;
    }
  }
}
