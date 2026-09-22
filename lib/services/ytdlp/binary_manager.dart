import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'ytdlp_service.dart';

/// Locates the `yt-dlp` binary:
///
/// 1. On PATH (desktop) — `which` / `where`
/// 2. Bundled app asset — `assets/bin/<platform>/yt-dlp` (per-ABI on Android)
/// 3. Downloaded from GitHub releases (desktop only — Android needs a
///    bionic build which GitHub does not publish)
class BinaryManager {
  String? _ytdlpPath;
  bool? _hasFfmpeg;

  Future<String> ensureYtdlp() async {
    if (_ytdlpPath != null) return _ytdlpPath!;
    final onPath = await _findOnPath(_ytdlpName);
    if (onPath != null) return _ytdlpPath = onPath;
    final bundled = await _extractAsset(_ytdlpName);
    if (bundled != null) return _ytdlpPath = bundled;
    if (!Platform.isAndroid) {
      final downloaded = await _downloadFromGithub();
      if (downloaded != null) return _ytdlpPath = downloaded;
    }
    throw YtdlpException(_missingHint());
  }

  Future<bool> hasFfmpeg() async {
    if (_hasFfmpeg != null) return _hasFfmpeg!;
    final onPath = await _findOnPath('ffmpeg');
    return _hasFfmpeg = onPath != null;
  }

  String get _ytdlpName => Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';

  String _missingHint() {
    if (Platform.isAndroid) {
      return 'yt-dlp binary not found.\n'
          'Place a yt-dlp build for your device ABI at '
          'assets/bin/android/<abi>/yt-dlp\n'
          '(this emulator: assets/bin/android/x86_64/yt-dlp), then run '
          '"flutter clean && flutter run".\n'
          'See tool/fetch_binaries.sh and the README for details.';
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
    try {
      final res = await Process.run('uname', ['-m']);
      if (res.exitCode != 0) return null;
      final m = (res.stdout as String).trim().toLowerCase();
      if (m == 'aarch64' || m == 'arm64') return 'arm64-v8a';
      if (m == 'x86_64') return 'x86_64';
      if (m.startsWith('armv7') || m == 'armv8l') return 'armeabi-v7a';
      if (m == 'i686' || m == 'x86') return 'x86';
      return null;
    } catch (_) {
      return null;
    }
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
    final dir = await getApplicationSupportDirectory();
    final target = File('${dir.path}/bin/${_ytdlpName}');
    if (await target.exists()) return target.path;

    final fileName = Platform.isWindows
        ? 'yt-dlp.exe'
        : (Platform.isMacOS ? 'yt-dlp_macos' : 'yt-dlp');
    final url =
        'https://github.com/yt-dlp/yt-dlp/releases/latest/download/$fileName';

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