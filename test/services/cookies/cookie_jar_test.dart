import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/cookies/cookie_jar.dart';
import 'package:ytdlp/services/cookies/cookie_model.dart';

void main() {
  group('parse', () {
    test('reads a real-world-style login jar', () {
      final text = File('test/fixtures/cookies/youtube_login.txt')
          .readAsStringSync();
      final result = CookieJar.parse(text);

      expect(result.entries, hasLength(6));
      expect(result.skipped, 0);

      final first = result.entries.first;
      expect(first.domain, '.example.com');
      expect(first.includeSubdomains, isTrue);
      expect(first.path, '/');
      expect(first.secure, isFalse);
      expect(first.name, 'VISITOR_INFO1_LIVE');
      expect(first.httpOnly, isTrue);
      // Expiry is epoch seconds, read back as UTC.
      expect(
        first.expiry,
        DateTime.fromMillisecondsSinceEpoch(1735689600 * 1000, isUtc: true),
      );

      // The LOGIN_INFO cookie is secure and not HttpOnly.
      final login = result.entries.firstWhere((e) => e.name == 'LOGIN_INFO');
      expect(login.secure, isTrue);
      expect(login.httpOnly, isFalse);

      // A trailing empty expiry column is a session cookie.
      final device = result.entries.firstWhere((e) => e.name == 'device_info');
      expect(device.expiry, isNull);
    });

    test('a value containing a tab survives whole', () {
      final text = File('test/fixtures/cookies/oddities.txt')
          .readAsStringSync();
      final result = CookieJar.parse(text);

      final split = result.entries.firstWhere((e) => e.name == 'split_value');
      // The value is everything after the sixth tab, so
      // the embedded tab is kept rather than dropped.
      expect(split.value, 'part1\tpart2');
    });

    test('a session cookie with expiry 0 has no expiry', () {
      final text = File('test/fixtures/cookies/oddities.txt')
          .readAsStringSync();
      final result = CookieJar.parse(text);

      final session = result.entries.firstWhere((e) => e.name == 'session_id');
      expect(session.expiry, isNull);
      expect(session.secure, isFalse);
    });

    test('malformed lines are skipped, not fatal', () {
      final text = File('test/fixtures/cookies/oddities.txt')
          .readAsStringSync();
      final result = CookieJar.parse(text);

      // Two truncated lines (five fields, and three), each
      // counted once; the three well-formed cookies parse.
      expect(result.skipped, 2);
      expect(result.entries, hasLength(3));
    });

    test('a comment-only file parses to nothing', () {
      const text = '# Netscape HTTP Cookie File\n# nothing here\n';
      final result = CookieJar.parse(text);
      expect(result.entries, isEmpty);
      expect(result.skipped, 0);
    });

    test('an empty input parses to nothing', () {
      final result = CookieJar.parse('');
      expect(result.entries, isEmpty);
      expect(result.skipped, 0);
    });

    test('a secure-only cookie is marked secure', () {
      const text =
          '.example.net\tTRUE\t/\tTRUE\t1735689600\t'
          'secure_cookie\ts3cret\n';
      final result = CookieJar.parse(text);
      final cookie = result.entries.single;
      expect(cookie.secure, isTrue);
      expect(cookie.domain, '.example.net');
    });
  });

  group('looksLikeCookieJar', () {
    test('accepts a real jar', () {
      final text = File('test/fixtures/cookies/youtube_login.txt')
          .readAsStringSync();
      expect(CookieJar.looksLikeCookieJar(text), isTrue);
    });

    test('rejects an HTML error page', () {
      const html = '<html><body>404 Not Found</body></html>\n';
      expect(CookieJar.looksLikeCookieJar(html), isFalse);
    });

    test('rejects a JSON export', () {
      const json = '[{"name":"session","value":"x"}]';
      expect(CookieJar.looksLikeCookieJar(json), isFalse);
    });

    test('rejects a header with no cookies', () {
      const headerOnly = '# Netscape HTTP Cookie File\n';
      expect(CookieJar.looksLikeCookieJar(headerOnly), isFalse);
    });
  });

  group('write', () {
    test('round-trips a parsed jar', () {
      final text = File('test/fixtures/cookies/youtube_login.txt')
          .readAsStringSync();
      final entries = CookieJar.parse(text).entries;

      final written = CookieJar.write(entries);
      final reparsed = CookieJar.parse(written);

      expect(reparsed.entries, entries);
      expect(reparsed.skipped, 0);
    });

    test('writes the #HttpOnly_ prefix for HttpOnly cookies', () {
      final entry = CookieJarEntry(
        domain: '.example.com',
        path: '/',
        name: 'SID',
        value: 'v',
        httpOnly: true,
        expiry: DateTime.fromMillisecondsSinceEpoch(
          1735689600 * 1000,
          isUtc: true,
        ),
      );
      final written = CookieJar.write([entry]);
      final lines = written.split('\n');
      // The first line is the header; the cookie line
      // carries the prefix.
      expect(lines[1].startsWith('#HttpOnly_'), isTrue);
    });

    test('a session cookie is written with expiry 0', () {
      const entry = CookieJarEntry(
        domain: '.example.com',
        path: '/',
        name: 'session',
        value: 'v',
      );
      final written = CookieJar.write([entry]);
      expect(written, contains('\t0\t'));
    });
  });

  group('isExpiredAt', () {
    test('a past expiry is expired', () {
      final entry = CookieJarEntry(
        domain: '.example.com',
        path: '/',
        name: 'old',
        value: 'v',
        expiry: DateTime.fromMillisecondsSinceEpoch(
          1700000000 * 1000,
          isUtc: true,
        ),
      );
      final now = DateTime.fromMillisecondsSinceEpoch(
        1800000000 * 1000,
        isUtc: true,
      );
      expect(entry.isExpiredAt(now), isTrue);
    });

    test('a session cookie never expires', () {
      const entry = CookieJarEntry(
        domain: '.example.com',
        path: '/',
        name: 'session',
        value: 'v',
      );
      expect(entry.isExpiredAt(DateTime.now()), isFalse);
    });
  });
}
