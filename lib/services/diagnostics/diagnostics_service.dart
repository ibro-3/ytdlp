import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/models/cookie_browser.dart';
import '../settings/settings_service.dart';
import '../ytdlp/binary_manager.dart';

/// Assembles a plain-text support report.
///
/// Every yt-dlp failure mode is a version or environment question, and without
/// a report the only way to answer one is for the user to hand-transcribe
/// versions, ABI and paths from four different screens. One tap here is what
/// turns a bug report into an answerable one.
///
/// Cookies are never included: the setting only records a *path*, and the jar
/// itself is the user's credential.
class DiagnosticsReport {
  const DiagnosticsReport({required this.text, required this.fileName});

  final String text;

  /// Suggested file name, e.g. `ytdlp-diagnostics-2026-09-28.txt`.
  final String fileName;

  /// Writes the report next to [directory], or into the temp dir when the
  /// preferred location is not writable. Returns the written file, or null if
  /// even the temp dir refused.
  Future<File?> write({Directory? directory}) async {
    final candidates = [?directory, Directory.systemTemp];
    for (final dir in candidates) {
      try {
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(text, flush: true);
        return file;
      } catch (_) {
        // Try the next candidate.
      }
    }
    return null;
  }
}

class DiagnosticsService {
  DiagnosticsService({
    required BinaryManager binary,
    required SettingsService settings,
  }) : _binary = binary,
       _settings = settings;

  // ignore_for_file: prefer_initializing_formals
  // A private field cannot be an initializing formal with a public parameter
  // name, which is the shape the providers use.
  final BinaryManager _binary;
  final SettingsService _settings;

  /// Builds the report, tolerating every probe failing.
  ///
  /// A report that omits the yt-dlp version is still useful, so a failure to
  /// read one field must not lose the rest.
  Future<DiagnosticsReport> build() async {
    final settings = _settings.settings;
    final buffer = StringBuffer()
      ..writeln('YTDL diagnostics')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln();

    buffer
      ..writeln('## App')
      ..writeln('version: ${_appVersion()}')
      ..writeln(
        'platform: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
      )
      ..writeln('dart: ${Platform.version.split(' ').first}')
      ..writeln('isAndroid: ${Platform.isAndroid}')
      ..writeln();

    buffer
      ..writeln('## Engine')
      ..writeln('yt-dlp: ${await _probe(() => _binary.ytdlpVersion())}')
      ..writeln('ffmpeg: ${await _probe(() => _binary.hasFfmpeg())}')
      ..writeln('ffprobe: ${await _probe(() => _binary.hasFfprobe())}')
      ..writeln();

    buffer
      ..writeln('## Paths')
      ..writeln('downloadRoot: ${_redactPath(settings.downloadRoot)}')
      ..writeln('cookies configured: ${settings.cookiesPath.isNotEmpty}')
      // The path itself can contain a username, so only whether one is set.
      ..writeln();

    // Domain *names* are safe to report: they are already in the cookie file,
    // in the download URL and in any yt-dlp error. Cookie *values* are the
    // credential and never appear here, in a log, or anywhere else.
    //
    // Both halves are worth reporting. A user whose downloads 403 has usually
    // switched a site off and forgotten, and a report saying only "3 sites
    // disabled" with no names leaves them to bisect it by hand.
    final disabled = settings.cookieDisabledDomains;
    final browser = CookieBrowser.byArgument(settings.cookieBrowser);
    buffer
      ..writeln('## Cookies')
      ..writeln('sites switched off: ${disabled.length}')
      ..writeln(
        disabled.isEmpty
            ? 'switched off: none'
            : 'switched off: ${disabled.join(', ')}',
      )
      // The browser and its profile *name* are safe: both are a fixed word and
      // a directory name, already visible in the user's own browser UI. The
      // folder they live in is not — that path can carry a username, which is
      // why `cookieBrowserRootPath` is never printed here either.
      ..writeln(
        browser == null
            ? 'browser source: none'
            : 'browser source: ${browser.argument}'
                  '${settings.cookieBrowserProfile.trim().isEmpty ? '' : ':${settings.cookieBrowserProfile.trim()}'}',
      )
      // Only worth reporting when it changes what is actually sent: with a
      // browser on, the withheld sites above are stored but not enforced.
      ..writeln(
        browser != null && disabled.isNotEmpty
            ? 'withheld sites not in effect: '
                  '${disabled.length} (the browser store is not filtered)'
            : 'withheld sites not in effect: none',
      )
      ..writeln();

    buffer
      ..writeln('## Settings')
      ..writeln(
        'concurrency: '
        '${settings.resolveConcurrency(isMobile: Platform.isAndroid)}',
      )
      ..writeln('queueSize: ${settings.maxQueueSize}')
      ..writeln('videoTier: ${settings.tierLabel}')
      ..writeln('outputTemplate: ${_redact(settings.outputTemplate)}')
      ..writeln('extraArgs: ${_redact(settings.extraArgs)}')
      ..writeln('concurrentFragments: ${settings.ytPrefs.concurrentFragments}')
      ..writeln('extractAudio: ${settings.ytPrefs.extractAudio}')
      ..writeln('downloadArchive: ${settings.ytPrefs.downloadArchive}');

    return DiagnosticsReport(
      text: buffer.toString(),
      fileName: 'ytdlp-diagnostics-${_stamp()}.txt',
    );
  }

