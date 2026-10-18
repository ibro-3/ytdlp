import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/utils/formatters.dart';
import 'redirect_policy.dart';
import 'ytdlp_service.dart';

/// Downloads a release asset into place, verifying it before it is trusted.
///
/// Split out of `BinaryManager` so the transfer itself can be tested: it needs
/// a server to serve it, and the manager would need a support directory, a
/// platform channel and a filesystem to exercise it.
///
/// The guarantees, in the order they apply:
///
/// - bytes land in a temp file and are only renamed over [target] once the
///   transfer finished and validated, so a failure never destroys the engine
///   that is currently running;
/// - the transfer is capped and stalled-bound while the bytes stream, so a
///   redirect into an unbounded body cannot fill the disk first;
/// - when [expectedSha256] is given, the bytes must hash to it — stronger than
///   any size heuristic, and what stops a corrupt or substituted transfer from
///   being made executable.
class AssetDownloader {
  AssetDownloader({
    this.maxBytes = defaultMaxBytes,
    this.connectionTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
    this.redirectPolicy = githubReleaseRedirects,
  });

  /// The largest official build shipped for any platform is the macOS one at
  /// ~37 MB. A ceiling generously above that still stops a truncated-but-huge
  /// transfer, or a link that never ends, from writing the disk full before the
  /// rename below happens.
  static const int defaultMaxBytes = 64 * 1024 * 1024;

  /// Ceiling on the body, counted while it streams.
  final int maxBytes;

  /// Bound on the connect.
  final Duration connectionTimeout;

  /// Bound on a stalled transfer.
  ///
  /// `connectionTimeout` only covers the connect. A socket that is open but
  /// stops sending (a captive portal, a half-dead link) would otherwise hold
  /// the transfer open for ever — and despite the name, `HttpClient`'s own
  /// `idleTimeout` does *not* do that: it closes pooled connections, not one
  /// mid-transfer. So the gap between chunks is timed here, and a response
  /// that goes quiet for more than this is abandoned.
  final Duration idleTimeout;

  /// Bound on the whole transfer.
  ///
  /// A slow-but-alive source could keep the idle bound fed forever with a
  /// drip every 59 seconds; a deadline on the whole body is the second half
  /// of the same guarantee. `maxBytes` at dial speed is still minutes, which
  /// is why this is generous rather than tight.
  final Duration totalTimeout = const Duration(minutes: 10);

  /// Which hosts a redirect may point at.
  ///
  /// `HttpClient` follows redirects on its own by default; the transfer opts
  /// out and follows them by hand so every hop is checked. See
  /// [RedirectPolicy].
  final RedirectPolicy redirectPolicy;

