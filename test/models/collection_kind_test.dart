import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/collection_kind.dart';

void main() {
  group('collectionKindForUrl', () {
    test('playlist layouts are playlists', () {
      const urls = [
        'https://www.youtube.com/playlist?list=PLabcdef',
        'https://youtube.com/playlist?list=PLabcdef',
        'https://m.youtube.com/playlist?list=PLabcdef',
        'https://music.youtube.com/playlist?list=PLabcdef',
        'https://www.youtube-nocookie.com/playlist?list=PLabcdef',
      ];
      for (final url in urls) {
        expect(collectionKindForUrl(url), CollectionKind.playlist, reason: url);
      }
    });

    test('every channel layout is a channel', () {
      // The three vanity layouts, a bare channel id, and a handle — each with
      // and without a tab suffix, since the tab is the same collection.
      const urls = [
        'https://www.youtube.com/channel/UCabcdefghijklmnop',
        'https://www.youtube.com/channel/UCabcdefghijklmnop/videos',
        'https://www.youtube.com/c/SomeCreator',
        'https://www.youtube.com/c/SomeCreator/streams',
        'https://www.youtube.com/user/SomeCreator',
        'https://www.youtube.com/user/SomeCreator/playlists',
        'https://www.youtube.com/@somecreator',
        'https://www.youtube.com/@somecreator/videos',
        'https://www.youtube.com/@somecreator/shorts',
        'https://www.youtube.com/@somecreator/streams',
      ];
      for (final url in urls) {
        expect(collectionKindForUrl(url), CollectionKind.channel, reason: url);
      }
    });

    test('a single video is not a collection', () {
      const urls = [
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        // The playlist half of a watch URL is ignored on purpose: the download
        // path resolves this to the video alone via --no-playlist.
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabcdef',
        'https://youtu.be/dQw4w9WgXcQ',
        'https://www.youtube.com/shorts/dQw4w9WgXcQ',
        'https://www.youtube.com/embed/dQw4w9WgXcQ',
        'https://www.youtube.com/',
        'https://www.youtube.com',
      ];
      for (final url in urls) {
        expect(collectionKindForUrl(url), isNull, reason: url);
      }
    });

    test('other sites are left unclassified rather than guessed at', () {
      // Paging a curated album or a plain stream would be wrong, so these must
      // return null and let the caller fall back to the payload.
      const urls = [
        'https://vimeo.com/album/12345',
        'https://soundcloud.com/someone/sets/a-set',
        'https://example.com/media/stream.m3u8',
        'https://example.com/channel/whatever',
        'https://example.com/@handle',
        'https://notyoutube.com.evil.test/channel/UCfake',
      ];
      for (final url in urls) {
        expect(collectionKindForUrl(url), isNull, reason: url);
      }
    });

    test('junk does not throw', () {
      for (final url in <String?>[
        null,
        '',
        '   ',
        'not a url at all',
        '://missing-scheme/channel/x',
        'https://',
      ]) {
        expect(() => collectionKindForUrl(url), returnsNormally);
      }
    });

    test('surrounding whitespace is tolerated', () {
      expect(
        collectionKindForUrl('  https://www.youtube.com/@somecreator  '),
        CollectionKind.channel,
      );
    });
  });

  group('resolveCollectionKind', () {
    test('the requested link wins over the payload', () {
      // This is the case that motivates the whole design: yt-dlp reports a
      // channel's uploads tab as a `youtube.com/playlist?list=UU…` URL, so a
      // payload-first reading would call every channel a playlist.
      final result = resolveCollectionKind(
        requestedUrl: 'https://www.youtube.com/@somecreator/videos',
        payload: {
          'webpage_url': 'https://www.youtube.com/playlist?list=UUabcdef',
        },
      );
      expect(result, CollectionKind.channel);
    });

    test('the payload is consulted when the link said nothing', () {
      // A share link the classifier does not know, which the extractor
      // resolved to a channel.
      final result = resolveCollectionKind(
        requestedUrl: 'https://youtu.be/dQw4w9WgXcQ',
        payload: {'webpage_url': 'https://www.youtube.com/@somecreator/videos'},
      );
      expect(result, CollectionKind.channel);
    });

    test('an unknown link with no payload falls back to playlist', () {
      // Every flat playlist is a curated playlist unless something positively
      // says otherwise; paging a 40-video playlist over a bad guess is the
      // worse failure.
      expect(
        resolveCollectionKind(requestedUrl: 'https://example.com/album/1'),
        CollectionKind.playlist,
      );
      expect(
        resolveCollectionKind(requestedUrl: 'https://example.com/album/1'),
        CollectionKind.playlist,
      );
    });

    test('a payload URL of the wrong type is ignored', () {
      // Extractor payloads are not contractually well-typed here, so a
      // non-string webpage_url must not throw.
      final result = resolveCollectionKind(
        requestedUrl: 'https://example.com/album/1',
        payload: {'webpage_url': 42},
      );
      expect(result, CollectionKind.playlist);
    });
  });

  group('labels', () {
    test('contentsLabel pluralises', () {
      expect(CollectionKind.contentsLabel(1), '1 video');
      expect(CollectionKind.contentsLabel(2), '2 videos');
      expect(CollectionKind.contentsLabel(0), '0 videos');
    });

    test('each kind names itself', () {
      expect(CollectionKind.playlist.label, 'Playlist');
      expect(CollectionKind.channel.label, 'Channel');
    });
  });
}
