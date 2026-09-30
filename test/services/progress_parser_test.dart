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

    test('parses warning lines and ignores non-warnings', () {
      expect(
        YtdlpProgressParser.parseWarning(
          'WARNING: webm doesn\'t support embedding a thumbnail, '
          'mkv will be used',
        ),
        'webm doesn\'t support embedding a thumbnail, mkv will be used',
      );
      expect(YtdlpProgressParser.parseWarning('ERROR: boom'), isNull);
      expect(YtdlpProgressParser.parseWarning('[download] 10%'), isNull);
    });

    group('JS runtime warnings are dropped', () {
      // All of these are the same problem — no runtime installed, so YouTube's
      // signature challenge failed — which the app reports once, in Settings,
      // instead of on every completed download card.
      test('the missing-runtime warning', () {
        expect(
          YtdlpProgressParser.parseWarning(
            'WARNING: [youtube] No supported JavaScript runtime could be found. '
            'Only deno is enabled by default; to use another runtime add '
            '--js-runtimes RUNTIME[:PATH] to your command/config.',
          ),
          isNull,
        );
      });

      test('the challenge-solving warnings, in each yt-dlp wording', () {
        for (final line in [
          'WARNING: [youtube] abc: nsig extraction failed: Some formats may be '
              'missing',
          'WARNING: [youtube] abc: Signature solving failed: Some formats may '
              'be missing.',
          'WARNING: [youtube] abc: n challenge solving failed: Some formats '
              'may be missing.',
        ]) {
          expect(
            YtdlpProgressParser.parseWarning(line),
            isNull,
            reason: 'should be dropped: ${line.split(' ').last}',
          );
        }
      });

      test('the trailing pointer to the wiki', () {
        expect(
          YtdlpProgressParser.parseWarning(
            'WARNING: Ensure you have a supported JavaScript runtime and '
            'challenge solver script distribution installed.',
          ),
          isNull,
        );
      });

      test('a genuine warning still comes through', () {
        // The filter is not a blanket "drop warnings" — a container change is
        // still worth explaining on the card.
        expect(
          YtdlpProgressParser.parseWarning(
            'WARNING: webm doesn\'t support embedding a thumbnail, mkv will '
            'be used',
          ),
          isNotNull,
        );
      });
    });
  });
}