  /// Downloads [url] to [target] atomically. Returns false — leaving [target]
  /// untouched — on any failure.
  ///
  /// [expectedSha256] is the digest the bytes must hash to, when the caller
  /// knows one. [minBytes] is the fallback sanity bound used only when there is
  /// no digest to check against: a real build is megabytes, and the next step
  /// after this is to make the file executable.
  Future<bool> download(
    String url,
    File target, {
    String? expectedSha256,
    int minBytes = 0,
  }) async {
    if (kIsWeb) return false;
    final tmp = File('${target.path}.tmp');
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = connectionTimeout
        ..idleTimeout = idleTimeout;
      // Walked by hand in `_open` so every hop can be host-checked; see
      // [redirectPolicy].
      final res = await _open(client, Uri.parse(url));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw YtdlpException('HTTP ${res.statusCode} from $url');
      }
      await target.parent.create(recursive: true);
      if (tmp.existsSync()) tmp.deleteSync();
      final sink = tmp.openWrite();
      // Hashed and counted as the bytes arrive, so a transfer that is going to
      // be thrown away never finishes writing.
      final digest = _DigestCollector();
      final hasher = sha256.startChunkedConversion(digest);
      var received = 0;
      // Total bound, checked between chunks rather than by wrapping the loop
      // in a timeout: a completion-side timeout would strand the loop still
      // running with no listener, pouring further bytes into a closed sink as
      // unhandled async errors. Between-chunks bounded by the idle bound, the
      // worst case overhead here is one more idle window.
      final watch = Stopwatch()..start();
      try {
        await for (final chunk in res.timeout(
          idleTimeout,
          onTimeout: (sink) => sink.addError(
            YtdlpException(
              'The download stalled: the server stopped sending after '
              '$received bytes and the transfer was stopped. '
              'Try again, or check the connection.',
            ),
          ),
        )) {
          if (watch.elapsed > totalTimeout) {
            throw YtdlpException(
              'The download took longer than '
              '${totalTimeout.inMinutes} minutes and was stopped.',
            );
          }
          received += chunk.length;
          if (received > maxBytes) {
            throw YtdlpException(
              'Downloaded $url grew past ${formatBytes(maxBytes)} and was '
              'stopped.',
            );
          }
          hasher.add(chunk);
          sink.add(chunk);
        }
        hasher.close();
        await sink.close();
      } catch (_) {
        // Release the handle before giving up: on Windows the temp file stays
        // locked until the sink is closed, and a locked temp file is a temp
        // file the next attempt cannot delete.
        await sink.close().catchError((Object _) {});
        rethrow;
      }
      if (received == 0) {
        throw const YtdlpException('Downloaded file is empty.');
      }
      final actual = digest.digests.single.toString();
      if (expectedSha256 != null) {
        if (actual != expectedSha256.toLowerCase()) {
          throw YtdlpException(
            'Downloaded file does not match the checksum published for it, so '
            'it was discarded.',
          );
        }
      } else if (received < minBytes) {
        throw YtdlpException(
          'Downloaded file is only $received bytes, which cannot be a build.',
        );
      }
      await replaceWith(tmp, target);
      return true;
    } catch (e) {
      try {
        await tmp.delete();
      } catch (_) {}
      // Surfaced rather than swallowed. Every caller turns a `false` here into
      // "yt-dlp was not found", so a 503 or an empty body was reported to the
      // user as a missing install — pointing them at a system package that was
      // never the problem.
      lastError = e is YtdlpException ? e.message : e.toString();
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// Opens [url], following redirects by hand up to the policy's limit.
  ///
  /// Each hop is host-checked before it is requested, so a redirect cannot hand
  /// the download to a host outside [redirectPolicy].
  Future<HttpClientResponse> _open(HttpClient client, Uri url) async {
    var current = url;
    for (var hop = 0; hop <= redirectPolicy.maxRedirects; hop++) {
      final req = await client.getUrl(current);
      // Resolved by `_open` so every hop can be checked.
      req.followRedirects = false;
      final res = await req
          // Listened via catchError rather than a bare await: the socket can
          // be torn down behind this wait (the caller closes the client in a
          // `finally`), and an unlistened future would then complete with an
          // error nothing handled.
          .close()
          .catchError(
            (Object _, StackTrace _) =>
                throw YtdlpException('Could not reach $current.'),
          )
          // The wait for response headers is bounded too: a server that
          // accepts the connection but never answers would otherwise hang
          // past every timeout dart:io has for it.
          .timeout(
            idleTimeout,
            onTimeout: () =>
                throw YtdlpException('The server did not reply in time.'),
          );
      if (!isRedirectStatus(res.statusCode)) return res;
      final location = res.headers.value(HttpHeaders.locationHeader);
      if (location == null) {
        throw RedirectException(
          'The server asked for a redirect but did not say where '
          '(HTTP ${res.statusCode}).',
        );
      }
      // Release the socket before opening the next hop. Staged: an unbounded
      // redirect body would hang an undrained read for ever, and abandoning
      // the hop is all that matters here — the finally force-closes the
      // client regardless.
      await res.drain<void>().timeout(idleTimeout, onTimeout: () {});
      current = redirectPolicy.resolve(current, location);
    }
    throw const RedirectException('Too many redirects while downloading.');
  }

  /// The digest a `SHA2-256SUMS` index lists for [asset], or null when the
  /// index does not list it.
  ///
  /// Public and static because parsing the index is the part that has to be
  /// exactly right and is checkable without a network: the format is
  /// `<sha256>  <filename>` — hex, whitespace, an optional `*` marker that GNU
  /// sha256sum uses for binary mode, then the name.
  static String? digestFromSums(String sums, String asset) {
    final entry = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$');
    for (final line in const LineSplitter().convert(sums)) {
      final match = entry.firstMatch(line.trim());
      if (match == null) continue;
      if (match.group(2) == asset) return match.group(1)!.toLowerCase();
    }
    return null;
  }

  /// Why the last [download] failed, or null if it has not failed.
  String? lastError;

  /// Renames [src] over [dst]. On failure the previous file (if any) is
  /// preserved via a backup rename, so a download that lands half-way through
  /// cannot leave the app without the engine it had.
  Future<void> replaceWith(File src, File dst) async {
    // `File.exists()` is false for a directory, which would send a directory
    // down the "nothing is there yet" path and fail later with a bare EISDIR.
    // Anything that is not a file is refused up front, with the reason.
    final stat = await FileStat.stat(dst.path);
    final type = stat.type;
    if (type == FileSystemEntityType.directory) {
      throw FileSystemException(
        'Cannot replace a directory with a file',
        dst.path,
      );
    }
    final existed = type != FileSystemEntityType.notFound;
    if (!existed) {
      await src.rename(dst.path);
      return;
    }
    final backup = File('${dst.path}.bak');
    if (backup.existsSync()) backup.deleteSync();
    try {
      await dst.rename(backup.path);
    } catch (_) {
      // Destination may be open/locked — keep going with the backup dance.
    }
    try {
      await src.rename(dst.path);
      try {
        if (backup.existsSync()) backup.deleteSync();
      } catch (_) {}
    } catch (_) {
      // Revert: put the previous binary back.
      try {
        if (backup.existsSync()) await backup.rename(dst.path);
      } catch (_) {}
      rethrow;
    }
  }
}

/// Collects the digests a chunked hash conversion produces.
///
/// `crypto`'s chunked API wants a [Sink] to push into; this is the smallest
/// one that keeps what it was given, so the caller can read the single digest
/// out after [close].
class _DigestCollector implements Sink<Digest> {
  final List<Digest> digests = <Digest>[];

  @override
  void add(Digest data) => digests.add(data);

  @override
  void close() {}
}
