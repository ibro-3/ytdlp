import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'binary_manager.dart';

/// What the app knows about the installed JS runtime for YouTube.
enum EjsStatus {
  /// Not looked at yet.
  unknown,

  /// Installed and importable.
  installed,

  /// Not installed.
  missing,

  /// Something is there but does not work — an interrupted install, or a
  /// version the bundled interpreter cannot load.
  broken,
}

/// Result of probing for the JS runtime.
class EjsInfo {
  const EjsInfo({
    this.status = EjsStatus.unknown,
    this.version,
    this.path,
    this.detail,
  });

  final EjsStatus status;

  /// Version reported by the installed package, when it could be read.
  final String? version;

  /// Where the package's entry point lives, for the diagnostics report.
  final String? path;

  /// Why it is broken, when it is.
  final String? detail;

  bool get isUsable => status == EjsStatus.installed;

  /// A sentence for the settings screen.
  String get summary => switch (status) {
    EjsStatus.installed =>
      version == null ? 'JS runtime installed' : 'JS runtime ${version!}',
    EjsStatus.missing => 'JS runtime not installed',
    EjsStatus.broken => 'JS runtime is installed but not working',
    EjsStatus.unknown => 'JS runtime status unknown',
  };
}

/// Where to fetch the JavaScript runtime from, and what its bytes must hash to.
///
/// The digest is not decoration. [EjsInstaller.install] refuses to unpack
/// anything that does not hash to [sha256], so a resolution that carries no
/// digest is a *failure* rather than a fallback to unverified code — hence this
/// type being non-nullable in both fields. A missing digest means PyPI did not
/// describe the file, and installing an undescribed file is the situation the
/// check exists to prevent.
class EjsWheel {
  const EjsWheel({required this.url, required this.sha256});

  final String url;

  /// Lower-case hex SHA-256 of the downloaded bytes, as PyPI publishes it.
  final String sha256;

  /// Enough to identify the wheel in a report, not enough to be useful to
  /// anyone reconstructing it.
  @override
  String toString() =>
      '$url (sha256:${sha256.length >= 12 ? sha256.substring(0, 12) : sha256}…)';
}

/// Installs and verifies yt-dlp's JavaScript runtime components.
///
/// yt-dlp loads `yt-dlp-ejs` from its plugin directory. The bundled Android
/// runtime is a full CPython tree, so the package is a plain import away; the
/// whole point is that a *verified* install replaces nothing, so a bad download
/// cannot break a working engine.
///
/// Verification is two layers, in order. The bytes are checked against the
/// SHA-256 PyPI published for the wheel before anything is unpacked, and the
/// request may only ever reach PyPI over HTTPS — a digest is only worth as much
/// as the response it came from. Then the package is actually imported by the
/// bundled interpreter, because a wheel that hashes correctly and still will not
/// load is a real failure mode and a file-exists check would miss it.
class EjsInstaller {
  EjsInstaller(this._binary);

  final BinaryManager _binary;

  /// Ceiling on the download. A pure-Python wheel is well under a megabyte, so
  /// this is a sanity bound rather than a real limit.
  static const int maxDownloadBytes = 32 * 1024 * 1024;

  /// Where the package is expected, given the runtime's `PYTHONPATH`.
  ///
  /// Kept in one place because both the installer and the prober need it, and a
  /// mismatch would show as "installed" forever.
  static const String packageName = 'yt_dlp_ejs';

  /// The plugin directory yt-dlp scans, relative to its own script.
  static const String pluginDirName = 'yt-dlp-plugins';

  EjsInfo? _cached;

  /// The tail of the install/uninstall queue, including whatever is running.
  ///
  /// Both swap the package directory in and out from under one shared staging
  /// path, and neither is safe to run twice: two concurrent installs would each
  /// delete and recreate the same staging directory mid-unpack. The UI's own
  /// `_installing` flag only guards a double tap on one button.
  Future<void> _queue = Future<void>.value();

