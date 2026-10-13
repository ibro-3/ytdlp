import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/redirect_policy.dart';

void main() {
  const current =
      'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp';

  group('RedirectPolicy.resolve', () {
    test('allows an HTTPS redirect to a trusted host', () {
      const location =
          'https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp';
      expect(
        githubReleaseRedirects.resolve(Uri.parse(current), location).host,
        'github.com',
      );
    });

    test('allows the release-assets CDN hop GitHub actually uses', () {
      const location =
          'https://release-assets.githubusercontent.com/github-production-release-asset/1';
      expect(
        githubReleaseRedirects.resolve(Uri.parse(current), location).host,
        'release-assets.githubusercontent.com',
      );
    });

    test('resolves a relative Location against the current URL', () {
      final next = githubReleaseRedirects.resolve(
        Uri.parse('https://github.com/a/b'),
        'c/d',
      );
      expect(next.toString(), 'https://github.com/a/c/d');
    });

    test('refuses a redirect to an untrusted host', () {
      expect(
        () => githubReleaseRedirects.resolve(
          Uri.parse(current),
          'https://evil.example/yt-dlp',
        ),
        throwsA(isA<RedirectException>()),
      );
    });

    test('refuses an HTTPS downgrade even on a trusted host', () {
      expect(
        () => githubReleaseRedirects.resolve(
          Uri.parse(current),
          'http://github.com/yt-dlp/yt-dlp/releases/download/1/yt-dlp',
        ),
        throwsA(isA<RedirectException>()),
      );
    });

    test('refuses a location it cannot parse', () {
      expect(
        () => githubReleaseRedirects.resolve(
          Uri.parse(current),
          'https://[not a uri',
        ),
        throwsA(isA<RedirectException>()),
      );
    });
  });

  group('isRedirectStatus', () {
    test('covers the status codes that carry a Location header', () {
      for (final code in [301, 302, 303, 307, 308]) {
        expect(isRedirectStatus(code), isTrue, reason: '$code');
      }
      for (final code in [200, 204, 400, 404, 500, 503]) {
        expect(isRedirectStatus(code), isFalse, reason: '$code');
      }
    });
  });
}
