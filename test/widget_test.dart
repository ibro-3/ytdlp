import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/utils/formatters.dart';
import 'package:ytdlp/core/utils/url_validator.dart';

void main() {
  group('url_validator', () {
    test('accepts https urls', () {
      expect(isValidUrl('https://www.youtube.com/watch?v=jNQXAC9IVRw'), isTrue);
      expect(isValidUrl('http://example.com/video'), isTrue);
      expect(isValidUrl('https://tiktok.com/@user/video/123'), isTrue);
    });
    test('rejects invalid', () {
      expect(isValidUrl(''), isFalse);
      expect(isValidUrl('not a url'), isFalse);
      expect(isValidUrl('ftp://example.com'), isFalse);
      expect(isValidUrl('   '), isFalse);
    });

    group('extractUrl', () {
      test('returns a bare URL unchanged', () {
        expect(
          extractUrl('https://youtu.be/jNQXAC9IVRw'),
          'https://youtu.be/jNQXAC9IVRw',
        );
      });

      test('trims surrounding whitespace', () {
        expect(
          extractUrl('  https://example.com/video \n'),
          'https://example.com/video',
        );
      });

      test('pulls a URL out of shared text', () {
        expect(
          extractUrl(
            'check this out https://www.youtube.com/watch?v=abc123 !!!',
          ),
          'https://www.youtube.com/watch?v=abc123',
        );
      });

      test('handles a URL wrapped in an angle bracket', () {
        expect(
          extractUrl('see <https://example.com/v>'),
          'https://example.com/v',
        );
      });

      test('keeps balanced parentheses inside a URL', () {
        expect(
          extractUrl('https://en.wikipedia.org/wiki/Foo_(bar)'),
          'https://en.wikipedia.org/wiki/Foo_(bar)',
        );
      });

      test('returns null when there is no URL', () {
        expect(extractUrl(''), isNull);
        expect(extractUrl('just some words'), isNull);
        expect(extractUrl('ftp://example.com/file'), isNull);
      });
    });
  });

  group('formatters', () {
    test('formatBytes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), contains('KB'));
      expect(formatBytes(1024 * 1024), contains('MB'));
    });
    test('formatDuration', () {
      expect(formatDuration(65), '1:05');
      expect(formatDuration(3661), '1:01:01');
      expect(formatDuration(0), '0:00');
    });
  });

  testWidgets('trivial widget pumps', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('hello'))),
    );
    expect(find.text('hello'), findsOneWidget);
  });
}