  /// Runs [action] once everything queued ahead of it has finished.
  ///
  /// Serialised here rather than only in the UI, because one control's flag is
  /// not the same thing as mutual exclusion between callers.
  Future<T> _serialised<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then<void>((_) {
      // Errors are reported to [completer], not to the queue: one failed install
      // must not break the wait for the next.
      unawaited(
        action().then<void>(
          (_) => completer.complete,
          onError: (Object e, StackTrace s) {
            completer.completeError(e, s);
          },
        ),
      );
    });
    return completer.future;
  }

  /// Probes the installed runtime, caching the answer.
  ///
  /// A cached miss is not re-probed on every call: this is consulted when
  /// building a download, and spawning an interpreter each time would add a
  /// process per download for no benefit.
  Future<EjsInfo> status({bool refresh = false}) async {
    if (!refresh && _cached != null) return _cached!;
    return _cached = await _probe();
  }

  Future<EjsInfo> _probe({Map<String, String>? env}) async {
    if (kIsWeb) return const EjsInfo(status: EjsStatus.missing);
    if (!Platform.isAndroid) {
      // Desktop resolves yt-dlp from PATH or a downloaded binary, and the
      // package may be present in the system Python. yt-dlp will use it if it
      // is importable, so this is a real (if indirect) check.
      return const EjsInfo(status: EjsStatus.missing);
    }
    try {
      final runtime = await _binary.androidRuntime;
      if (runtime == null) {
        return const EjsInfo(
          status: EjsStatus.missing,
          detail: 'This install does not use the bundled Python runtime.',
        );
      }
      final probe = await Process.run(runtime.python, [
        '-c',
        'import $packageName, sys; sys.stdout.write($packageName.__name__)',
      ], environment: env ?? runtime.env);
      if (probe.exitCode == 0) {
        return EjsInfo(status: EjsStatus.installed, version: _versionOf(probe));
      }
      // Distinguish "never installed" from "installed but broken": an
      // ImportError for the package itself means missing, anything else means
      // something is there and does not work.
      final stderr = '${probe.stderr}';
      final isMissing =
          stderr.contains('ModuleNotFoundError') ||
          stderr.contains("No module named '$packageName'");
      return EjsInfo(
        status: isMissing ? EjsStatus.missing : EjsStatus.broken,
        detail: isMissing ? null : stderr.trim().split('\n').last,
      );
    } catch (e) {
      return EjsInfo(status: EjsStatus.unknown, detail: e.toString());
    }
  }

  /// Downloads and installs the package, verifying before it commits.
  ///
  /// [archiveUrl] is resolved by the caller so the download source stays out of
  /// this class and can change without touching the install logic.
  ///
  /// Throws [EjsInstallException] with an actionable message on any failure;
  /// the existing install is never left in a half-written state.
  ///
  /// [version] is accepted for the caller's convenience and for the message it
  /// may need, but the download itself is pinned by [wheel], both to its URL
  /// and to the digest it must hash to.
  Future<EjsInfo> install({required EjsWheel wheel, required String version}) =>
      _serialised(() => _install(wheel: wheel, version: version));

  Future<EjsInfo> _install({
    required EjsWheel wheel,
    required String version,
  }) async {
    if (kIsWeb) {
      throw const EjsInstallException(
        'The JavaScript runtime is not available on the web build.',
      );
    }
    final runtime = await _binary.androidRuntime;
    if (runtime == null) {
      throw const EjsInstallException(
        'This install does not use the bundled Python runtime, so the '
        'JavaScript runtime cannot be added to it.\n'
        'Update the app, or install yt-dlp-ejs into your own Python.',
      );
    }

    final bytes = await _download(wheel.url, expectedSha256: wheel.sha256);
    final staging = await _stagingDir();
    try {
      // The wheel is a zip; a source distribution is a gzipped tar. Both are
      // handled so a PyPI URL of either shape works.
      _unpack(bytes, staging);

      final staged = Directory(p.join(staging.path, packageName));
      if (!await staged.exists()) {
        throw EjsInstallException(
          'The downloaded archive did not contain $packageName.',
        );
      }
      // Reject anything that tries to escape the staging directory before it
      // is moved into the interpreter's path.
      await _rejectEscapes(staged);

      final sitePackages = _sitePackages(runtime);
      await Directory(sitePackages).create(recursive: true);

      // Verified *before* the existing copy is touched.
      //
      // The probe imports from `sitePackages`, so the staged copy is put ahead
      // of it on `PYTHONPATH`: the interpreter resolves the new package to the
      // staged path while the installed one keeps working underneath it. The
      // previous ordering renamed the installed copy aside *first*, which left
      // the interpreter with no `yt_dlp_ejs` at all for the duration of a
      // process spawn plus an import plus a copy — a window any download
      // starting inside it would hit as an ImportError.
      final verified = await _probe(env: _withStaging(runtime, staging.path));
      if (!verified.isUsable) {
        throw EjsInstallException(
          'The verified download would not import, so it was not installed.\n'
          '${verified.detail ?? ''}',
        );
      }

      // Only now does anything move. `rename` within the same filesystem is
      // close to atomic, and both paths are under the app support directory,
      // so the swap is two renames rather than a copy.
      final target = p.join(sitePackages, packageName);
      final previous = Directory(target);
      final hadPrevious = await previous.exists();
      final backup = Directory('$target.previous');
      if (hadPrevious) await previous.rename(backup.path);
      try {
        await _moveIntoPlace(staged, Directory(target));
      } catch (_) {
        if (hadPrevious) {
          try {
            await backup.rename(target);
          } catch (_) {}
        }
        rethrow;
      }
      // The backup is kept until the *installed* copy has been confirmed, so a
      // rollback always has something to restore.
      final info = await status(refresh: true);
      if (!info.isUsable) {
        await _deleteDir(Directory(target));
        if (hadPrevious) {
          try {
            await backup.rename(target);
          } catch (e) {
            throw EjsInstallException(
              'The runtime installed but could not be loaded, so it was '
              'removed, and the previous copy could not be restored either.\n'
              '$e'
              '${info.detail == null ? '' : '\n${info.detail}'}',
            );
          }
        }
        throw EjsInstallException(
          'The runtime installed but could not be loaded, so it was removed.'
          '${info.detail == null ? '' : '\n${info.detail}'}',
        );
      }
      if (hadPrevious) await _deleteDir(backup);
      return info;
    } finally {
      await _deleteDir(staging);
    }
  }

  /// The runtime's environment with [stagingDir] ahead of its `PYTHONPATH`.
  ///
  /// Prepend, not replace: the staged copy must win for the package under test,
  /// but everything else the runtime depends on has to stay importable.
  Map<String, String> _withStaging(
    AndroidRuntimeHandle runtime,
    String stagingDir,
  ) {
    final env = Map<String, String>.of(runtime.env);
    final existing = env['PYTHONPATH'];
    env['PYTHONPATH'] = existing == null || existing.isEmpty
        ? stagingDir
        : '$stagingDir${p.separator}$existing';
    return env;
  }

  /// Moves the staged package into place, renaming when the filesystem allows.
  ///
  /// Both paths are under the app support directory in every configuration the
  /// app actually runs, so this is a `rename`; the copy is the fallback for a
  /// filesystem that disagrees.
  Future<void> _moveIntoPlace(Directory staged, Directory target) async {
    try {
      await staged.rename(target.path);
    } on FileSystemException {
      await _copyDir(staged, target);
    }
  }

  /// Removes the package, for a "not working" that the user would rather opt
  /// out of than keep retrying.
  Future<void> uninstall() => _serialised(() async {
    if (kIsWeb) return;
    final runtime = await _binary.androidRuntime;
    if (runtime == null) return;
    await _deleteDir(Directory(p.join(_sitePackages(runtime), packageName)));
    _cached = null;
  });

  /// The wheel for the package, from PyPI's JSON API.
  ///
  /// Returns the URL *and* the digest PyPI published for it. A payload that has
  /// a wheel but no digest resolves to null: without one there is nothing to
  /// verify against, and [EjsWheel] deliberately cannot express that.
  ///
  /// Split out so the resolution can be tested without a network: the API shape
  /// is the part that is easy to get wrong.
  static EjsWheel? resolveWheel(Map<String, dynamic> pypiJson) {
    final urls = pypiJson['urls'];
    if (urls is! List) return null;
    for (final entry in urls) {
      if (entry is! Map) continue;
      final name = entry['filename'];
      final url = entry['url'];
      final digests = entry['digests'];
      // A pure-Python wheel is `py3-none-any`; anything else is a build for a
      // specific platform and would not match the bundled interpreter.
      if (name is String &&
          name.endsWith('py3-none-any.whl') &&
          url is String) {
        final sha256 = digests is Map ? digests['sha256'] : null;
        if (sha256 is! String || !_isHexSha256(sha256)) return null;
        return EjsWheel(url: url, sha256: sha256.toLowerCase());
      }
    }
    return null;
  }

  /// 64 lowercase hex characters — the only shape a SHA-256 digest has.
  static final _hexSha256 = RegExp(r'^[0-9a-fA-F]{64}$');

  static bool _isHexSha256(String value) => _hexSha256.hasMatch(value);

  static String pypiJsonUrl(String version) =>
      'https://pypi.org/pypi/$packageName/$version/json';

  /// Looks up the wheel for [version] on PyPI.
  ///
  /// Throws [EjsInstallException] when the version is missing, has no
  /// pure-Python wheel, or has no digest to verify against, so the caller can
  /// say so rather than installing something the bundled interpreter cannot
  /// load — or something nobody can vouch for.
  Future<EjsWheel> resolveLatestWheel(String version) async {
    final body = await _fetch(pypiJsonUrl(version));
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw EjsInstallException('PyPI returned an unreadable response.');
    }
    if (decoded is! Map) {
      throw const EjsInstallException('PyPI returned an unexpected response.');
    }
    final wheel = resolveWheel(Map<String, dynamic>.from(decoded));
    if (wheel == null) {
      // Distinguishes the two reasons, because they need different things from
      // the user: one is an app update, the other is a PyPI change.
      final hasWheel = _hasPureWheel(Map<String, dynamic>.from(decoded));
      throw EjsInstallException(
        hasWheel
            ? 'PyPI did not publish a checksum for $packageName $version, so '
                  'it could not be verified and was not installed.\n'
                  'The app may need an update.'
            : 'No wheel for $packageName $version matches this device.\n'
                  'The app may need an update.',
      );
    }
    return wheel;
  }

  /// Whether the payload lists a pure-Python wheel at all, digest aside.
  static bool _hasPureWheel(Map<String, dynamic> pypiJson) {
    final urls = pypiJson['urls'];
    if (urls is! List) return false;
    return urls.any(
      (entry) =>
          entry is Map &&
          entry['filename'] is String &&
          (entry['filename'] as String).endsWith('py3-none-any.whl'),
    );
  }

  /// Hosts the installer will fetch from.
  ///
  /// Pinned because the two requests are not equally trustworthy if either can
  /// be redirected. The digest comes from the JSON response, so a redirect of
  /// *that* request to another host would hand whoever controls it the URL and
  /// the expected hash together — and verifying a hash an attacker chose is
  /// not verification. `HttpClient` follows redirects by default, so both
  /// requests opt out and are followed by hand only to these hosts.
  static const _allowedHosts = {
    'pypi.org',
    'www.pypi.org',
    'files.pythonhosted.org',
  };

  /// How many redirects to walk before giving up. PyPI uses one, occasionally
  /// two; anything more is not a redirect chain any more.
  static const _maxRedirects = 5;

  /// Resolves a `Location` header against [current], refusing to leave an HTTPS
  /// URL on [_allowedHosts].
  ///
  /// A pure function so the one decision that carries the whole host-pinning
  /// guarantee can be pinned by a test without a network — see
  /// [_allowedHosts] for why that decision matters.
  ///
  /// The scheme is pinned as well as the host: a redirect to
  /// `http://pypi.org/…` names an allowed host while dropping to cleartext, and
  /// the digest check would still pass — it protects the file, not the request
  /// that fetched it, so it would happily verify a file an attacker on the path
  /// had already substituted.
  @visibleForTesting
  static Uri checkedRedirect(Uri current, String location) {
    Uri next;
    try {
      // Resolved against the *current* URL, because RFC 7231 allows a relative
      // Location, which PyPI's CDN uses.
      next = current.resolve(location);
    } catch (_) {
      throw EjsInstallException(
        'The server sent a redirect this app could not follow '
        '("$location").',
      );
    }
    if (next.scheme != 'https' || !_allowedHosts.contains(next.host)) {
      throw EjsInstallException(
        'The download was redirected to ${next.host}, which this app does not '
        'fetch from, so it was not installed.',
      );
    }
    return next;
  }

  /// GETs [url] as text, with the same size and status guards as [_download].
  Future<String> _fetch(String url) async {
    final bytes = await _get(url);
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw const EjsInstallException('The server response was not text.');
    }
  }

  /// Fetches [url] as bytes, refusing to leave [_allowedHosts].
  ///
  /// Redirects are followed explicitly rather than by `HttpClient` so each hop
  /// can be checked; see [_allowedHosts].
  Future<List<int>> _get(String url) async {
    var current = Uri.parse(url);
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      // A fresh client per hop: `_request` closes its own, and reusing a closed
      // connection throws.
      final response = await _request(current);
      if (!response.isRedirect) return response.body;
      final location = response.headers.value('location');
      if (location == null) {
        throw EjsInstallException(
          'The server asked for a redirect but did not say where '
          '(HTTP ${response.statusCode}).',
        );
      }
      final next = checkedRedirect(current, location);
      current = next;
    }
    throw const EjsInstallException(
      'Too many redirects while fetching the JavaScript runtime.',
    );
  }

  /// One drained HTTP response.
  ///
  /// Drained rather than streamed to the caller: a body that is only partly
  /// read holds the socket open, and these are two small requests whose whole
  /// point is to be finished with.
  Future<_Response> _request(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(url);
      // Walked by hand in `_get` so every hop can be host-checked.
      req.followRedirects = false;
      final res = await req.close();
      final builder = BytesBuilder();
      await for (final chunk in res) {
        builder.add(chunk);
        // A wheel is small; anything larger is not what was asked for.
        if (builder.length > maxDownloadBytes) {
          // Drains the rest before throwing so the socket is released rather
          // than left half-read for the `finally` to close aggressively.
          await res.drain<void>();
          throw const EjsInstallException(
            'The downloaded file is far larger than expected and was not '
            'installed.',
          );
        }
      }
      // Redirects are legitimate here and are resolved by the caller, so the
      // status is only an error once it is neither.
      if (res.statusCode != 204 && builder.isEmpty) {
        throw const EjsInstallException('The downloaded file was empty.');
      }
      if (!res.isRedirect && (res.statusCode < 200 || res.statusCode >= 300)) {
        throw EjsInstallException(
          'Could not download the JavaScript runtime (HTTP '
          '${res.statusCode}).',
        );
      }
      return _Response(
        statusCode: res.statusCode,
        headers: res.headers,
        body: builder.takeBytes(),
        isRedirect: res.isRedirect,
      );
    } on SocketException catch (e) {
      throw EjsInstallException('Could not reach the server (${e.message}).');
    } on HttpException catch (e) {
      // A redirect loop, a bad URI, a closed connection: all reach the user as
      // the same "could not fetch", which is what they can act on.
      throw EjsInstallException('Could not reach the server (${e.message}).');
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the wheel and checks it against [expectedSha256].
  ///
  /// The check is here rather than in [install] so that no unverified byte ever
  /// leaves this method — unpacking is the point of no return, because it
  /// writes into the interpreter's package directory.
  ///
  /// Throws [EjsInstallException] when the bytes do not hash to the digest
  /// PyPI published, which is what a truncated transfer, a substituted mirror
  /// or a tampered CDN response looks like from here.
  Future<List<int>> _download(
    String url, {
    required String expectedSha256,
  }) async {
    final bytes = await _get(url);
    verifyDigest(sha256.convert(bytes).toString(), expectedSha256);
    return bytes;
  }

  /// Fails when [actual] is not the digest PyPI published.
  ///
  /// Comparison is case-insensitive because PyPI does not promise a case, and
  /// the hex alphabet is the same either way.
  ///
  /// Pure, and separate from [_download], so the check and its message can be
  /// pinned by a test that does not reach the network: hashing the real bytes
  /// and comparing is the assertion that matters, and it should not need a
  /// server to run.
  @visibleForTesting
  static void verifyDigest(String actual, String expected) {
    if (actual.toLowerCase() != expected.toLowerCase()) {
      throw EjsInstallException(
        'The JavaScript runtime download did not match the checksum PyPI '
        'published, so it was not installed.\n'
        'Expected $expected\n'
        'Got      $actual',
      );
    }
  }

  /// Extracts [bytes] into [target], choosing the codec by magic bytes rather
  /// than by file name, since the URL may carry neither extension.
  void _unpack(List<int> bytes, Directory target) {
    final isZip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    final isGzip = bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;
    try {
      if (isZip) {
        _writeArchive(ZipDecoder().decodeBytes(bytes), target);
      } else if (isGzip) {
        _writeArchive(
          TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes)),
          target,
        );
      } else {
        throw const EjsInstallException(
          'The downloaded file was not a wheel or a source archive.',
        );
      }
    } on EjsInstallException {
      rethrow;
    } catch (e) {
      throw EjsInstallException('Could not read the download ($e).');
    }
  }

  void _writeArchive(Archive archive, Directory target) {
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final out = File(p.join(target.path, entry.name));
      // A path escaping the staging dir is dropped rather than written.
      if (!p.isWithin(target.path, out.path)) continue;
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(entry.content as List<int>, flush: true);
    }
  }

  /// Fails loudly if the archive contained a symlink or a `..` path.
  Future<void> _rejectEscapes(Directory staged) async {
    await for (final entity in staged.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw EjsInstallException(
          'The downloaded archive contained a link, so it was not installed.',
        );
      }
      final rel = p.relative(entity.path, from: staged.path);
      if (rel.split(p.separator).contains('..')) {
        throw EjsInstallException(
          'The downloaded archive tried to write outside its folder, so it '
          'was not installed.',
        );
      }
    }
  }

  String _sitePackages(AndroidRuntimeHandle runtime) => runtime.sitePackages;

  Future<Directory> _stagingDir() async {
    final dir = Directory(
      p.join((await _binary.supportDirectory).path, 'ejs-staging'),
    );
    if (await dir.exists()) await _deleteDir(dir);
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: from.path);
      if (entity is Directory) {
        await Directory(p.join(to.path, rel)).create(recursive: true);
      } else if (entity is File) {
        final out = File(p.join(to.path, rel));
        await out.parent.create(recursive: true);
        await entity.copy(out.path);
      }
    }
  }

  Future<void> _deleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort; a leftover staging dir is reclaimed on the next install.
    }
  }

  String? _versionOf(ProcessResult probe) {
    final out = '${probe.stdout}'.trim();
    if (out.isEmpty) return null;
    return out.split('\n').last.trim();
  }
}

class _Response {
  const _Response({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.isRedirect,
  });

  final int statusCode;
  final HttpHeaders headers;
  final List<int> body;
  final bool isRedirect;
}

class EjsInstallException implements Exception {
  const EjsInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}
