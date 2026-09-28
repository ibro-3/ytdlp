import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/download_options.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/models/yt_prefs.dart';
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
  YtPrefs prefs = const YtPrefs(),
  String? archivePath,
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
  prefs: prefs,
  archivePath: archivePath,
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

  group('yt preferences', () {
    test('default prefs add nothing to the command line', () {
      // The whole point of the defaults: an untouched app produces byte-for-byte
      // the same invocation as before these controls existed.
      expect(_args(), _args(prefs: const YtPrefs()));
    });

    test('fragment parallelism is omitted at the default of 1', () {
      expect(_args(prefs: const YtPrefs()), isNot(contains('-N')));
      expect(
        _args(prefs: const YtPrefs(concurrentFragments: 1)),
        isNot(contains('-N')),
        reason: '1 is yt-dlp\'s own default, so passing it is noise',
      );
    });

    test('fragment parallelism is passed when raised', () {
      final a = _args(prefs: const YtPrefs(concurrentFragments: 4));
      expect(a, containsAllInOrder(['-N', '4']));
    });

    test('a rate limit and request delay are passed through', () {
      final a = _args(prefs: const YtPrefs(limitRate: '2M', sleepRequests: 5));
      expect(a, containsAllInOrder(['-r', '2M']));
      expect(a, containsAllInOrder(['--sleep-requests', '5']));
    });

    test('proxy and referer are passed through when set', () {
      final a = _args(
        prefs: const YtPrefs(
          proxy: 'http://localhost:8080',
          referer: 'https://example.com',
        ),
      );
      expect(a, containsAllInOrder(['--proxy', 'http://localhost:8080']));
      expect(a, containsAllInOrder(['--referer', 'https://example.com']));
    });

    test('blank proxy and referer are omitted', () {
      final a = _args(prefs: const YtPrefs(limitRate: '   '));
      expect(a, isNot(contains('--proxy')));
      expect(a, isNot(contains('--referer')));
      expect(a, isNot(contains('-r')));
    });

    test('live-from-start and no-part are passed when enabled', () {
      final a = _args(prefs: const YtPrefs(liveFromStart: true, noPart: true));
      expect(a, contains('--live-from-start'));
      expect(a, contains('--no-part'));
    });

    test('the download archive is only passed with a path', () {
      expect(
        _args(prefs: const YtPrefs(downloadArchive: true)),
        isNot(contains('--download-archive')),
        reason: 'without a file to append to, the flag is meaningless',
      );
      final a = _args(
        prefs: const YtPrefs(downloadArchive: true),
        archivePath: '/support/downloaded.txt',
      );
      expect(
        a,
        containsAllInOrder(['--download-archive', '/support/downloaded.txt']),
      );
    });

    test('an empty archive path is ignored', () {
      final a = _args(
        prefs: const YtPrefs(downloadArchive: true),
        archivePath: '',
      );
      expect(a, isNot(contains('--download-archive')));
    });

    test('audio extraction passes -x with its format', () {
      final a = _args(
        prefs: const YtPrefs(extractAudio: true, audioFormat: 'mp3'),
      );
      expect(a, containsAllInOrder(['-x', '--audio-format', 'mp3']));
    });

    test('remux passes its target', () {
      expect(
        _args(prefs: const YtPrefs(remuxVideo: 'mkv')),
        containsAllInOrder(['--remux-video', 'mkv']),
      );
    });

    test('metadata, chapters and sponsorblock are passed', () {
      final a = _args(
        prefs: const YtPrefs(
          embedMetadata: true,
          embedChapters: true,
          sponsorblockRemove: true,
        ),
      );
      expect(a, contains('--embed-metadata'));
      expect(a, contains('--embed-chapters'));
      expect(a, containsAllInOrder(['--sponsorblock-remove', 'default']));
    });

    test('postprocessing flags are omitted without ffmpeg', () {
      // Otherwise yt-dlp fails late with "Postprocessing: ffprobe not found",
      // after the bytes are already downloaded.
      final a = _args(
        hasFfmpeg: false,
        prefs: const YtPrefs(
          extractAudio: true,
          remuxVideo: 'mkv',
          embedMetadata: true,
          embedChapters: true,
          sponsorblockRemove: true,
        ),
      );
      expect(a, isNot(contains('-x')));
      expect(a, isNot(contains('--audio-format')));
      expect(a, isNot(contains('--remux-video')));
      expect(a, isNot(contains('--embed-metadata')));
      expect(a, isNot(contains('--embed-chapters')));
      expect(a, isNot(contains('--sponsorblock-remove')));
    });

    test('download-side prefs survive without ffmpeg', () {
      // -N, -r and the proxy have nothing to do with postprocessing.
      final a = _args(
        hasFfmpeg: false,
        prefs: const YtPrefs(
          concurrentFragments: 4,
          limitRate: '2M',
          proxy: 'http://p',
          downloadArchive: true,
        ),
        archivePath: '/a.txt',
      );
      expect(a, containsAllInOrder(['-N', '4']));
      expect(a, containsAllInOrder(['-r', '2M']));
      expect(a, containsAllInOrder(['--download-archive', '/a.txt']));
    });

    test('an embed is dropped when the target container cannot hold it', () {
      // WAV has nowhere to put cover art and yt-dlp discards it silently, so
      // the flag is omitted rather than producing a file missing its art.
      final a = _args(
        options: const DownloadOptions(embedThumb: true, writeThumb: true),
        prefs: const YtPrefs(extractAudio: true, audioFormat: 'wav'),
      );
      expect(a, isNot(contains('--embed-thumbnail')));
      // The sidecar is still written, so the image is not simply lost.
      expect(a, contains('--write-thumbnail'));
    });

    test('an embed is kept when the target container supports it', () {
      final a = _args(
        options: const DownloadOptions(embedThumb: true),
        prefs: const YtPrefs(extractAudio: true, audioFormat: 'm4a'),
      );
      expect(a, contains('--embed-thumbnail'));
    });

    test('prefs come AFTER extra args so a raw -x cannot override them', () {
      // Same last-word-wins rule as the other managed flags.
      final a = _args(
        prefs: const YtPrefs(extractAudio: true, audioFormat: 'mp3'),
        extraArgs: const ['-x', '--audio-format', 'wav'],
      );
      expect(a.indexOf('wav'), lessThan(a.lastIndexOf('mp3')));
    });

    test('the URL is still last', () {
      final a = _args(
        prefs: const YtPrefs(
          concurrentFragments: 4,
          limitRate: '2M',
          extractAudio: true,
        ),
      );
      expect(a.last, 'https://example.com/watch?v=abc');
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