  /// Runs a probe, returning a readable result rather than propagating.
  Future<String> _probe(Future<Object?> Function() fn) async {
    try {
      final value = await fn();
      return value?.toString() ?? 'unavailable';
    } catch (e) {
      return 'unavailable ($e)';
    }
  }

  /// A short date stamp for the file name.
  static String _stamp() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  /// The app version, or a placeholder outside a release build.
  static String _appVersion() {
    // In debug the constant is replaced with the real value at build time.
    return const String.fromEnvironment(
      'FLUTTER_VERSION',
      defaultValue: 'unknown (debug build)',
    );
  }

  /// Masks credentials in a free-text setting before it goes in a report.
  ///
  /// `extraArgs` and `outputTemplate` are raw user text and legitimately carry
  /// `--password`, `--username` or an `--add-header 'Authorization: …'`. A token
  /// in one of those is exactly what the report must not carry: the report is
  /// copied to the clipboard and written to the system temp directory, and from
  /// there into a public bug tracker.
  ///
  /// Truncation alone does not do this — the overwhelming majority of passwords
  /// and bearer tokens are well under any length worth capping at — so the
  /// value is *replaced*, not shortened. The flag name is kept, so a report
  /// still says that a password was configured, which is the part that matters
  /// for diagnosing a login failure.
  static String _redact(String value) {
    final line = value.trim().split('\n').first.trim();
    if (line.isEmpty) return '(not set)';
    var text = line;
    // Ordered so a credential flag is masked before the bare-token pattern can
    // see its key, and a header's value is masked inside its quoting.
    text = text.replaceAllMapped(_credentialHeader, (m) {
      // The header name is kept so the report still says which header was set;
      // a `Referer` is worth reporting and an `Authorization` is not.
      final body = m[2] ?? m[3] ?? m[4] ?? '';
      final colon = body.indexOf(':');
      if (colon <= 0) return m[0]!;
      final name = body.substring(0, colon);
      return _isCredentialHeaderName(name) ? '${m[1]}$name: <redacted>' : m[0]!;
    });
    text = text.replaceAllMapped(
      _credentialFlag,
      (m) => '${m[1]}${m[2]} <redacted>',
    );
    text = text.replaceAllMapped(_bareToken, (m) => '${m[1]}<redacted>');
    return text.length > _maxRedactedChars
        ? '${text.substring(0, _maxRedactedChars)}… (truncated)'
        : text;
  }

