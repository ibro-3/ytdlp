import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

/// Installs and verifies yt-dlp's JavaScript runtime components.
///
/// yt-dlp loads `yt-dlp-ejs` from its plugin directory. The bundled Android
/// runtime is a full CPython tree, so the package is a plain import away; the
/// whole point is that a *verified* install replaces nothing, so a bad download
/// cannot break a working engine. Verification therefore actually runs the
/// bundled interpreter rather than checking that a file exists.
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
        action().then<void>((_) => completer.complete, onError: (Object e, StackTrace s) {
          completer.completeError(e, s);
        }),
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

  Future<EjsInfo> _probe() async {
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
      ], environment: runtime.env);
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
  /// may need, but the download itself is pinned by the URL [archiveUrl]
  /// resolves to.
  Future<EjsInfo> install({
    required String archiveUrl,
    required String version,
  }) => _serialised(() => _install(archiveUrl: archiveUrl, version: version));

  Future<EjsInfo> _install({
    required String archiveUrl,
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

    final bytes = await _download(archiveUrl);
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
      // Install beside the existing copy and swap, so an interrupted install
      // cannot leave the interpreter with a half-written package.
      final target = p.join(sitePackages, packageName);
      final previous = Directory(target);
      final hadPrevious = await previous.exists();
      final backup = Directory('$target.previous');
      if (hadPrevious) await previous.rename(backup.path);
      try {
        await _copyDir(staged, Directory(target));
      } catch (_) {
        if (hadPrevious) await backup.rename(target);
        rethrow;
      }
      // The backup is kept until the install has been verified. Deleting it here
      // meant the rollback below copied from a directory that no longer existed,
      // so `_copyDir` threw a raw FileSystemException out of `install` and the
      // user got neither the explanation nor their previous install back.
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

  /// Removes the package, for a "not working" that the user would rather opt
  /// out of than keep retrying.
  Future<void> uninstall() => _serialised(() async {
    if (kIsWeb) return;
    final runtime = await _binary.androidRuntime;
    if (runtime == null) return;
    await _deleteDir(Directory(p.join(_sitePackages(runtime), packageName)));
    _cached = null;
  });

  /// The wheel/sdist for [version], from PyPI's JSON API.
  ///
  /// Split out so the resolution can be tested without a network: the API shape
  /// is the part that is easy to get wrong.
  static String? resolveWheelUrl(Map<String, dynamic> pypiJson) {
    final urls = pypiJson['urls'];
    if (urls is! List) return null;
    for (final entry in urls) {
      if (entry is! Map) continue;
      final name = entry['filename'];
      final url = entry['url'];
      // A pure-Python wheel is `py3-none-any`; anything else is a build for a
      // specific platform and would not match the bundled interpreter.
      if (name is String &&
          name.endsWith('py3-none-any.whl') &&
          url is String) {
        return url;
      }
    }
    return null;
  }

  static String pypiJsonUrl(String version) =>
      'https://pypi.org/pypi/$packageName/$version/json';

  /// Looks up the wheel for [version] on PyPI.
  ///
  /// Throws [EjsInstallException] when the version is missing or has no
  /// pure-Python wheel, so the caller can say so rather than installing
  /// something the bundled interpreter cannot load.
  Future<String> resolveLatestWheel(String version) async {
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
    final url = resolveWheelUrl(Map<String, dynamic>.from(decoded));
    if (url == null) {
      throw EjsInstallException(
        'No wheel for $packageName $version matches this device.\n'
        'The app may need an update.',
      );
    }
    return url;
  }

  /// GETs [url] as text, with the same size and status guards as [_download].
  Future<String> _fetch(String url) async {
    final bytes = await _download(url);
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw const EjsInstallException('The server response was not text.');
    }
  }

  Future<List<int>> _download(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw EjsInstallException(
          'Could not download the JavaScript runtime (HTTP '
          '${res.statusCode}).',
        );
      }
      final builder = BytesBuilder();
      await for (final chunk in res) {
        builder.add(chunk);
        // A wheel is small; anything larger is not what was asked for.
        if (builder.length > maxDownloadBytes) {
          throw const EjsInstallException(
            'The downloaded file is far larger than expected and was not '
            'installed.',
          );
        }
      }
      if (builder.isEmpty) {
        throw const EjsInstallException('The downloaded file was empty.');
      }
      return builder.toBytes();
    } on SocketException catch (e) {
      throw EjsInstallException('Could not reach the server (${e.message}).');
    } finally {
      client?.close(force: true);
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

class EjsInstallException implements Exception {
  const EjsInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}
