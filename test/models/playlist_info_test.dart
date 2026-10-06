import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/collection_kind.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/playlist_paging.dart';
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

    test('survives the collection fields being the wrong type', () {
      // These come from the site. `as String` on a number throws, which used to
      // crash the whole metadata fetch rather than dropping the field.
      late PlaylistInfo p;
      expect(
        () => p = _parse({
          '_type': 'playlist',
          'id': 7,
          'title': 42,
          'webpage_url': ['nope'],
          'channel': 3.5,
          'entries': <Map<String, dynamic>>[],
        }),
        returnsNormally,
      );
      expect(p.id, '');
      expect(p.title, 'Untitled playlist');
      expect(p.webUrl, '');
      expect(p.uploader, isNull);
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

  group('batch quality selectors', () {
    // A flat entry carries no formats, so a batch download's quality comes from
    // the user's saved tier rather than from the source. These pin the selector
    // a batch actually produces, which must match what the same video would
    // resolve to downloaded on its own.
    test('a video tier mirrors the single-video selector', () {
      expect(
        videoFormatForTier(720, hasFfmpeg: true).selector,
        'bv*[height<=720]+ba/b[height<=720]/b',
      );
    });

    test('an audio tier prefers m4a under the cap', () {
      expect(
        audioFormatForTier(128).selector,
        'ba[ext=m4a][abr<=128]/ba[ext=m4a]',
      );
    });

    test('the device ffmpeg capability decides merge versus mp4-only', () {
      expect(
        videoFormatForTier(720, hasFfmpeg: false).selector,
        contains('[ext=mp4]'),
      );
      expect(
        videoFormatForTier(720, hasFfmpeg: false).selector,
        isNot(contains('bv*')),
        reason: 'split streams cannot be merged without ffmpeg',
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

  group('collection kind', () {
    test('a channel link is a channel even when the payload looks like one', () {
      // yt-dlp reports a channel's uploads tab as a /playlist?list=UU… URL, so
      // the requested link is the only thing that identifies the collection.
      final p = PlaylistInfo.fromYtdlpJson(
        {
          ..._playlist([_entry('a')]),
          'webpage_url': 'https://www.youtube.com/playlist?list=UUabcdef',
        },
        hasFfmpeg: true,
        canPostprocess: true,
        requestedUrl: 'https://www.youtube.com/@somecreator/videos',
      );
      expect(p.kind, CollectionKind.channel);
    });

    test('a playlist link is a playlist', () {
      final p = PlaylistInfo.fromYtdlpJson(
        _playlist([_entry('a')]),
        hasFfmpeg: true,
        canPostprocess: true,
        requestedUrl: 'https://www.youtube.com/playlist?list=PL123',
      );
      expect(p.kind, CollectionKind.playlist);
    });

    test('defaults to a playlist when nothing identifies the collection', () {
      expect(_parse(_playlist([_entry('a')])).kind, CollectionKind.playlist);
    });
  });

  group('paging', () {
    PlaylistInfo parseWith(
      List<Map<String, dynamic>> entries, {
      int? playlistCount,
      int startedAt = 1,
    }) {
      final json = _playlist(entries);
      if (playlistCount != null) json['playlist_count'] = playlistCount;
      return PlaylistInfo.fromYtdlpJson(
        json,
        hasFfmpeg: true,
        canPostprocess: true,
        requestedUrl: 'https://www.youtube.com/@somecreator/videos',
        paging: PlaylistPaging(startedAt: startedAt),
      );
    }

    test('counts raw entries, not the ones that survived filtering', () {
      // The cursor has to line up with `--playlist-start`, which upstream
      // indexes before unavailable entries are dropped. Counting the filtered
      // list would re-request entries already seen.
      final p = parseWith([
        _entry('a'),
        _entry('b', availability: 'private'),
        <String, dynamic>{
          'id': 'nourl',
          'title': 'No URL',
          'webpage_url': null,
          'url': null,
        },
        _entry('d'),
      ]);
      expect(p.entries, hasLength(2));
      expect(p.paging.fetched, 4);
      expect(p.paging.nextStart, 5);
    });

    test('a short slice is complete', () {
      final p = parseWith([_entry('a'), _entry('b')]);
      expect(p.paging.hasMore, isFalse);
    });

    test('a reported total is carried through', () {
      final p = parseWith([_entry('a')], playlistCount: 5000);
      expect(p.paging.totalCount, 5000);
      expect(p.paging.hasMore, isTrue);
    });

    test('a reported total is only trusted when it is positive', () {
      // A zero total would end the listing immediately and hide every later
      // video; a negative one is plainly not a count.
      for (final bogus in [0, -1, -5000]) {
        final p = parseWith([_entry('a')], playlistCount: bogus);
        expect(p.paging.totalCount, isNull, reason: '$bogus');
      }
    });

    test('a non-numeric total is ignored rather than crashing', () {
      final json = _playlist([_entry('a')])..['playlist_count'] = 'lots';
      final p = PlaylistInfo.fromYtdlpJson(
        json,
        hasFfmpeg: true,
        canPostprocess: true,
      );
      expect(p.paging.totalCount, isNull);
    });

    test('a numeric-string total is read', () {
      final json = _playlist([_entry('a')])..['playlist_count'] = '5000';
      final p = PlaylistInfo.fromYtdlpJson(
        json,
        hasFfmpeg: true,
        canPostprocess: true,
      );
      expect(p.paging.totalCount, 5000);
    });
  });

  group('copyWith', () {
    test('keeps the collection identity and replaces the listing', () {
      final p = PlaylistInfo.fromYtdlpJson(
        _playlist([_entry('a')]),
        hasFfmpeg: true,
        canPostprocess: false,
        requestedUrl: 'https://www.youtube.com/@somecreator',
      );
      final merged = p.copyWith(
        entries: const [
          VideoInfo(id: 'a', title: 'A', webUrl: 'https://x/a'),
          VideoInfo(id: 'b', title: 'B', webUrl: 'https://x/b'),
        ],
        paging: const PlaylistPaging(fetched: 400),
      );
      expect(merged.id, p.id);
      expect(merged.title, p.title);
      expect(merged.webUrl, p.webUrl);
      expect(merged.kind, p.kind);
      expect(merged.uploader, p.uploader);
      // Capability flags must survive: they gate the embed toggles, and a
      // later slice must not silently re-enable an option the device cannot do.
      expect(merged.hasFfmpeg, p.hasFfmpeg);
      expect(merged.canPostprocess, p.canPostprocess);
      expect(merged.entries, hasLength(2));
      expect(merged.paging.fetched, 400);
    });

    group('a slice that came back short', () {
      test('marks the end of a collection with no reported total', () {
        // What the app does after asking for entries 201-400 of a collection
        // that stopped at 200. Recording the end is the only way the picker
        // learns there is nothing more to fetch.
        final p = PlaylistInfo.fromYtdlpJson(
          {'id': 'UC1', 'title': 'Deep Archive', 'entries': []},
          hasFfmpeg: false,
          canPostprocess: false,
          requestedUrl: 'https://www.youtube.com/@deeparchive/videos',
          paging: const PlaylistPaging(startedAt: 201),
        );

        expect(p.paging.fetched, 0);
        expect(p.paging.endReached, isTrue);
        expect(p.paging.hasMore, isFalse);
      });

      test('marks the end for a first slice under the window too', () {
        // A curated playlist of 12 arrives whole. With no total reported it
        // would otherwise look like a partial listing and offer to load more.
        final p = PlaylistInfo.fromYtdlpJson(
          {
            'id': 'PL1',
            'title': 'Shortlist',
            'entries': [
              for (var i = 0; i < 12; i++)
                {'id': 'v$i', 'title': 'Clip $i', 'url': 'https://x/v$i'},
            ],
          },
          hasFfmpeg: false,
          canPostprocess: false,
          requestedUrl: 'https://example.com/playlist?list=PL1',
        );

        expect(p.paging.endReached, isTrue);
        expect(p.paging.hasMore, isFalse);
        expect(p.paging.truncationNotice(12), isNull);
      });

      test('a full window leaves the listing open', () {
        final p = PlaylistInfo.fromYtdlpJson(
          {
            'id': 'UC1',
            'title': 'Deep Archive',
            'entries': [
              for (var i = 0; i < PlaylistPaging.sliceSize; i++)
                {'id': 'v$i', 'title': 'Clip $i', 'url': 'https://x/v$i'},
            ],
          },
          hasFfmpeg: false,
          canPostprocess: false,
          requestedUrl: 'https://www.youtube.com/@deeparchive/videos',
        );

        expect(p.paging.endReached, isFalse);
        expect(p.paging.hasMore, isTrue);
        expect(p.paging.truncationNotice(PlaylistPaging.sliceSize), isNotNull);
      });

      test('a short page does not overrule a total the site gave', () {
        // The extractor said 5,000. Believing the short page instead would
        // hide 4,999 videos behind a picker that insists there is nothing
        // more, and the user would have no way to find out.
        final p = PlaylistInfo.fromYtdlpJson(
          _playlist([_entry('a')])..['playlist_count'] = 5000,
          hasFfmpeg: true,
          canPostprocess: true,
        );

        expect(p.paging.endReached, isFalse);
        expect(p.paging.hasMore, isTrue);
      });

      test('an empty response ends it even against a total', () {
        // Nothing at all came back, which is direct evidence rather than an
        // inference — so it wins, and the picker stops asking.
        final json = _playlist([])..['playlist_count'] = 5000;
        final p = PlaylistInfo.fromYtdlpJson(
          json,
          hasFfmpeg: true,
          canPostprocess: true,
          paging: const PlaylistPaging(startedAt: 201),
        );

        expect(p.paging.totalCount, 5000);
        expect(p.paging.endReached, isTrue);
        expect(p.paging.hasMore, isFalse);
      });
    });
  });
}
