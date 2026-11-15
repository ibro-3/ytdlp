import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// What the check found, in a shape the UI can render honestly.
enum AppUpdateStatus { updateAvailable, upToDate, unreachable, unknownCurrent }

/// The result of checking GitHub for a newer YTDL release.
class AppUpdateResult {
  const AppUpdateResult(this.status, {this.release});

  final AppUpdateStatus status;
  final GitHubRelease? release;
}

class AppUpdater {
  AppUpdater({this.http, this.currentVersion});

  /// Injected for tests; defaults to a real [HttpClient].
  final Future<String?> Function(Uri, int)? http;

  /// Where the running version comes from. Defaults to the platform package.
  /// Injectable so tests can drive the decision table without a platform
  /// channel.
  final Future<String?> Function()? currentVersion;

  /// Compares the running app's version (from the platform) against what
  /// GitHub reports as the newest release in this build's channel.
  ///
  /// Channel rules:
  /// - A prerelease build (its own version carries a `-…` identifier) sees
  ///   every published, non-draft release, prereleases included.
  /// - A stable build rides the stable channel: a prerelease of the same or a
  ///   future version never outranks it — a stable user is never nudged onto
  ///   an rc.
  /// - If the repo has no stable release at all to compare against, prereleases
  ///   are considered anyway. "You have the latest" is a claim and it is only
  ///   made after looking at something: a stable 0.1 build released against a
  ///   repo whose only newer artifact is the rc is told the rc exists.
  ///
  /// An offline or erroring check reports itself rather than failing silently:
  /// a user who asked for their status should hear "couldn't check", not "up to
  /// date".
  Future<AppUpdateResult> check() async {
    final version = currentVersion == null
        ? (await PackageInfo.fromPlatform()).version
        : await currentVersion!();
    if (version == null) {
      return const AppUpdateResult(AppUpdateStatus.unknownCurrent);
    }
    final current = SemanticVersion.tryParse(version);
    // Compare via the pure table, which also handles a missing/unparseable
    // version where the UI would rather say so than guess.
    final latest = await _fetchLatest(
      currentIsPrerelease: current?.isPrerelease ?? false,
    );
    final tag = latest?.tag;
    return AppUpdateResult(AppUpdater.compare(tag, version), release: latest);
  }

  /// The `/releases/latest` endpoint GitHub offers does not return pre-releases
  /// at all, so it is not usable here: it would 404 against a repo whose only
  /// release is an rc, forever, and the check would claim "couldn't reach the
  /// server" when the server was fine and the endpoint was just the wrong
  /// question. Hence the list endpoint, selected here.
  Future<GitHubRelease?> _fetchLatest({
    required bool currentIsPrerelease,
  }) async {
    const url =
        'https://api.github.com/repos/ibro-3/ytdlp/releases?per_page=30';
    final https = http;
    final body = https != null
        ? await https(Uri.parse(url), 200)
        : await _defaultGet(url);
    if (body == null) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) return null;
      final candidates = <GitHubRelease>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        // Drafts are invisible to anonymous readers anyway; drop them on
        // principle in case a token ever shows up here.
        if (item['draft'] == true) continue;
        final prerelease = item['prerelease'] == true;
        final tag = item['tag_name'] as String?;
        if (tag == null) continue;
        final version = SemanticVersion.tryParse(tag);
        if (version == null) continue;
        candidates.add(
          GitHubRelease(version: version, tag: tag, prerelease: prerelease),
        );
      }
      if (candidates.isEmpty) return null;
      final stable = candidates.where((r) => !r.prerelease).toList();
      final eligible = currentIsPrerelease || stable.isEmpty
          ? candidates
          : stable;
      // Pick the highest version the channel allows, rather than trusting
      // GitHub's order (newest created first): tags can be cut out of order.
      return eligible.reduce(
        (a, b) => b.version.compareTo(a.version) > 0 ? b : a,
      );
    } catch (_) {
      return null;
    }
  }

  /// Ceiling on a response body.
  ///
  /// A release payload is a few kilobytes; a captive portal's HTML or a
  /// redirect into something unbounded is not, and the cap keeps that from
  /// becoming a download of its own.
  static const int _maxBodyBytes = 1024 * 1024;

  /// How long the release endpoint may go silent — never answering, or
  /// stopping mid-body — before the request is abandoned.
  ///
  /// Neither the connect timeout nor `HttpClient`'s pooled-connection idle
  /// timeout covers a socket left open mid-transfer, so both waits here
  /// (headers, then each chunk gap) are bounded explicitly.
  static const Duration _idle = Duration(seconds: 60);

  /// How long the whole response may keep dribbling before it is abandoned:
  /// a source alive enough to feed the idle bound forever is caught here.
  static const Duration _total = Duration(minutes: 10);

  Future<String?> _defaultGet(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      // The release endpoint is a stable, non-redirecting API URL; pinning
      // this avoids being silently sent anywhere else.
      req.followRedirects = false;
      // `catchError` keeps the header future listened-to so an abandoned one
      // cannot complete later with an unhandled error. Any of these failures
      // is swallowed by the caller's catch and reported as `unreachable`.
      final res = await req
          .close()
          .catchError(
            (Object _, StackTrace _) => throw HttpException('no response'),
          )
          .timeout(_idle, onTimeout: () => throw HttpException('no response'));
      if (res.statusCode != 200) return null;
      final body = StringBuffer();
      var received = 0;
      // Total bound, checked between chunks: wrapping the loop in a timeout
      // would strand the still-running subscription with no listener.
      final watch = Stopwatch()..start();
      await for (final chunk in res.timeout(
        _idle,
        onTimeout: (sink) => sink.addError(HttpException('no response')),
      )) {
        if (watch.elapsed > _total) return null;
        received += chunk.length;
        if (received > _maxBodyBytes) return null;
        body.write(utf8.decode(chunk, allowMalformed: true));
      }
      return body.toString();
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// Pure comparison: given the release tag GitHub reports (or null) and the
  /// running version, what should the UI say?
  ///
  /// Public so tests (and the diagnostics report) can assert the decision
  /// table directly, without going through [PackageInfo] or the network.
  static AppUpdateStatus compare(String? releaseTag, String currentVersion) {
    final current = SemanticVersion.tryParse(currentVersion);
    if (current == null) return AppUpdateStatus.unknownCurrent;
    if (releaseTag == null) return AppUpdateStatus.unreachable;
    final latest = SemanticVersion.tryParse(releaseTag);
    if (latest == null) return AppUpdateStatus.unreachable;
    if (latest.isNewerThan(current)) return AppUpdateStatus.updateAvailable;
    return AppUpdateStatus.upToDate;
  }

  /// Parses `1.2.3`, `1.0.0-rc.1` and the like, optionally with a leading `v`
  /// and a `+4` build suffix. The build suffix is dropped for comparison
  /// because it tracks the ABI, not a user-visible release. Returns null when
  /// the release identifier cannot be read.
  static SemanticVersion? parseVersion(String raw) =>
      SemanticVersion.tryParse(raw);
}

