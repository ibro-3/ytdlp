import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/utils/url_validator.dart';

void main() {
  group('isValidUrl', () {
    test('accepts http and https', () {
      expect(isValidUrl('https://youtu.be/abc'), isTrue);
      expect(isValidUrl('http://example.com/a'), isTrue);
      expect(isValidUrl('  https://example.com/a  '), isTrue);
    });

    test('rejects other schemes and bare text', () {
      expect(isValidUrl('ftp://example.com'), isFalse);
      expect(isValidUrl('www.example.com'), isFalse);
      expect(isValidUrl('just some text'), isFalse);
      expect(isValidUrl(''), isFalse);
    });
  });

  group('extractUrl', () {
    test('returns a bare URL verbatim', () {
      expect(
        extractUrl('https://youtu.be/jNQXAC9IVRw'),
        'https://youtu.be/jNQXAC9IVRw',
      );
    });

    test('pulls a link out of a sentence', () {
      expect(
        extractUrl('watch this https://youtu.be/xyz later'),
        'https://youtu.be/xyz',
      );
    });

    test('strips trailing sentence punctuation', () {
      expect(extractUrl('see https://example.com/a.'), 'https://example.com/a');
      expect(extractUrl('(https://example.com/a)'), 'https://example.com/a');
    });

    test('keeps a balanced parenthesis group in the path', () {
      expect(
        extractUrl('https://en.wikipedia.org/wiki/Foo_(bar)'),
        'https://en.wikipedia.org/wiki/Foo_(bar)',
      );
    });

    test('unwraps angle brackets', () {
      // A link pasted out of a chat client often arrives as <url>.
      expect(
        extractUrl('see <https://example.com/v>'),
        'https://example.com/v',
      );
    });

    test('returns null when there is no link', () {
      expect(extractUrl('no link here'), isNull);
      expect(extractUrl(''), isNull);
    });
  });

  group('extractUrls', () {
    test('finds one link in a sentence', () {
      expect(extractUrls('watch https://youtu.be/xyz later'), [
        'https://youtu.be/xyz',
      ]);
    });

    test('finds every link in a multi-line paste', () {
      expect(
        extractUrls('''
watch these:
https://youtu.be/aaa
https://youtu.be/bbb
and https://vimeo.com/999
'''),
        [
          'https://youtu.be/aaa',
          'https://youtu.be/bbb',
          'https://vimeo.com/999',
        ],
      );
    });

    test('finds several links on one line', () {
      expect(
        extractUrls('a https://a.example.com/1 b https://b.example.com/2 c'),
        ['https://a.example.com/1', 'https://b.example.com/2'],
      );
    });

    test('de-duplicates the same link', () {
      // Pasting a link twice means one download, not two of the same file.
      expect(
        extractUrls('https://a.example.com/1 and https://a.example.com/1'),
        ['https://a.example.com/1'],
      );
    });

    test('preserves order', () {
      expect(extractUrls('https://c.example.com/3 https://a.example.com/1'), [
        'https://c.example.com/3',
        'https://a.example.com/1',
      ], reason: 'queue order follows what the user pasted');
    });

    test('strips trailing punctuation from each link', () {
      expect(
        extractUrls(
          'one https://a.example.com/1. two https://b.example.com/2!',
        ),
        ['https://a.example.com/1', 'https://b.example.com/2'],
      );
    });

    test('ignores non-http links', () {
      expect(
        extractUrls('ftp://files.example.com/x and mailto:a@b.com'),
        isEmpty,
      );
    });

    test('returns an empty list for text with no links', () {
      expect(extractUrls('nothing to see'), isEmpty);
      expect(extractUrls(''), isEmpty);
    });

    test('agrees with extractUrl on the first link', () {
      const text = 'a https://one.example.com/1 b https://two.example.com/2';
      expect(extractUrl(text), extractUrls(text).first);
    });
  });
}
