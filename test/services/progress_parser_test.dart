import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/progress_parser.dart';

void main() {
  group('YtdlpProgressParser', () {
    test('parses a full progress line', () {
      final p = YtdlpProgressParser.parseProgress(
        '[download]  42.5% of 250.00MiB at 5.21MiB/s ETA 00:47',
      );
      expect(p, isNotNull);
      expect(p!.progress, closeTo(0.425, 0.0001));
      expect(p.speed, '5.21 MiB/s');
      expect(p.eta, '00:47');
    });

    test('parses a bare percentage', () {
      final p = YtdlpProgressParser.parseProgress('[download]   5.0%');
      expect(p, isNotNull);
      expect(p!.progress, closeTo(0.05, 0.0001));
      expect(p.speed, isNull);
      expect(p.eta, isNull);
    });

    test('ignores non-progress lines', () {
      expect(
        YtdlpProgressParser.parseProgress('[info] Downloading to x.mp4'),
        isNull,
      );
    });

    test('parses destination and merged-file lines', () {
      expect(
        YtdlpProgressParser.parseDestination(
          '[download] Destination: /tmp/a.mp4',
        ),
        '/tmp/a.mp4',
      );
      expect(
        YtdlpProgressParser.parseMergedFile(
          '[Merger] Merging formats into "/tmp/a.mp4"',
        ),
        '/tmp/a.mp4',
      );
    });

    test('parses error lines', () {
      expect(
        YtdlpProgressParser.parseError('ERROR: Unsupported URL: xyz'),
        'Unsupported URL: xyz',
      );
    });
  });
}
