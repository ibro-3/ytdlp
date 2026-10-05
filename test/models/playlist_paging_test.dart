import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/playlist_paging.dart';

void main() {
  const slice = PlaylistPaging.sliceSize;

  group('cursor', () {
    test('an untouched listing starts at 1', () {
      expect(PlaylistPaging.empty.nextStart, 1);
    });

    test('the next slice follows the entries already fetched', () {
      const paging = PlaylistPaging(fetched: 200);
      expect(paging.nextStart, 201);
    });

    test('a later slice continues from where it was asked to start', () {
      // `startedAt` matters because a resumed request has to say where it
      // resumes *from*, not how many entries have been seen in total.
      const paging = PlaylistPaging(startedAt: 401, fetched: 200);
      expect(paging.nextStart, 601);
    });
  });

  group('hasMore', () {
    test('a short first slice means the collection ended', () {
      expect(const PlaylistPaging(fetched: 40).hasMore, isFalse);
    });

    test('nothing fetched yet is not more', () {
      expect(PlaylistPaging.empty.hasMore, isFalse);
    });

    test('a full slice with no reported total is presumed to continue', () {
      // Cannot know, so offer rather than claim completeness.
      expect(const PlaylistPaging(fetched: slice).hasMore, isTrue);
    });

    test('a reported total decides exactly', () {
      expect(
        const PlaylistPaging(fetched: 200, totalCount: 5000).hasMore,
        isTrue,
      );
      expect(
        const PlaylistPaging(fetched: 200, totalCount: 200).hasMore,
        isFalse,
      );
    });

    test('a reported total shorter than the slice still ends the listing', () {
      // A stale total must not leave "load more" on screen for ever.
      expect(
        const PlaylistPaging(fetched: 200, totalCount: 150).hasMore,
        isFalse,
      );
    });
  });

  group('appended', () {
    test('slices accumulate and the cursor follows', () {
      const first = PlaylistPaging(fetched: slice);
      final both = first.appended(
        const PlaylistPaging(startedAt: 201, fetched: slice),
      );
      expect(both.fetched, 400);
      expect(both.nextStart, 401);
      expect(both.hasMore, isTrue);
    });

    test('a slice with no total does not retract an earlier one', () {
      const first = PlaylistPaging(fetched: slice, totalCount: 5000);
      final both = first.appended(
        const PlaylistPaging(startedAt: 201, fetched: slice),
      );
      expect(both.totalCount, 5000);
    });

    test('the newest total wins', () {
      const first = PlaylistPaging(fetched: slice, totalCount: 5000);
      final both = first.appended(
        const PlaylistPaging(startedAt: 201, fetched: 10, totalCount: 210),
      );
      expect(both.totalCount, 210);
      expect(both.hasMore, isFalse);
    });
  });

  group('truncationNotice', () {
    test('says nothing when the listing is complete', () {
      expect(const PlaylistPaging(fetched: 40).truncationNotice(40), isNull);
      expect(
        const PlaylistPaging(
          fetched: 200,
          totalCount: 200,
        ).truncationNotice(200),
        isNull,
      );
      expect(PlaylistPaging.empty.truncationNotice(0), isNull);
    });

    test('states the total when the site reported one', () {
      expect(
        const PlaylistPaging(
          fetched: 200,
          totalCount: 5000,
        ).truncationNotice(200),
        'Showing the first 200 of 5000',
      );
    });

    test('does not invent a total when the site reported none', () {
      final notice = const PlaylistPaging(fetched: slice)
          .truncationNotice(slice);
      expect(notice, isNotNull);
      expect(notice, contains('first $slice'));
      expect(notice, contains('load more'));
      expect(notice, isNot(contains(' of ')));
    });

    test('quotes the listed rows, not the fetched count', () {
      // 200 fetched, 5 dropped as unavailable. The user can see 195 rows, so
      // claiming they can see 200 would describe a video that is not there.
      const paging = PlaylistPaging(fetched: slice, totalCount: 5000);
      expect(paging.truncationNotice(195), 'Showing the first 195 of 5000');
    });

    test('a filtered listing still names the real total', () {
      const paging = PlaylistPaging(fetched: 200, totalCount: 240);
      expect(paging.truncationNotice(200), 'Showing the first 200 of 240');
    });
  });

  group('reaching the end of an unmeasured collection', () {
    // The heuristic that saves us when no total is reported — "a full slice
    // means there may be more" — cannot notice the end on its own. A request
    // that starts past the last entry returns nothing, so the fetched count
    // stops moving and the heuristic keeps saying yes. Without an explicit end
    // marker the picker would offer to load more forever, and every tap would
    // fire another request that also returns nothing.

    test('a slice that came back short ends the listing', () {
      expect(const PlaylistPaging(endReached: true).hasMore, isFalse);
    });

    test('the end beats even a total that says there is more', () {
      // A stale total is worse than none: it would keep a dead button alive.
      const paging = PlaylistPaging(
        fetched: 200,
        totalCount: 5000,
        endReached: true,
      );
      expect(paging.hasMore, isFalse);
      expect(paging.truncationNotice(200), isNull);
    });

    test('a full slice with no end marker still offers more', () {
      expect(const PlaylistPaging(fetched: 200).hasMore, isTrue);
    });

    test('an empty resumed slice ends the listing', () {
      // The failure this guards: 200 fetched, then a request from 201 that
      // returns zero entries. The count is unchanged, so only [endReached] can
      // say the collection is finished.
      const first = PlaylistPaging(startedAt: 1, fetched: 200);
      const emptySlice = PlaylistPaging(
        startedAt: 201,
        fetched: 0,
        endReached: true,
      );

      expect(first.hasMore, isTrue);
      final merged = first.appended(emptySlice);
      expect(merged.fetched, 200, reason: 'nothing new arrived');
      expect(merged.hasMore, isFalse, reason: 'so the button must go away');
      expect(merged.truncationNotice(200), isNull);
    });

    test('the end survives being merged in either order', () {
      const ended = PlaylistPaging(fetched: 0, endReached: true);
      const open = PlaylistPaging(fetched: 200);
      expect(ended.appended(open).endReached, isTrue);
      expect(open.appended(ended).endReached, isTrue);
    });

    test('a slice reporting no end leaves the listing open', () {
      final merged = const PlaylistPaging(fetched: 200)
          .appended(const PlaylistPaging(startedAt: 201, fetched: 200));
      expect(merged.fetched, 400);
      expect(merged.hasMore, isTrue);
    });
  });
}
