import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/playlist_paging.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

/// Deciding "playlist vs video" from the first-stage `-J --no-playlist` run is
/// the hinge of the whole feature. Miss it and the user hits a dead end; over-
/// detect it and a genuine "video is private" error gets retried as a playlist
/// and reported as "no videos available", which is worse.
void main() {
  bool detect({String stdout = '', String stderr = '', int exitCode = 0}) =>
      YtdlpService.looksLikePlaylistOutput(
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
      );

  group('a payload that declares itself a playlist', () {
    test('is detected even on a clean exit', () {
      // yt-dlp returns the entire collection and still exits 0 when an
      // extractor ignores --no-playlist.
      expect(
        detect(stdout: '{"_type": "playlist", "id": "PL1", "entries": []}'),
        isTrue,
      );
      expect(
        detect(stdout: '{"_type":"playlist","id":"PL1"}'),
        isTrue,
        reason: 'no space after the colon is valid JSON too',
      );
    });

    test('is detected even on a failing exit', () {
      expect(
        detect(
          stdout: '{"_type": "playlist"}',
          exitCode: 1,
          stderr: 'ERROR: something unrelated',
        ),
        isTrue,
      );
    });
  });

  group('an error that only mentions a playlist', () {
    test('the real --no-playlist rejection is detected', () {
      // This is the case the feature exists for: the first stage fails, and
      // without this the user gets "this app downloads one video at a time".
      expect(
        detect(
          stdout: '',
          exitCode: 1,
          stderr:
              'ERROR: This is a playlist. Use --yes-playlist to download the '
              'videos.',
        ),
        isTrue,
      );
    });

    test('the --yes-playlist hint is detected on its own', () {
      expect(
        detect(
          stdout: '',
          exitCode: 2,
          stderr: 'ERROR: playlist download: use --yes-playlist',
        ),
        isTrue,
      );
    });

    test('matching is case-insensitive', () {
      expect(detect(exitCode: 1, stderr: 'error: this IS A PLAYLIST'), isTrue);
    });
  });

  group('a plain video', () {
    test('is not mistaken for a playlist', () {
      expect(
        detect(stdout: '{"id": "abc", "title": "Video", "formats": []}'),
        isFalse,
      );
    });

    test('an unrelated error is not retried as a playlist', () {
      // The over-detection case: this must surface as an error, not as
      // "that playlist has no videos available".
      for (final stderr in [
        'ERROR: Video unavailable. This video is private.',
        'ERROR: [youtube] abc: Sign in to confirm you\'re not a bot',
        'ERROR: Unsupported URL: https://example.com/page',
        'ERROR: playlist_position is out of range', // mentions it, not a playlist
        'ERROR: Video is no longer available because the account associated '
            'with it has been terminated.',
      ]) {
        expect(detect(exitCode: 1, stderr: stderr), isFalse, reason: stderr);
      }
    });

    test('an empty run is not a playlist', () {
      expect(detect(stdout: '', exitCode: 1, stderr: ''), isFalse);
      expect(detect(stdout: '', stderr: 'some warning'), isFalse);
    });

    test('a truncated payload that lost _type is not a playlist', () {
      // The stdout budget kills the process mid-payload; the head is retained
      // so _type is normally still there, but a huge playlist could be cut
      // before it if yt-dlp reordered output.
      expect(
        detect(stdout: '{"entries": [{"id": "a"}]}', exitCode: 1),
        isFalse,
      );
    });
  });

  // Detecting the collection is only half the job: once it is detected, the
  // second stage has to *ask* for it in a way that can be resumed, or a channel
  // with more videos than the stdout capture can hold still fails outright.
  group('listing one slice', () {
    const url = 'https://www.youtube.com/@somecreator/videos';
    const slice = PlaylistPaging.sliceSize;

    List<String> args({required int start}) =>
        YtdlpService.buildPlaylistListArgs(url: url, start: start);

    String flag(List<String> a, String name) => a[a.indexOf(name) + 1];

    test('the first slice starts at the beginning', () {
      // An explicit --playlist-start 1 is redundant, and some extractors treat
      // an explicit start differently from its absence — so it is left out.
      expect(args(start: 1), isNot(contains('--playlist-start')));
    });

    test('a later slice resumes where it was asked to', () {
      final a = args(start: 201);
      expect(flag(a, '--playlist-start'), '201');
    });

    test('every slice is capped at one slice of entries', () {
      // The cap is what keeps a huge channel inside the bounded capture, so it
      // has to be exactly one slice wide and move with the start index.
      expect(flag(args(start: 1), '--playlist-end'), '$slice');
      expect(flag(args(start: 201), '--playlist-end'), '${201 + slice - 1}');
      expect(
        flag(args(start: 100_001), '--playlist-end'),
        '${100_000 + slice}',
      );
    });

    test('the listing is flat, so no per-entry stream data is pulled', () {
      expect(args(start: 1), contains('--flat-playlist'));
    });

    test('the url is the last argument', () {
      // yt-dlp treats everything after the URL as another URL.
      expect(args(start: 1).last, url);
      expect(args(start: 201).last, url);
    });

    test('the paging cursor feeds straight back into the next request', () {
      // The end-to-end contract: what a slice measured is what the next one
      // resumes from, so a second call cannot re-request the first slice.
      const firstSlice = PlaylistPaging(fetched: slice);
      final second = args(start: firstSlice.nextStart);
      expect(flag(second, '--playlist-start'), '${slice + 1}');
      expect(flag(second, '--playlist-end'), '${2 * slice}');
    });
  });
}
