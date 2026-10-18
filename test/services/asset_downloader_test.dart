import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/asset_downloader.dart';

/// Serves [body] on a loopback port and tears the server down with the test.
///
/// A real local server is the only way to exercise the transfer: the code
/// under test opens an `HttpClient`, and a fake would only prove that the
/// bytes were written, not that they were verified, capped and installed.
class _Server {
  _Server._(this._server, this.body);

  final HttpServer _server;
  final List<int> body;

  String get url => 'http://127.0.0.1:${_server.port}/asset';

  static Future<_Server> start(
    List<int> body, {
    int status = 200,
    String? location,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = status;
      if (location != null) {
        req.response.headers.set(HttpHeaders.locationHeader, location);
      }
      req.response.add(body);
      await req.response.close();
    });
    return _Server._(server, body);
  }

  /// A server that sends one byte and then never finishes, closing nothing.
  ///
  /// This is the captive-portal shape the bounds exist for — and
  /// importantly, it is one `HttpClient.idleTimeout` does *not* rescue: the
  /// pooled-connection idle timeout only closes connections sitting in its
  /// pool, not a transfer whose last bytes are ages old.
  static Future<_Server> startStalled() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.add([0x41]);
      await req.response.flush();
      // Never closed. The server dies with the test.
      await Completer<void>().future;
    });
    return _Server._(server, const []);
  }

  Future<void> close() => _server.close(force: true);
}

const _payload = 'not a real yt-dlp, but a deterministic body';

/// Idle bound short enough that the stall test yields quickly; the real
/// default is a minute.
const _shortIdle = Duration(milliseconds: 400);
final _payloadBytes = utf8.encode(_payload);
final _payloadSha = sha256.convert(_payloadBytes).toString();

