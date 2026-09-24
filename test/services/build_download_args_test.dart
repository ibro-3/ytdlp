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
}) => buildDownloadArgs(
  url: 'https://example.com/watch?v=abc',
  format: format,
  options: options,
  outputDir: '/tmp/stg',
  template: '%(title)s [%(id)s].%(ext)s',
  cookiesPath: cookiesPath,
  hasFfmpeg: hasFfmpeg,
  androidFfmpegPath: androidFfmpegPath,
);

void main() {
  group('buildDownloadArgs', () {
    test('always carries the base download flags and the URL last', () {
      final a = _args();
      expect(a.sublist(0, 3), ['--newline', '--no-playlist', '--no-mtime']);
      expect(a, containsAllInOrder(['--continue', '--retries', '10']));
      expect(a, containsAllInOrder(['--fragment-retries', '10']));
      expect(a, containsAllInOrder(['--retry-sleep', 'linear=1:5:2']));
      expect(
        a,
        containsAllInOrder(['-o', '/tmp/stg/%(title)s [%(id)s].%(ext)s']),
      );
      expect(a, containsAllInOrder(['-f', _video.selector]));
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
}
