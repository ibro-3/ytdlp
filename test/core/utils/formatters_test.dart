import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/utils/formatters.dart';

void main() {
  group('formatBytes', () {
    test('reports bytes below a kilobyte exactly', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('steps up a unit at a time with one decimal', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes(1024 * 1024 * 1024 * 1024), '1.0 TB');
    });

    test('stops at terabytes rather than inventing a unit', () {
      final petabyte = 1024 * 1024 * 1024 * 1024 * 1024;
      expect(formatBytes(petabyte), contains('TB'));
    });
  });

  group('formatDuration', () {
    test('is m:ss below an hour', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(9), '0:09');
      expect(formatDuration(65), '1:05');
      expect(formatDuration(599), '9:59');
      expect(formatDuration(3599), '59:59');
    });

    test('adds hours, unpadded, when there are any', () {
      expect(formatDuration(3600), '1:00:00');
      expect(formatDuration(3661), '1:01:01');
      expect(formatDuration(36600), '10:10:00');
    });
  });

  group('formatDate', () {
    test('is month day, year', () {
      expect(formatDate(DateTime(2026, 1, 5)), 'Jan 5, 2026');
      expect(formatDate(DateTime(2026, 12, 31)), 'Dec 31, 2026');
    });
  });

  group('parseUploadDate', () {
    test('reads the YYYYMMDD yt-dlp emits', () {
      expect(parseUploadDate('20240115'), DateTime(2024, 1, 15));
    });

    test('is null rather than throwing on anything else', () {
      // A site or an extractor can put anything here, and this feeds a filename
      // — a guess would produce a plausible-looking wrong date.
      expect(parseUploadDate(null), isNull);
      expect(parseUploadDate(''), isNull);
      expect(parseUploadDate('2024'), isNull);
      expect(parseUploadDate('not a date at all'), isNull);
      expect(parseUploadDate('99999999'), isNull);
    });
  });
}