void main() {
  group('digestFromSums', () {
    // The shape GitHub actually publishes: "<sha256>  <filename>".
    const index = '''
1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  yt-dlp
66674953fe251b89f4d08c5f035e0728679bd67ab3d7d05c0562af101dd3e7a  yt-dlp.exe
0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos
''';

    test('returns the digest listed for the asset', () {
      expect(
        AssetDownloader.digestFromSums(index, 'yt-dlp'),
        '1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6',
      );
      expect(
        AssetDownloader.digestFromSums(index, 'yt-dlp_macos'),
        '0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202',
      );
    });

    test('returns null for an asset the index does not list', () {
      expect(AssetDownloader.digestFromSums(index, 'yt-dlp_linux'), isNull);
    });

    test('ignores lines that are not index entries', () {
      const noisy = 'not a sums file\n\n$index';
      expect(
        AssetDownloader.digestFromSums(noisy, 'yt-dlp'),
        '1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6',
      );
    });

    test('accepts the binary-mode marker GNU sha256sum adds', () {
      const marked =
          '1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6 *yt-dlp\n';
      expect(
        AssetDownloader.digestFromSums(marked, 'yt-dlp'),
        '1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6',
      );
    });
  });

  group('download', () {
    test('a stalled transfer is abandoned by the idle bound', () async {
      // The regression this guards: the connect timeout only covers the
      // connect, and `HttpClient.idleTimeout` closes pooled connections but
      // not a transfer that has stopped moving — so a socket that was open
      // but never finished held the whole install open for ever.
      final server = await _Server.startStalled();
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');

      final downloader = AssetDownloader(idleTimeout: _shortIdle);
      final watch = Stopwatch()..start();
      final ok = await downloader.download(server.url, target);
      watch.stop();

      expect(ok, isFalse, reason: 'the stalled transfer reports its failure');
      expect(downloader.lastError, isNotNull);
      expect(target.existsSync(), isFalse);
      // The bounds, not the test's own patience, ended this: the idle window
      // plus some slack rather than the forever it used to take.
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('installs a body that hashes to the expected digest', () async {
      final server = await _Server.start(_payloadBytes);
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');

      final ok = await AssetDownloader().download(
        server.url,
        target,
        expectedSha256: _payloadSha,
      );

      expect(ok, isTrue);
      expect(target.readAsStringSync(), _payload);
      // The temp file is renamed away, not left beside the engine.
      expect(File('${target.path}.tmp').existsSync(), isFalse);
      expect(File('${target.path}.bak').existsSync(), isFalse);
    });

    test('a body that does not hash to the digest is discarded', () async {
      final server = await _Server.start(_payloadBytes);
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');
      await target.writeAsString('the engine that was already working');

      final downloader = AssetDownloader();
      final ok = await downloader.download(
        server.url,
        target,
        expectedSha256: '0' * 64,
      );

      expect(ok, isFalse);
      // The previously installed engine is still there, and the bad download
      // left nothing behind.
      expect(target.readAsStringSync(), 'the engine that was already working');
      expect(File('${target.path}.tmp').existsSync(), isFalse);
      expect(downloader.lastError, contains('does not match the checksum'));
    });

    test('a body past the byte cap is stopped and discarded', () async {
      final server = await _Server.start(_payloadBytes);
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');

      final downloader = AssetDownloader(maxBytes: 8);
      final ok = await downloader.download(server.url, target);

      expect(ok, isFalse);
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.tmp').existsSync(), isFalse);
      expect(downloader.lastError, contains('grew past'));
    });

    test('an empty body is refused', () async {
      final server = await _Server.start(const []);
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');

      final ok = await AssetDownloader().download(server.url, target);

      expect(ok, isFalse);
      expect(target.existsSync(), isFalse);
    });

    test('a non-200 status is refused', () async {
      final server = await _Server.start(_payloadBytes, status: 503);
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');

      final ok = await AssetDownloader().download(server.url, target);

      expect(ok, isFalse);
      expect(target.existsSync(), isFalse);
    });

    test('a redirect to an untrusted host is refused', () async {
      // The policy only walks HTTPS hops, so a cleartext loopback redirect is
      // refused before it is followed.
      final server = await _Server.start(
        _payloadBytes,
        status: 302,
        location: 'http://127.0.0.1:1/elsewhere',
      );
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');

      final downloader = AssetDownloader();
      final ok = await downloader.download(server.url, target);

      expect(ok, isFalse);
      expect(target.existsSync(), isFalse);
      expect(downloader.lastError, contains('does not fetch from'));
    });

    test('a redirect with no Location header is refused', () async {
      final server = await _Server.start(_payloadBytes, status: 302);
      addTearDown(server.close);
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/yt-dlp');

      final downloader = AssetDownloader();
      final ok = await downloader.download(server.url, target);

      expect(ok, isFalse);
      expect(target.existsSync(), isFalse);
    });

    test(
      'a body below the size floor is refused when there is no digest',
      () async {
        final server = await _Server.start(const [1, 2, 3]);
        addTearDown(server.close);
        final dir = await Directory.systemTemp.createTemp('asset_downloader');
        addTearDown(() => dir.delete(recursive: true));
        final target = File('${dir.path}/yt-dlp');

        final ok = await AssetDownloader().download(
          server.url,
          target,
          minBytes: 64 * 1024,
        );

        expect(ok, isFalse);
        expect(target.existsSync(), isFalse);
      },
    );
  });

  group('replaceWith', () {
    test('moves a new file into place', () async {
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final src = File('${dir.path}/new')..writeAsStringSync('the engine');
      final dst = File('${dir.path}/installed');

      await AssetDownloader().replaceWith(src, dst);

      expect(dst.readAsStringSync(), 'the engine');
      expect(src.existsSync(), isFalse);
      expect(File('${dst.path}.bak').existsSync(), isFalse);
    });

    test('replaces an existing file and cleans the backup up', () async {
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final src = File('${dir.path}/new')..writeAsStringSync('the replacement');
      final dst = File('${dir.path}/installed')
        ..writeAsStringSync('the working engine');

      await AssetDownloader().replaceWith(src, dst);

      expect(dst.readAsStringSync(), 'the replacement');
      expect(File('${dst.path}.bak').existsSync(), isFalse);
    });

    test('refuses to replace a directory, leaving it alone', () async {
      final dir = await Directory.systemTemp.createTemp('asset_downloader');
      addTearDown(() => dir.delete(recursive: true));
      final src = File('${dir.path}/new')..writeAsStringSync('the replacement');
      // A non-empty directory where the file should go. `File.exists()` is
      // false for a directory, which is exactly the case that used to fall
      // through to a raw EISDIR from the rename.
      Directory('${dir.path}/installed').createSync();
      File('${dir.path}/installed/child').writeAsBytesSync('x'.codeUnits);

      await expectLater(
        AssetDownloader().replaceWith(src, File('${dir.path}/installed')),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('Cannot replace a directory'),
          ),
        ),
      );

      // Nothing was destroyed: the directory is still there and still a
      // directory, and the would-be replacement was not consumed.
      expect(Directory('${dir.path}/installed').existsSync(), isTrue);
      expect(src.existsSync(), isTrue);
    });
  });
}
