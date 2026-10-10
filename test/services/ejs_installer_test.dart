import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/ejs_installer.dart';

/// A run of [n] hex characters, for building digest-shaped strings.
///
/// The resolver validates the *shape* of a digest rather than its value, so any
/// well-formed string stands in for a real one and no fixture needs a genuine hash.
String _hex(int n, [String c = 'a']) => List.filled(n, c).join();

const _digestA =
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa'
    'aaaa';
const _digestB =
    'bbbbbbbb'
    'bbbbbbbb'
    'bbbbbbbb'
    'bbbbbbbb'
    'bbbbbbbb'
    'bbbbbbbb'
    'bbbbbbbb'
    'bbbbbbbb';

/// A PyPI JSON payload with one pure-Python wheel.
///
/// [omitDigests] drops the `digests` key entirely, which is the case that has
/// to be refused: PyPI described nothing to verify against.
Map<String, dynamic> _pypi({
  Object? digest = _digestA,
  bool omitDigests = false,
  String filename = 'yt_dlp_ejs-2025.09.25-py3-none-any.whl',
  Object? url = 'https://files.pythonhosted.org/packages/ab/cd/yt_dlp_ejs.whl',
}) => {
  'urls': [
    {
      'filename': filename,
      'url': url,
      if (!omitDigests) 'digests': {'sha256': digest},
    },
  ],
};

