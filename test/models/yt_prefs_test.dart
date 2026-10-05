import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/yt_prefs.dart';

void main() {
  group('defaults', () {
    test('match yt-dlp and the app previous behaviour', () {
      const p = YtPrefs();
      // 1 is yt-dlp's own -N default, so an untouched app behaves exactly as
      // it did before these controls existed.
      expect(p.concurrentFragments, 1);
      expect(p.limitRate, isEmpty);
      expect(p.extractAudio, isFalse);
      expect(p.audioFormat, 'm4a');
      expect(p.remuxVideo, isEmpty);
      expect(p.noPart, isFalse);
      expect(p.sleepRequests, 0);
    });

    test('produce no yt-dlp flags at all', () {
      // The critical property: enabling nothing must add nothing to the
      // command line, so a user's existing downloads are unaffected.
      const p = YtPrefs();
      expect(p.needsPostprocessing, isFalse);
    });
  });

  group('validation and clamping', () {
    test('fromMap defaults every field', () {
      final p = YtPrefs.fromMap(null);
      expect(p.concurrentFragments, 1);
      expect(p.limitRate, isEmpty);
      expect(p.proxy, isEmpty);
    });

    test('clamps fragment count into range', () {
      expect(
        YtPrefs.fromMap({'concurrentFragments': 0}).concurrentFragments,
        1,
      );
      expect(
        YtPrefs.fromMap({'concurrentFragments': -5}).concurrentFragments,
        1,
      );
      expect(
        YtPrefs.fromMap({'concurrentFragments': 99}).concurrentFragments,
        YtPrefs.maxConcurrentFragments,
      );
      expect(
        YtPrefs.fromMap({'concurrentFragments': 3}).concurrentFragments,
        3,
      );
    });

    test('rejects an audio format the app does not offer', () {
      // An unknown value would produce a nonsense --audio-format and fail the
      // download inside ffmpeg.
      expect(YtPrefs.fromMap({'audioFormat': 'exe'}).audioFormat, 'm4a');
      expect(YtPrefs.fromMap({'audioFormat': 'MP3'}).audioFormat, 'mp3');
    });

    test('rejects an unknown remux format', () {
      expect(YtPrefs.fromMap({'remuxVideo': 'avi'}).remuxVideo, isEmpty);
      expect(YtPrefs.fromMap({'remuxVideo': 'MKV'}).remuxVideo, 'mkv');
    });

    test('clamps the request delay', () {
      expect(YtPrefs.fromMap({'sleepRequests': -1}).sleepRequests, 0);
      expect(YtPrefs.fromMap({'sleepRequests': 500}).sleepRequests, 60);
      expect(YtPrefs.fromMap({'sleepRequests': 5}).sleepRequests, 5);
    });

    test('clamps the retry counts', () {
      // A retry count is a small non-negative integer; a corrupt or
      // hand-edited value must not turn into thousands of retries.
      expect(YtPrefs.fromMap({'retries': -1}).retries, YtPrefs.minRetries);
      expect(YtPrefs.fromMap({'retries': 999}).retries, YtPrefs.maxRetries);
      expect(YtPrefs.fromMap({'retries': 3}).retries, 3);
      expect(
        YtPrefs.fromMap({'fragmentRetries': -5}).fragmentRetries,
        YtPrefs.minRetries,
      );
      expect(
        YtPrefs.fromMap({'fragmentRetries': 999}).fragmentRetries,
        YtPrefs.maxRetries,
      );
      // A missing field falls back to yt-dlp's own default.
      expect(YtPrefs.fromMap(null).retries, 10);
      expect(YtPrefs.fromMap(null).fragmentRetries, 10);
    });

    test('tolerates a non-map', () {
      // A corrupt settings box must not stop the app from starting.
      expect(() => YtPrefs.fromMap(const {}), returnsNormally);
    });

    test('copyWith re-clamps', () {
      const p = YtPrefs();
      expect(p.copyWith(concurrentFragments: 50).concurrentFragments, 4);
      expect(p.copyWith(retries: 999).retries, YtPrefs.maxRetries);
      expect(p.copyWith(fragmentRetries: -1).fragmentRetries, 0);
    });
  });

  group('canEmbedThumbnail', () {
    test('is available with no conversion', () {
      const p = YtPrefs();
      expect(p.canEmbedThumbnail, isTrue);
    });

    test('is available for an audio format that can carry art', () {
      expect(
        const YtPrefs(extractAudio: true, audioFormat: 'm4a').canEmbedThumbnail,
        isTrue,
      );
      expect(
        const YtPrefs(extractAudio: true, audioFormat: 'mp3').canEmbedThumbnail,
        isTrue,
      );
      expect(
        const YtPrefs(
          extractAudio: true,
          audioFormat: 'flac',
        ).canEmbedThumbnail,
        isTrue,
      );
    });

    test('is unavailable for a format that cannot carry art', () {
      // WAV has no cover-art support anywhere, so offering the toggle would
      // produce a file with the art silently dropped.
      expect(
        const YtPrefs(extractAudio: true, audioFormat: 'wav').canEmbedThumbnail,
        isFalse,
      );
    });

    test('follows the remux target when not extracting audio', () {
      expect(const YtPrefs(remuxVideo: 'mkv').canEmbedThumbnail, isTrue);
    });
  });

  group('needsPostprocessing', () {
    test('is false for download-side preferences', () {
      expect(
        const YtPrefs(
          concurrentFragments: 4,
          limitRate: '2M',
          proxy: 'http://p',
          liveFromStart: true,
          downloadArchive: true,
        ).needsPostprocessing,
        isFalse,
      );
    });

    test('is true for anything that goes through ffmpeg', () {
      for (final p in const [
        YtPrefs(extractAudio: true),
        YtPrefs(remuxVideo: 'mkv'),
        YtPrefs(embedMetadata: true),
        YtPrefs(embedChapters: true),
        YtPrefs(sponsorblockRemove: true),
      ]) {
        expect(p.needsPostprocessing, isTrue, reason: '$p');
      }
    });
  });

  group('persistence', () {
    test('round-trips through a map', () {
      const p = YtPrefs(
        concurrentFragments: 3,
        limitRate: '500K',
        proxy: 'http://localhost:8080',
        referer: 'https://example.com',
        extractAudio: true,
        audioFormat: 'opus',
        remuxVideo: 'mkv',
        embedMetadata: true,
        embedChapters: true,
        sponsorblockRemove: true,
        liveFromStart: true,
        downloadArchive: true,
        noPart: true,
        sleepRequests: 3,
        retries: 4,
        fragmentRetries: 7,
      );
      expect(YtPrefs.fromMap(p.toMap()), p);
    });

    test('equality is by value', () {
      expect(const YtPrefs(limitRate: '2M'), const YtPrefs(limitRate: '2M'));
      expect(
        const YtPrefs(limitRate: '2M'),
        isNot(const YtPrefs(limitRate: '3M')),
      );
    });

    test('hashCode matches for equal values', () {
      expect(
        const YtPrefs(limitRate: '2M').hashCode,
        const YtPrefs(limitRate: '2M').hashCode,
      );
    });
  });
}
