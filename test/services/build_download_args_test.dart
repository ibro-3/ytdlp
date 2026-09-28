import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/download_options.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

const _video = Format(
  kind: FormatKind.video,
  label: '720p',
  selector: 'bv*[height<=720]+ba/b[height<=720]/b',
);
const _audio = Format(
  kind: FormatKind.audio,
  label: 'Medium · M4A · 128kbps',
  selector: 'ba[ext=m4a][abr<=128]/ba[ext=m4a]',
  tier: 128,
);

List<String> _args({
  Format format = _video,
  DownloadOptions options = const DownloadOptions(),
  String? cookiesPath,
  bool hasFfmpeg = true,
  String? androidFfmpegPath,
  List<String> extraArgs = const [],
}) => buildDownloadArgs(
  url: 'https://example.com/watch?v=abc',
  format: format,
  options: options,
  outputDir: '/tmp/stg',
  template: '%(title)s [%(id)s].%(ext)s',
  cookiesPath: cookiesPath,
  hasFfmpeg: hasFfmpeg,
  androidFfmpegPath: androidFfmpegPath,
  extraArgs: extraArgs,
);

void main() {
  group('buildDownloadArgs', () {
    test('always carries the base download flags and the URL last', () {
      final a = _args();
      expect(a.sublist(0, 2), ['--newline', '--no-mtime']);
      expect(a, containsAllInOrder(['--continue', '--retries', '10']));
      expect(a, containsAllInOrder(['--fragment-retries', '10']));
      expect(a, containsAllInOrder(['--retry-sleep', 'linear=1:5:2']));
      expect(
        a,
        containsAllInOrder(['-o', '/tmp/stg/%(title)s [%(id)s].%(ext)s']),
      );
      expect(a, containsAllInOrder(['-f', _video.selector]));
      expect(a, contains('--no-playlist'));
      expect(a.last, 'https://example.com/watch?v=abc');
    });

    test('adds cookies only when provided', () {
      expect(_args(cookiesPath: ''), isNot(contains('--cookies')));
      final a = _args(cookiesPath: '/x/cookies.txt');
      expect(a, containsAllInOrder(['--cookies', '/x/cookies.txt']));
    });

    test('sidecar subtitles: write-subs + sub-langs, no conversion', () {
      final a = _args(
        options: const DownloadOptions(
          writeSubs: true,
          subLanguages: ['en', 'de'],
        ),
      );
      expect(a, containsAllInOrder(['--write-subs', '--sub-langs', 'en,de']));
      expect(a, isNot(contains('--convert-subs')));
      expect(a, isNot(contains('--embed-subs')));
      expect(a, isNot(contains('--write-auto-subs')));
    });

    test('auto captions add --write-auto-subs', () {
      final a = _args(
        options: const DownloadOptions(writeSubs: true, includeAutoSubs: true),
      );
      expect(a, contains('--write-auto-subs'));
    });

    test('empty language list means all', () {
      final a = _args(options: const DownloadOptions(writeSubs: true));
      expect(a, containsAllInOrder(['--sub-langs', 'all']));
    });

    test('embed subs converts to srt when ffmpeg is available', () {
      final a = _args(
        options: const DownloadOptions(embedSubs: true),
        hasFfmpeg: true,
      );
      expect(
        a,
        containsAllInOrder([
          '--write-subs',
          '--sub-langs',
          'all',
          '--convert-subs',
          'srt',
          '--embed-subs',
        ]),
      );
    });

    test('embed subs without ffmpeg does not ask for srt conversion', () {
      final a = _args(
        options: const DownloadOptions(embedSubs: true),
        hasFfmpeg: false,
      );
      expect(a, containsAllInOrder(['--write-subs', '--embed-subs']));
      expect(a, isNot(contains('--convert-subs')));
    });

    test('embed subs is silently dropped for audio formats', () {
      final a = _args(
        format: _audio,
        options: const DownloadOptions(embedSubs: true),
      );
      expect(a, isNot(contains('--embed-subs')));
      expect(a, isNot(contains('--convert-subs')));
    });

    test('sidecar thumbnail writes and converts to jpg', () {
      final a = _args(options: const DownloadOptions(writeThumb: true));
      expect(
        a,
        containsAllInOrder([
          '--write-thumbnail',
          '--convert-thumbnails',
          'jpg',
        ]),
      );
      expect(a, isNot(contains('--embed-thumbnail')));
    });

    test('embed thumbnail only embeds', () {
      final a = _args(options: const DownloadOptions(embedThumb: true));
      expect(a, contains('--embed-thumbnail'));
      // No -k, no accidental sidecar write, no unsupported quality flag.
      expect(a, isNot(contains('--write-thumbnail')));
      expect(a, isNot(contains('--thumbnail')));
    });

    test('both thumbnail options combine', () {
      final a = _args(
        options: const DownloadOptions(embedThumb: true, writeThumb: true),
      );
      expect(
        a,
        containsAllInOrder([
          '--write-thumbnail',
          '--convert-thumbnails',
          'jpg',
          '--embed-thumbnail',
        ]),
      );
    });

    test('android ffmpeg location is prepended', () {
      final a = _args(androidFfmpegPath: '/data/data/app/ffmpeg');
      expect(a.sublist(0, 2), ['--ffmpeg-location', '/data/data/app/ffmpeg']);
      expect(a.last, 'https://example.com/watch?v=abc');
    });

    test('everything together', () {
      final a = _args(
        format: _video,
        options: const DownloadOptions(
          embedSubs: true,
          writeSubs: true,
          includeAutoSubs: true,
          subLanguages: ['en'],
          embedThumb: true,
          writeThumb: true,
        ),
        cookiesPath: '/c/cookies.txt',
        hasFfmpeg: true,
        androidFfmpegPath: '/a/ffmpeg',
      );
      expect(
        a,
        containsAllInOrder([
          '--ffmpeg-location',
          '/a/ffmpeg',
          '--write-subs',
          '--write-auto-subs',
          '--sub-langs',
          'en',
          '--convert-subs',
          'srt',
          '--embed-subs',
          '--write-thumbnail',
          '--convert-thumbnails',
          'jpg',
          '--embed-thumbnail',
        ]),
      );
      expect(a, containsAllInOrder(['--cookies', '/c/cookies.txt']));
    });
  });

  group('extra arguments', () {
    test('are inserted after the base flags', () {
      final a = _args(extraArgs: ['--concurrent-fragments', '4']);
      expect(a, containsAllInOrder(['--concurrent-fragments', '4']));
      // Still before the URL.
      expect(a.last, 'https://example.com/watch?v=abc');
    });

    test('do not disturb the managed flags when benign', () {
      final a = _args(
        extraArgs: ['--embed-metadata', '--no-check-certificate'],
      );
      expect(a, containsAllInOrder(['-f', _video.selector]));
      expect(
        a,
        containsAllInOrder(['-o', '/tmp/stg/%(title)s [%(id)s].%(ext)s']),
      );
    });

    test('come BEFORE -o so a user -o cannot win', () {
      // yt-dlp lets the last occurrence of a single-valued option win, so a
      // user-supplied -o placed after ours would redirect the staging path and
      // break the finalise/move step entirely. Ordering is the whole defence.
      final a = _args(extraArgs: ['-o', '/tmp/attacker']);
      final userO = a.indexOf('/tmp/attacker');
      final appO = a.indexOf('/tmp/stg/%(title)s [%(id)s].%(ext)s');
      expect(userO, greaterThanOrEqualTo(0));
      expect(appO, greaterThan(userO), reason: 'the app value must come last');
    });

    test('come BEFORE -f so a user -f cannot change the stream', () {
      final a = _args(extraArgs: ['-f', 'worst']);
      expect(a.indexOf(_video.selector), greaterThan(a.indexOf('worst')));
    });

    test('come BEFORE --no-playlist so --yes-playlist cannot expand', () {
      final a = _args(extraArgs: ['--yes-playlist']);
      expect(a.indexOf('--yes-playlist'), lessThan(a.indexOf('--no-playlist')));
    });

    test('an empty list changes nothing', () {
      expect(_args(), _args(extraArgs: const []));
    });

    test('are placed before --ffmpeg-location prepending is irrelevant', () {
      // The ffmpeg location is inserted at index 0; the user flags still come
      // after the app's own base flags, so ordering of the two groups does not
      // change which -o wins.
      final a = _args(
        extraArgs: ['-o', '/tmp/attacker'],
        androidFfmpegPath: '/a/ffmpeg',
      );
      expect(a.first, '--ffmpeg-location');
      expect(
        a.indexOf('/tmp/stg/%(title)s [%(id)s].%(ext)s'),
        greaterThan(a.indexOf('/tmp/attacker')),
      );
    });
  });
}