void main() {
  group('EjsWheel resolution', () {
    test('resolves the URL and the digest PyPI published for it', () {
      final wheel = EjsInstaller.resolveWheel(_pypi());
      expect(wheel, isNotNull);
      expect(
        wheel!.url,
        'https://files.pythonhosted.org/packages/ab/cd/yt_dlp_ejs.whl',
      );
      // Lower-cased, because the comparison in `_download` is exact and PyPI
      // is not obliged to send upper- or lower-case.
      expect(wheel.sha256, _digestA);
    });

    test('normalises an upper-case digest', () {
      final wheel = EjsInstaller.resolveWheel(_pypi(digest: _hex(64, 'A')));
      expect(wheel!.sha256, _hex(64, 'a'));
    });

    test('refuses a payload with a wheel but no digest', () {
      // The whole point: an unverifiable wheel is a failure, not a fallback to
      // installing code nothing vouches for.
      expect(EjsInstaller.resolveWheel(_pypi(omitDigests: true)), isNull);
      // A digest that is present but null is the same answer from the other
      // direction — PyPI named no algorithm.
      expect(EjsInstaller.resolveWheel(_pypi(digest: null)), isNull);
    });

    test('refuses a digest of the wrong shape', () {
      for (final bad in [
        '',
        'abc',
        _hex(64, 'z'),
        _hex(63, 'a'),
        _hex(65, 'a'),
        42,
      ]) {
        expect(
          EjsInstaller.resolveWheel(_pypi(digest: bad)),
          isNull,
          reason: 'a digest shaped like "$bad" cannot be a SHA-256',
        );
      }
    });

    test('refuses a non-string digest', () {
      expect(EjsInstaller.resolveWheel(_pypi(digest: 12345)), isNull);
    });

    test('picks the pure-Python wheel when there are several', () {
      final wheel = EjsInstaller.resolveWheel({
        'urls': [
          {
            'filename': 'yt_dlp_ejs-2025.09.25-cp313-cp313-manylinux.whl',
            'url': 'platform',
            'digests': {'sha256': _hex(64, 'c')},
          },
          {
            'filename': 'yt_dlp_ejs-2025.09.25-py3-none-any.whl',
            'url': 'good',
            'digests': {'sha256': _digestA},
          },
        ],
      });
      expect(wheel!.url, 'good');
      expect(wheel.sha256, _digestA);
    });

    test('returns null when there is no pure-Python wheel', () {
      expect(
        EjsInstaller.resolveWheel({
          'urls': [
            {
              'filename': 'x-cp313-cp313-win.whl',
              'url': 'a',
              'digests': {'sha256': _digestA},
            },
          ],
        }),
        isNull,
      );
      expect(EjsInstaller.resolveWheel(const {}), isNull);
      expect(EjsInstaller.resolveWheel({'urls': 'nope'}), isNull);
    });

    test('tolerates a malformed entry in the list', () {
      expect(
        EjsInstaller.resolveWheel({
          'urls': [
            'garbage',
            {'no_filename': 1},
            {
              'filename': 'yt_dlp_ejs-1-py3-none-any.whl',
              'url': 'ok',
              'digests': {'sha256': _digestB},
            },
          ],
        })!.url,
        'ok',
      );
    });

    test('the PyPI url is well formed', () {
      expect(
        EjsInstaller.pypiJsonUrl('1.2.0'),
        'https://pypi.org/pypi/yt_dlp_ejs/1.2.0/json',
      );
    });
  });

  group('redirect host pinning', () {
    /// PyPI's own CDN, which the package download legitimately lands on.
    test('allows a redirect to the PyPI CDN', () {
      expect(
        EjsInstaller.checkedRedirect(
          Uri.parse('https://pypi.org/pypi/yt_dlp_ejs/1/json'),
          'https://files.pythonhosted.org/packages/ab/cd/x.whl',
        ).host,
        'files.pythonhosted.org',
      );
    });

    test('allows a relative Location', () {
      // The CDN redirects to a path, not an absolute URL.
      expect(
        EjsInstaller.checkedRedirect(
          Uri.parse('https://pypi.org/pypi/yt_dlp_ejs/1/json'),
          '/packages/ab/cd/x.whl',
        ).toString(),
        'https://pypi.org/packages/ab/cd/x.whl',
      );
    });

    test('refuses to be sent anywhere else', () {
      // This is the decision that makes verifying the hash worth anything: the
      // digest comes from the JSON response, so an attacker who can redirect
      // *that* request controls both the URL and the expected hash.
      for (final location in [
        'https://evil.example/x.whl',
        'https://pypi.org.evil.example/x.whl',
        'http://pypi.org/x.whl',
        '//evil.example/x.whl',
        'file:///etc/passwd',
      ]) {
        expect(
          () => EjsInstaller.checkedRedirect(
            Uri.parse('https://pypi.org/pypi/yt_dlp_ejs/1/json'),
            location,
          ),
          throwsA(
            isA<EjsInstallException>().having(
              (e) => e.message,
              'message',
              contains('does not fetch from'),
            ),
          ),
          reason: 'a redirect to "$location" must not be followed',
        );
      }
    });

    test('names the host it refused', () {
      expect(
        () => EjsInstaller.checkedRedirect(
          Uri.parse('https://pypi.org/pypi/x/json'),
          'https://evil.example/y.whl',
        ),
        throwsA(
          isA<EjsInstallException>().having(
            (e) => e.message,
            'message',
            contains('evil.example'),
          ),
        ),
      );
    });

    test('a malformed Location is reported, not crashed on', () {
      expect(
        () => EjsInstaller.checkedRedirect(
          Uri.parse('https://pypi.org/pypi/x/json'),
          'http://[not-a-uri',
        ),
        throwsA(isA<EjsInstallException>()),
      );
    });
  });

  group('digest verification', () {
    test('accepts bytes that hash to the published digest', () {
      final bytes = utf8.encode('a plausible little wheel');
      final digest = sha256.convert(bytes).toString();
      // The real hash, not a shaped stand-in: this is the assertion that the
      // bytes and the digest are the same thing.
      expect(() => EjsInstaller.verifyDigest(digest, digest), returnsNormally);
    });

    test('accepts either case', () {
      final digest = sha256.convert(utf8.encode('x')).toString();
      expect(
        () => EjsInstaller.verifyDigest(digest.toUpperCase(), digest),
        returnsNormally,
      );
    });

    test('rejects bytes that do not', () {
      final good = sha256.convert(utf8.encode('the real wheel')).toString();
      final tampered = sha256
          .convert(utf8.encode('a wheel, but edited'))
          .toString();
      expect(
        () => EjsInstaller.verifyDigest(tampered, good),
        throwsA(
          isA<EjsInstallException>()
              .having((e) => e.message, 'message', contains('did not match'))
              // Says which bytes were expected, so a report can be compared
              // against PyPI without re-downloading.
              .having((e) => e.message, 'message', contains(good))
              .having((e) => e.message, 'message', contains(tampered)),
        ),
      );
    });

    test('rejects an empty download', () {
      final good = sha256.convert(utf8.encode('not empty')).toString();
      final empty = sha256.convert(const <int>[]).toString();
      expect(
        () => EjsInstaller.verifyDigest(empty, good),
        throwsA(isA<EjsInstallException>()),
      );
    });

    test('a one-byte difference is still rejected', () {
      // Truncation is the common case: a partial transfer is not a corrupt one.
      final full = utf8.encode('0123456789');
      final digest = sha256.convert(full).toString();
      expect(
        () => EjsInstaller.verifyDigest(
          sha256.convert(full.sublist(0, 9)).toString(),
          digest,
        ),
        throwsA(isA<EjsInstallException>()),
      );
    });
  });

  group('EjsWheel', () {
    test('summarises without printing the whole digest', () {
      final wheel = const EjsWheel(url: 'https://x/y.whl', sha256: _digestA);
      expect(wheel.toString(), contains('https://x/y.whl'));
      // Enough to identify it in a report, not enough to be a credential.
      expect(wheel.toString(), contains('sha256:${_hex(12, 'a')}'));
      expect(wheel.toString(), isNot(contains(_hex(32, 'a'))));
    });
  });

  group('EjsInfo', () {
    test('summarises each state for the settings screen', () {
      expect(
        const EjsInfo(status: EjsStatus.missing).summary,
        'JS runtime not installed',
      );
      expect(
        const EjsInfo(status: EjsStatus.installed).summary,
        'JS runtime installed',
      );
      expect(
        const EjsInfo(status: EjsStatus.installed, version: '1.2.3').summary,
        'JS runtime 1.2.3',
      );
      expect(
        const EjsInfo(status: EjsStatus.broken).summary,
        'JS runtime is installed but not working',
      );
      expect(
        const EjsInfo(status: EjsStatus.unknown).summary,
        'JS runtime status unknown',
      );
    });

    test('only an installed runtime counts as usable', () {
      expect(const EjsInfo(status: EjsStatus.installed).isUsable, isTrue);
      for (final status in [
        EjsStatus.unknown,
        EjsStatus.missing,
        EjsStatus.broken,
      ]) {
        expect(EjsInfo(status: status).isUsable, isFalse);
      }
    });
  });

  group('EjsInstallException', () {
    test('carries the message it is built from', () {
      const e = EjsInstallException('the thing failed');
      expect(e.message, 'the thing failed');
      expect(e.toString(), 'the thing failed');
    });
  });
}