  /// Longest field the report carries before it is cut. Only bounds the report
  /// itself; it is not a security measure, which [_redact]'s masking is.
  static const _maxRedactedChars = 120;

  /// Headers whose value is a credential and must not survive into a report.
  static const _credentialHeaderNames = {
    'authorization',
    'cookie',
    'set-cookie',
  };

  static bool _isCredentialHeaderName(String name) {
    final lower = name.trim().toLowerCase();
    return _credentialHeaderNames.contains(lower) ||
        lower.endsWith('-token') ||
        lower.startsWith('x-api-key') ||
        lower.startsWith('x-auth');
  }

  /// A flag whose argument is itself a secret.
  ///
  /// The short forms `-u` and `-p` are matched only at a token boundary so a
  /// `-p` inside a path is not mistaken for a password.
  static final _credentialFlag = RegExp(
    r'''(^|\s)(--(?:ap-)?(?:username|password|video-password|netrc-location)|-[up]\b)(?:[=\s]+)(?:"[^"]*"|'[^']*'|\S+)''',
    caseSensitive: false,
  );

  /// `--add-header 'Authorization: Bearer …'` and friends.
  ///
  /// The three quotings yt-dlp accepts, plus a bare unquoted token. The header
  /// name is kept so the report still says which header was set; only the value
  /// goes, and only for a header that actually carries a credential.
  static final _credentialHeader = RegExp(
    r'''(--add-header\s+)(?:"([^"]*)"|'([^']*)'|(\S+))''',
    caseSensitive: false,
  );

  /// A bearer token or `key=value` secret pasted on its own, outside any flag.
  static final _bareToken = RegExp(
    r'''\b((?:bearer|token|api[_-]?key|secret|password|passwd|pwd)\s*[=:]\s*)(?:"[^"]*"|'[^']*'|\S+)''',
    caseSensitive: false,
  );

  /// Collapses a path to its last two components.
  ///
  /// A download folder can contain a username, and the report is meant to leave
  /// the device. Truncation was not enough: `/home/ibro/Projects/Videos` is
  /// short enough to survive any length cap intact, so the leading components
  /// are dropped rather than the tail.
  static String _redactPath(String value) {
    final path = value.trim();
    if (path.isEmpty) return '(not set)';
    final parts = path
        .split(RegExp(r'[/\\]'))
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.length <= 2
        ? parts.join('/')
        : '…/${parts.sublist(parts.length - 2).join('/')}';
  }
}

/// Notified when the report is ready, so the UI can react without awaiting
/// inside a build.
typedef DiagnosticsListener = void Function(
  DiagnosticsReport? report,
  Object? error,
);

/// Drives [DiagnosticsService.build] as an observable state machine.
///
/// Held for a caller that wants to show progress and the last result — nothing
/// in the app does yet, because the diagnostics screen builds the report on
/// demand. Kept because it is the correct shape for that screen, and because the
/// two things it gets right are easy to get wrong by hand: the in-flight guard,
/// and notifying only while still mounted.
class DiagnosticsNotifier extends ChangeNotifier {
  DiagnosticsNotifier(this._service);

  final DiagnosticsService _service;
  bool _busy = false;
  bool _disposed = false;
  DiagnosticsReport? _last;
  Object? _error;

  bool get isBusy => _busy;
  DiagnosticsReport? get lastReport => _last;
  Object? get error => _error;

  /// Builds the report, or returns the last one if a build is already running.
  ///
  /// The guard matters because building probes the environment — several
  /// subprocesses — so a second tap would double the work and interleave two
  /// results.
  Future<DiagnosticsReport?> generate() async {
    if (_busy) return _last;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final report = await _service.build();
      _last = report;
      return report;
    } catch (e) {
      _error = e;
      return null;
    } finally {
      _busy = false;
      // The build awaits, so the notifier can be disposed underneath it — the
      // caller closing a sheet is enough. Notifying then throws from a disposed
      // ChangeNotifier.
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