/// A version without a build suffix, per semantic versioning 2.0.0.
///
/// Ordering follows the spec: the core is compared numerically, a prerelease
/// is lower than the same release (`1.0.0-rc.1 < 1.0.0`), and prerelease
/// identifiers compare numeric-below-alphanumeric, ASCII-lexically otherwise.
class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion(
    this.major,
    this.minor,
    this.patch, [
    this.prerelease = const [],
  ]);

  final int major;
  final int minor;
  final int patch;

  /// The dot-separated identifiers after `-`, empty for a release.
  final List<String> prerelease;

  bool get isPrerelease => prerelease.isNotEmpty;

  bool isNewerThan(SemanticVersion other) => compareTo(other) > 0;

  @override
  int compareTo(SemanticVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    final a = prerelease, b = other.prerelease;
    if (a.isEmpty && b.isEmpty) return 0;
    // A release outranks any of its prereleases.
    if (a.isEmpty) return 1;
    if (b.isEmpty) return -1;
    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shared; i++) {
      final cmp = _compareIdentifiers(a[i], b[i]);
      if (cmp != 0) return cmp;
    }
    return a.length.compareTo(b.length);
  }

  static int _compareIdentifiers(String a, String b) {
    final aNum = _isNumeric(a), bNum = _isNumeric(b);
    if (aNum && bNum) {
      // Ids can in theory exceed int range; in practice they don't, and the
      // length check keeps them ordered if one ever did.
      if (a.length != b.length) return a.length.compareTo(b.length);
      return a.compareTo(b);
    }
    if (aNum) return -1; // numeric identifiers are lower than alphanumeric
    if (bNum) return 1;
    // ASCII ordering == UTF-16 code unit ordering for these characters.
    return a.compareTo(b);
  }

  static bool _isNumeric(String id) => RegExp(r'^[0-9]+$').hasMatch(id);

  static final _identifier = RegExp(r'^[0-9A-Za-z-]+$');

  static SemanticVersion? tryParse(String raw) {
    var cleaned = raw.trim().replaceFirst(RegExp(r'^v'), '');
    // Build metadata is dropped: it must not influence precedence.
    final noBuild = cleaned.split('+').first;
    final dash = noBuild.indexOf('-');
    final core = dash == -1 ? noBuild : noBuild.substring(0, dash);
    final preRaw = dash == -1 ? '' : noBuild.substring(dash + 1);

    final parts = core.split('.');
    if (parts.length < 2 || parts.length > 3) return null;
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = parts.length >= 3 ? int.tryParse(parts[2]) : 0;
    if (major == null || minor == null || patch == null) return null;
    if (major < 0 || minor < 0 || patch < 0) return null;

    final pre = <String>[];
    if (dash != -1) {
      if (preRaw.isEmpty) return null;
      for (final id in preRaw.split('.')) {
        if (id.isEmpty || !_identifier.hasMatch(id)) return null;
        // Numeric identifiers must not carry leading zeroes (spec §2).
        if (_isNumeric(id) && id.length > 1 && id.startsWith('0')) {
          return null;
        }
        pre.add(id);
      }
    }
    return SemanticVersion(major, minor, patch, List.unmodifiable(pre));
  }

  @override
  bool operator ==(Object other) =>
      other is SemanticVersion &&
      compareTo(other) == 0 &&
      _samePrerelease(other);

  bool _samePrerelease(SemanticVersion other) {
    if (prerelease.length != other.prerelease.length) return false;
    for (var i = 0; i < prerelease.length; i++) {
      if (prerelease[i] != other.prerelease[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(prerelease));

  @override
  String toString() => prerelease.isEmpty
      ? '$major.$minor.$patch'
      : '$major.$minor.$patch-${prerelease.join('.')}';
}

/// A parsed GitHub release with a ready-to-display version.
class GitHubRelease {
  const GitHubRelease({
    required this.version,
    required this.tag,
    this.prerelease = false,
  });

  final SemanticVersion version;
  final String tag;

  /// True when the release is marked as a pre-release on GitHub.
  final bool prerelease;

  String get url => 'https://github.com/ibro-3/ytdlp/releases/tag/$tag';
}
