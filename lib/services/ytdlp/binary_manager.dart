import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

/// Locates the `yt-dlp` binary:
///
/// Desktop:
/// 1. On PATH — `which` / `where`
/// 2. Bundled app asset — `assets/bin/<platform>/yt-dlp`
/// 3. Downloaded from GitHub releases into the app support dir
///
/// Android:
/// 1. Legacy single-file asset — `assets/bin/android/<abi>/yt-dlp`
///    (custom bionic builds take precedence when present)
/// 2. Bundled CPython + yt-dlp runtime —
///    `assets/bin/android/<abi>/python.tar.gz`
///    (built by `tool/fetch_android_runtime.sh` from Termux packages)
class BinaryManager {
  String? _ytdlpPath;
  String? _ffmpegPath;
  bool? _hasFfmpeg;
  bool _isSystem = false;
  bool _usingRuntime = false;
  String? _managedUrl;

  Future<bool> hasFfmpeg() async {
    if (_hasFfmpeg != null) return _hasFfmpeg!;
    if (Platform.isAndroid) {
      final ffmpeg = await _ensureAndroidFfmpeg();
      return _hasFfmpeg = ffmpeg != null;
    }
    final onPath = await _findOnPath('ffmpeg');
    return _hasFfmpeg = onPath != null;
  }

  static const _runtimeVersion = 'v1';
  static const _ffmpegVersion = 'v1';

  /// Extracts the per-ABI minimal static ffmpeg asset (once per version).
  /// Returns its path, or null when the asset is missing.
  Future<String?> _ensureAndroidFfmpeg() async {
    if (_ffmpegPath != null) return _ffmpegPath;
    final support = await getApplicationSupportDirectory();
    final target = File('${support.path}/bin/ffmpeg');
    final marker = File('${support.path}/bin/.ffmpeg-v');
    if (await target.exists()) {
      try {
        if ((await marker.readAsString()).trim() == _ffmpegVersion) {
          await _ensureExecutable(target.path);
          return _ffmpegPath = target.path;
        }
      } catch (_) {}
      // Stale or unmarked copy from an older app install.
      try {
        await target.delete();
      } catch (_) {}
    }
    final extracted = await _extractAsset('ffmpeg');
    if (extracted != null) {
      try {
        await marker.writeAsString(_ffmpegVersion, flush: true);
      } catch (_) {}
      _ffmpegPath = extracted;
    }
    return _ffmpegPath;
  }

  Future<ProcessRunner> ensureRunner() async {
    if (Platform.isAndroid) return _ensureAndroidRunner();
    final bin = await ensureYtdlp();
    return ProcessRunner(executable: bin);
  }

  Future<String> ensureYtdlp() async {
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
        final preArgs = <String>['$usr/bin/yt-dlp'];
        if (_ffmpegPath != null) {
          preArgs.addAll(['--ffmpeg-location', File(_ffmpegPath!).parent.path]);
        }
        return ProcessRunner(
          executable: '$usr/bin/python3.14',
          preArgs: preArgs,
          env: {
            'LD_LIBRARY_PATH': '$usr/lib',
            'PYTHONHOME': usr,
            'PYTHONPATH': '$usr/lib/python3.14/site-packages',
            'SSL_CERT_FILE': '$usr/etc/tls/cert.pem',
            'HOME': support.path,
            'TMPDIR': cache.path,
          },
        );
      }
    }
    throw YtdlpException(_missingHint());
  }

  /// Extracts the per-ABI python.tar.gz asset into the app support dir
  /// (once per install). Returns the runtime root, or null when the asset
  /// is missing/corrupt.
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
    try {
      final tarBytes = GZipDecoder().decodeBytes(
        data.buffer.asUint8List(),
        verify: true,
      );
      final archive = TarDecoder().decodeBytes(tarBytes);
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
      for (final entry in archive.files) {
        final outPath = '${root.path}/${entry.name}';
        if (entry.isDirectory) {
          await Directory(outPath).create(recursive: true);
        } else if (entry.isSymbolicLink) {
          final target = entry.symbolicLink;
          if (target == null || target.isEmpty) continue;
          final link = Link(outPath);
          await link.parent.create(recursive: true);
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
      final script = File(
        '${root.path}/data/data/com.termux/files/usr/bin/yt-dlp',
      );
      if (!await pythonBin.exists() || !await script.exists()) return null;
      await _chmodX(pythonBin.path);
      await marker.writeAsString(_runtimeVersion, flush: true);
      return root;
    } on YtdlpException {
      rethrow;
    } catch (_) {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
      return null;
    }
  }

  /// Best-effort re-chmod on reuse (e.g. after backup restore); never throws.
  Future<void> _ensureExecutable(String path) async {
    try {
      // ignore: avoid_slow_async_io
      final mode = FileStat.statSync(path).mode;
      if ((mode & 0x40) != 0) return;
    } catch (_) {
      return;
    }
    try {
      await _chmodX(path);
    } catch (_) {}
  }

  /// Installed yt-dlp version string, e.g. `2026.08.19`.
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

  /// Updates the binary in place and returns the new version.
  ///
  /// - System install: runs `yt-dlp -U`.
  /// - App-managed copy: re-downloads (desktop uses the official release
  ///   URL; Android requires [androidUrl] — there is no official build).
  /// - Android bundled runtime: updates ship with app releases.
  Future<String> updateYtdlp({String? androidUrl}) async {
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
    if (_usingRuntime) {
      throw YtdlpException(
        'The bundled Android runtime updates with app releases.\n'
        'Current version is shown above; to refresh it, update the app.',
      );
    }
    final custom = androidUrl?.trim();
    String url;
    if (!Platform.isAndroid) {
      url =
          _managedUrl ??
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/$_officialFileName';
    } else if (custom != null && custom.isNotEmpty) {
      url = custom;
    } else {
      throw YtdlpException(
        'Set an Android yt-dlp build URL in Settings first.\n'
        'There is no official Android build — point it at a bionic '
        'binary for your ABI.',
      );
    }
    final replaced = await _downloadFromUrl(url, force: true);
    if (replaced == null) {
      throw YtdlpException('Download failed — check the URL and connection.');
    }
    _managedUrl = url;
    return ytdlpVersion();
  }

  String get _ytdlpName => Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';

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
        final mode = FileStat.statSync(path).mode;
        if ((mode & 0x40) != 0) return;
      } catch (_) {}
    }
    throw YtdlpException(
      'Could not make the yt-dlp runtime executable ($path).\n'
      'The app may lack permission to execute its own files on this device.',
    );
  }

  /// Copies a bundled binary from assets into the app support dir and
  /// makes it executable (deduplicated per app install).
  Future<String?> _extractAsset(String name) async {
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}/bin/$name');
    if (await target.exists()) return target.path;

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
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
        if (!Platform.isWindows) {
          try {
            await Process.run('chmod', ['755', target.path]);
          } catch (_) {}
        }
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
  Future<String?> _downloadFromUrl(String url, {bool force = false}) async {
    if (kIsWeb) return null;
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}/bin/$_ytdlpName');
    if (!force && await target.exists()) return target.path;

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      await target.parent.create(recursive: true);
      final sink = target.openWrite();
      await res.pipe(sink);
      await sink.close();
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['755', target.path]);
        } catch (_) {}
      }
      return target.path;
    } catch (_) {
      try {
        await target.delete();
      } catch (_) {}
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
