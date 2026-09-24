import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/bounded_capture.dart';

void main() {
  group('BoundedCapture (head)', () {
    test('keeps everything while under the budget', () {
      final c = BoundedCapture(maxBytes: 100);
      expect(c.add('hello '), isTrue);
      expect(c.add('world'), isTrue);
      expect(c.overflowed, isFalse);
      expect(c.text, 'hello world');
      expect(c.bytes, 11);
    });

    test('reports overflow while keeping the beginning of the stream', () {
      final c = BoundedCapture(maxBytes: 10, windowChars: 32);
      expect(c.add('0123456789'), isTrue, reason: 'exactly at the budget');
      expect(
        c.add('MORE-DATA'),
        isFalse,
        reason: 'false tells the caller to stop the process',
      );
      expect(c.overflowed, isTrue);
      expect(c.bytes, 19, reason: 'counts what was seen, not what was kept');
      expect(
        c.text,
        startsWith('0123456789'),
        reason: 'the retained head is still a prefix of the stream',
      );
    });

    test('bounds the retained head for a flood of chunks', () {
      final c = BoundedCapture(maxBytes: 8, windowChars: 4);
      c.add('aaaa');
      c.add('bbbb');
      c.add('cccc');
      c.add('dddd');
      expect(c.overflowed, isTrue);
      expect(c.text.length, lessThanOrEqualTo(4));
    });
  });

  group('BoundedCapture (tail)', () {
    test('keeps the end, which is where errors are', () {
      final c = BoundedCapture(
        maxBytes: 10,
        keep: CaptureKeep.tail,
        windowChars: 6,
      );
      c.add('start-1');
      c.add('start-2');
      c.add('boom!');
      expect(c.overflowed, isTrue);
      expect(c.text, contains('boom!'));
      expect(c.text, isNot(contains('start-1')));
    });

    test('a single oversized chunk is trimmed to the window', () {
      final c = BoundedCapture(
        maxBytes: 4,
        keep: CaptureKeep.tail,
        windowChars: 4,
      );
      c.add('abcdefghij');
      expect(c.text, 'ghij');
    });
  });

  group('playlist detection', () {
    test('recognises a yt-dlp playlist payload', () {
      expect(
        BoundedCapture.looksLikePlaylist(
          '{"_type": "playlist", "entries": []}',
        ),
        isTrue,
      );
      expect(BoundedCapture.looksLikePlaylist('{"_type":"playlist"}'), isTrue);
    });

    test('does not misfire on a single video', () {
      expect(
        BoundedCapture.looksLikePlaylist('{"_type": "video", "id": "abc"}'),
        isFalse,
      );
    });
  });

  group('lenientDecoder', () {
    test('survives malformed UTF-8 instead of throwing', () {
      // 0xC3 starts a 2-byte sequence; 0x28 is not a valid continuation.
      final bad = <int>[...utf8.encode('ok '), 0xC3, 0x28];
      final out = lenientDecoder.convert(bad);
      expect(out, startsWith('ok '));
    });
  });

  group('formatBytesShort', () {
    test('formats the sizes used in error messages', () {
      expect(formatBytesShort(512), '512 B');
      expect(formatBytesShort(39 * 1024 * 1024), contains('MB'));
      expect(formatBytesShort(2048), contains('KB'));
    });
  });
}
