import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/video_info.dart';

Map<String, dynamic> _entry(
  String id, {
  String? title,
  String? webpageUrl,
  String? url,
  int? duration,
  String? availability,
  String? uploader,
}) => {
  'id': id,
  'title': title ?? 'Video $id',
  'webpage_url': webpageUrl,
  // Defaults to a fetchable URL so a fixture only has to opt out of one.
  'url': url ?? (id.isEmpty ? null : 'https://example.com/watch?v=$id'),
  'duration': duration,
  'availability': availability,
  'uploader': uploader,
  'thumbnails': [
    {'url': 'https://img.example/$id.jpg'},
  ],
};

Map<String, dynamic> _playlist(List<Map<String, dynamic>> entries) => {
  '_type': 'playlist',
  'id': 'PL123',
  'title': 'My Playlist',
  'webpage_url': 'https://example.com/playlist?list=PL123',
  'uploader': 'Some Channel',
  'entries': entries,
};

PlaylistInfo _parse(Map<String, dynamic> json) =>
    PlaylistInfo.fromYtdlpJson(json, hasFfmpeg: true, canPostprocess: true);

void main() {
  group('PlaylistInfo.fromYtdlpJson', () {
    test('reads the playlist metadata and its entries', () {
      final p = _parse(
        _playlist([
          _entry('a', duration: 60),
          _entry('b', duration: 30),
          _entry('c', duration: 90),
        ]),
      );
      expect(p.id, 'PL123');
      expect(p.title, 'My Playlist');
      expect(p.webUrl, 'https://example.com/playlist?list=PL123');
      expect(p.uploader, 'Some Channel');
      expect(p.count, 3);
      expect(p.isEmpty, isFalse);
      expect(p.totalDuration, 180);
    });

    test(
      'prefers webpage_url over the bare url for the entry download URL',
      () {
        final p = _parse(
          _playlist([
            _entry(
              'a',
              webpageUrl: 'https://example.com/watch?v=a',
              url: 'https://cdn/a.m3u8',
            ),
          ]),
        );
        expect(p.entries.single.webUrl, 'https://example.com/watch?v=a');
      },
    );

    test('falls back to url, as flat entries often lack webpage_url', () {
      final p = _parse(
        _playlist([_entry('a', url: 'https://www.youtube.com/watch?v=a')]),
      );
      expect(p.entries.single.webUrl, 'https://www.youtube.com/watch?v=a');
    });

    test('drops entries that cannot be downloaded', () {
      final p = _parse(
        _playlist([
          _entry('ok'),
          _entry('private', availability: 'private'),
          _entry('subscriber_only', availability: 'needs_auth'),
          _entry('premium', availability: 'premium_only'),
          _entry('ok2'),
        ]),
      );
      expect(p.entries.map((e) => e.id), ['ok', 'ok2']);
    });

    test('keeps public and unlisted entries', () {
      final p = _parse(
        _playlist([
          _entry('a', availability: 'public'),
          _entry('b', availability: 'unlisted'),
        ]),
      );
      expect(p.count, 2);
    });

    test('drops entries with no id or no resolvable URL', () {
      // Built by hand because the _entry helper always supplies a url.
      final noUrl = <String, dynamic>{
        'id': 'nourl',
        'title': 'No URL',
        'webpage_url': null,
        'url': null,
      };
      final noId = <String, dynamic>{
        'id': '',
        'title': 'No id',
        'url': 'https://example.com/watch?v=noid',
      };
      final p = _parse(
        _playlist([
          _entry('good', webpageUrl: 'https://example.com/v/good'),
          noId,
          noUrl,
        ]),
      );
      expect(p.entries.map((e) => e.id), ['good']);
    });

    test('survives entries fields of the wrong type', () {
      // A site controls the payload, so a String where a list is documented
      // must not throw.
      for (final bad in [
        'nope',
        42,
        true,
        <String>['a'],
        null,
      ]) {
        final p = _parse({
          '_type': 'playlist',
          'id': 'x',
          'title': 'T',
          'entries': bad,
        });
        expect(p.isEmpty, isTrue, reason: 'entries: $bad');
      }
    });

    test('survives a missing entries field', () {
      expect(
        _parse({'_type': 'playlist', 'id': 'x', 'title': 'T'}).isEmpty,
        isTrue,
      );
    });

    test('totals only count entries whose duration is known', () {
      final p = _parse(_playlist([_entry('a', duration: 60), _entry('b')]));
      expect(p.totalDuration, 60);
      expect(formatPlaylistDuration(60), '1 min');
    });

    test('carries the device capability flags onto every entry', () {
      final p = PlaylistInfo.fromYtdlpJson(
        _playlist([_entry('a', webpageUrl: 'https://example.com/a')]),
        hasFfmpeg: false,
        canPostprocess: false,
      );
      expect(p.hasFfmpeg, isFalse);
      expect(p.canPostprocess, isFalse);
      expect(p.entries.single.hasFfmpeg, isFalse);
      expect(p.entries.single.canPostprocess, isFalse);
      // Flat entries expose no formats, so the batch UI has nothing to list.
      expect(p.entries.single.videoFormats, isEmpty);
      expect(p.entries.single.audioFormats, isEmpty);
    });

    test('tolerates a null title and reports the uploader fallback chain', () {
      final p = _parse({
        '_type': 'playlist',
        'id': 'x',
        'channel': 'Fallback Channel',
        'entries': <Map<String, dynamic>>[],
      });
      expect(p.title, 'Untitled playlist');
      expect(p.uploader, 'Fallback Channel');
    });
  });

  group('videoFormatForTier', () {
    test('best quality with ffmpeg merges split streams', () {
      final f = videoFormatForTier(null, hasFfmpeg: true);
      expect(f.kind, FormatKind.video);
      expect(f.selector, 'bv*+ba/b');
      expect(f.tier, isNull);
      expect(f.label, 'Best quality');
    });

    test('a height cap mirrors the single-video selector', () {
      expect(
        videoFormatForTier(720, hasFfmpeg: true).selector,
        'bv*[height<=720]+ba/b[height<=720]/b',
      );
      expect(videoFormatForTier(720, hasFfmpeg: true).tier, 720);
      expect(videoFormatForTier(720, hasFfmpeg: true).label, '720 p');
    });

    test('without ffmpeg it falls back to combined mp4 only', () {
      expect(
        videoFormatForTier(null, hasFfmpeg: false).selector,
        'b[ext=mp4][acodec!=none]/b[acodec!=none]',
      );
      expect(
        videoFormatForTier(480, hasFfmpeg: false).selector,
        'b[height<=480][ext=mp4][acodec!=none]/b[height<=480][acodec!=none]',
      );
    });
  });

  group('audioFormatForTier', () {
    test('best audio prefers m4a', () {
      final f = audioFormatForTier(null);
      expect(f.kind, FormatKind.audio);
      expect(f.selector, 'ba[ext=m4a]/ba');
      expect(f.tier, isNull);
    });

    test('a bitrate cap mirrors the single-video selector', () {
      final f = audioFormatForTier(128);
      expect(f.selector, 'ba[ext=m4a][abr<=128]/ba[ext=m4a]');
      expect(f.tier, 128);
    });
  });

  group('PlaylistInfo.formatsFor', () {
    test('builds one format of the requested kind', () {
      final p = _parse(_playlist([_entry('a', webpageUrl: 'https://x/a')]));
      expect(
        p.formatsFor(kind: FormatKind.video, tier: 720).single.selector,
        'bv*[height<=720]+ba/b[height<=720]/b',
      );
      expect(
        p.formatsFor(kind: FormatKind.audio, tier: 128).single.selector,
        'ba[ext=m4a][abr<=128]/ba[ext=m4a]',
      );
    });

    test('respects the device ffmpeg capability', () {
      final p = PlaylistInfo.fromYtdlpJson(
        _playlist([_entry('a', webpageUrl: 'https://x/a')]),
        hasFfmpeg: false,
        canPostprocess: false,
      );
      expect(
        p.formatsFor(kind: FormatKind.video, tier: 720).single.selector,
        contains('[ext=mp4]'),
      );
      expect(
        p.formatsFor(kind: FormatKind.video, tier: 720).single.selector,
        isNot(contains('bv*')),
      );
    });
  });

  group('formatPlaylistDuration', () {
    test('formats hours, minutes and an unknown total', () {
      expect(formatPlaylistDuration(0), 'unknown length');
      expect(formatPlaylistDuration(45), '0 min');
      expect(formatPlaylistDuration(60 * 90), '1 h 30 min');
    });
  });
}
