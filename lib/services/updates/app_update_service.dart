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

  /// Compares the running app's version (from the platform) against the newest
  /// tag on GitHub.
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
    // Compare via the pure table, which also handles a missing/unparseable
    // version where the UI would rather say so than guess.
    final latest = await _fetchLatest();
    final tag = latest?.tag;
    return AppUpdateResult(AppUpdater.compare(tag, version), release: latest);
  }

  Future<GitHubRelease?> _fetchLatest() async {
    const url = 'https://api.github.com/repos/ibro-3/ytdlp/releases/latest';
    final https = http;
    final body = https != null
        ? await https(Uri.parse(url), 200)
        : await _defaultGet(url);
    if (body == null) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String?;
      if (tag == null) return null;
      final version = _parseVersion(tag);
      if (version == null) return null;
      return GitHubRelease(version: version, tag: tag);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _defaultGet(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) return null;
      return await utf8.decodeStream(res);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// Pure comparison: given the release tag GitHub reports and the running
  /// version, what should the UI say?
  ///
  /// Public so tests (and the diagnostics report) can assert the decision
  /// table directly, without going through [PackageInfo] or the network.
  static AppUpdateStatus compare(String? releaseTag, String currentVersion) {
    final current = _parseVersion(currentVersion);
    if (current == null) return AppUpdateStatus.unknownCurrent;
    if (releaseTag == null) return AppUpdateStatus.unreachable;
    final latest = _parseVersion(releaseTag);
    if (latest == null) return AppUpdateStatus.unreachable;
    if (latest.isNewerThan(current)) return AppUpdateStatus.updateAvailable;
    return AppUpdateStatus.upToDate;
  }

  /// Parses `1.2.3`, optionally with a leading `v` and a `+4` build suffix.
  /// The build suffix is dropped for comparison because it tracks the ABI, not
  /// a user-visible release.
  static SemanticVersion? parseVersion(String raw) => _parseVersion(raw);

  static SemanticVersion? _parseVersion(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^v'), '');
    final withoutBuild = cleaned.split('+').first;
    final parts = withoutBuild.split('.');
    if (parts.length < 2) return null;
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = parts.length >= 3 ? int.tryParse(parts[2]) : 0;
    if (major == null || minor == null || patch == null) return null;
    return SemanticVersion(major, minor, patch);
  }
}

/// A three-part version without a build suffix.
class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  bool isNewerThan(SemanticVersion other) => compareTo(other) > 0;

  @override
  int compareTo(SemanticVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is SemanticVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// A parsed GitHub release tag with a ready-to-display version.
class GitHubRelease {
  const GitHubRelease({required this.version, required this.tag});

  final SemanticVersion version;
  final String tag;

  String get url => 'https://github.com/ibro-3/ytdlp/releases/tag/$tag';
}
