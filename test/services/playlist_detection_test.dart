import 'package:flutter_test/flutter_test.dart';
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
}
