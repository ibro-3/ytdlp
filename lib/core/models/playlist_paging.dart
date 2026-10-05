/// Where a listing sits inside a collection that may be larger than one
/// response.
///
/// A channel has no defined end, and the JSON for tens of thousands of entries
/// does not fit the metadata byte budget, so the app asks for one slice at a
/// time and merges the slices. This records what has been seen so the UI can
/// say "showing the first N of M" out loud — a truncated list presented as a
/// complete one would have the user believe a 5,000-video channel holds 200
/// videos, which is the specific failure the paging exists to prevent.
class PlaylistPaging {
  const PlaylistPaging({
    this.startedAt = 1,
    this.fetched = 0,
    this.totalCount,
    this.endReached = false,
  });

  /// Nothing has been fetched yet.
  static const empty = PlaylistPaging();

  /// 1-based index of the first entry the collection asked for.
  final int startedAt;

  /// Entries the source returned for the slices fetched so far, counted
  /// *before* unavailable entries were dropped.
  ///
  /// Deliberately the raw count and not the number of listed rows. Unavailable
  /// entries still occupied a slot upstream, so resuming from a filtered count
  /// would re-request items already seen — and on a collection with many
  /// private videos, walk backwards indefinitely.
  final int fetched;

  /// Entries in the whole collection, when the extractor reports one.
  ///
  /// Null means "unknown", not "none": extractors differ in whether they expose
  /// a total for a channel tab, and a null here must never read as "that is all
  /// of them".
  final int? totalCount;

  /// Whether a slice has come back short, which is the only end-of-collection
  /// signal available when no total is reported.
  ///
  /// Needed because [fetched] cannot express the end on its own: a request that
  /// starts past the last entry returns nothing, so [fetched] stops growing and
  /// the "a full slice means there may be more" heuristic would go on offering
  /// more forever.
  final bool endReached;

  /// 1-based index to pass as `--playlist-start` for the next slice.
  int get nextStart => startedAt + fetched;

  /// Whether another slice is worth asking for.
  ///
  /// A known [totalCount] answers this exactly. Otherwise it is inferred from
  /// the shape of the responses: a slice that came back short means the
  /// collection ended, and a full slice means there may be more — so the UI
  /// offers to load rather than claiming the list is complete.
  bool get hasMore {
    if (endReached) return false;
    return totalCount != null
        ? nextStart <= totalCount!
        : fetched >= PlaylistPaging.sliceSize;
  }

  /// The paging state after [next], another slice of the same collection.
  PlaylistPaging appended(PlaylistPaging next) => PlaylistPaging(
    startedAt: startedAt,
    fetched: fetched + next.fetched,
    // The newest total wins; a slice that does not report one cannot retract
    // what an earlier slice already established.
    totalCount: next.totalCount ?? totalCount,
    // Either slice seeing the end is enough, and it cannot be un-seen, so this
    // is an or rather than a replacement.
    endReached: endReached || next.endReached,
  );

  /// How many entries one listing request asks for.
  ///
  /// Large enough that an ordinary channel needs a single request, small
  /// enough that a full slice stays quick to parse and well inside the stdout
  /// budget.
  static const sliceSize = 200;

  /// What to tell the user when the listing is not the whole collection.
  ///
  /// [visibleCount] is the number of rows actually on screen, which is
  /// deliberately *not* [fetched]: entries dropped as unavailable are fetched
  /// but never listed, and quoting the raw count would tell the user they can
  /// see a video they cannot.
  ///
  /// Returns null when nothing is being withheld. Where there are more but the
  /// site never said how many, the wording states only what is known rather
  /// than inventing a total.
  String? truncationNotice(int visibleCount) {
    if (!hasMore) return null;
    final total = totalCount;
    if (total != null && total > visibleCount) {
      return 'Showing the first $visibleCount of $total';
    }
    return 'Showing the first $visibleCount — load more to see the rest';
  }
}
