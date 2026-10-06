import '../utils/json_utils.dart';
import 'collection_kind.dart';
import 'playlist_paging.dart';
import 'video_info.dart';

/// A playlist (or channel) collection returned by yt-dlp.
///
/// Entries are [VideoInfo]s built from a *flat* extraction: they carry the
/// metadata needed to list and download an item (id, title, URL, thumbnail,
/// duration) but **no format lists**, because `--flat-playlist` never asks the
/// extractor to enumerate streams. That is deliberate — it keeps the response
/// small (a flat entry is a few hundred bytes, so even a 10k-item channel fits
/// the metadata budget) and fast.
///
/// Because a flat entry has no stream data, the quality for a batch download
/// comes from the user's saved tier rather than from the source, see
/// [videoFormatForTier] / [audioFormatForTier].
class PlaylistInfo {
  const PlaylistInfo({
    required this.id,
    required this.title,
    required this.webUrl,
    this.kind = CollectionKind.playlist,
    this.uploader,
    this.entries = const [],
    this.hasFfmpeg = false,
    this.canPostprocess = false,
    this.paging = PlaylistPaging.empty,
  });

  final String id;
  final String title;
  final String webUrl;

  /// Whether this is a curated playlist or a whole channel. See
  /// [resolveCollectionKind] for why the requested link is the evidence.
  final CollectionKind kind;

  final String? uploader;
  final List<VideoInfo> entries;

  /// Device capability flags, copied from the device-wide probe so the batch
  /// options UI can gate embed toggles the same way the single-video sheet
  /// does. Flat entries carry no formats, so these cannot be derived per entry.
  final bool hasFfmpeg;
  final bool canPostprocess;

  /// How much of the collection [entries] covers. A complete curated playlist
  /// leaves this [PlaylistPaging.empty]; a channel that was listed one slice at
  /// a time carries the cursor needed to fetch the next one.
  final PlaylistPaging paging;

  int get count => entries.length;

  bool get isEmpty => entries.isEmpty;

  /// Sum of the entries whose duration is known. Entries without a duration
  /// (live streams, some extractors) contribute nothing, so this is a lower
  /// bound rather than an exact total.
  int get totalDuration => entries.fold(0, (sum, e) => sum + e.duration);

  /// Builds a collection from a `--flat-playlist` payload.
  ///
  /// [requestedUrl] is the link the user gave, which is what decides
  /// [CollectionKind]: see [resolveCollectionKind].
  factory PlaylistInfo.fromYtdlpJson(
    Map<String, dynamic> j, {
    required bool hasFfmpeg,
    required bool canPostprocess,
    String requestedUrl = '',
    PlaylistPaging paging = PlaylistPaging.empty,
  }) {
    final rawEntries = jsonList<Map<String, dynamic>>(j['entries']);

    // yt-dlp marks entries it could not resolve with a `_type` of "url" and a
    // non-null `ie_key` error, or with an `availability` of "private"/"needs
    // auth". Those cannot be downloaded, so they are dropped up front rather
    // than shown as items that will always fail.
    final entries = <VideoInfo>[];
    for (final raw in rawEntries) {
      if (_isUnavailable(raw)) continue;
      final entry = VideoInfo.fromYtdlpJson(
        raw,
        hasFfmpeg: hasFfmpeg,
        canPostprocess: canPostprocess,
      );
      // A flat entry with no resolvable URL cannot be enqueued.
      if (entry.id.isEmpty || entry.webUrl.isEmpty) continue;
      entries.add(entry);
    }

    // The slice that was just fetched, measured from the payload: the raw count
    // rather than `entries.length`, because the cursor has to line up with
    // `--playlist-start`, which upstream indexes before the filtering above.
    final total = _totalCount(j) ?? paging.totalCount;
    final slice = PlaylistPaging(
      startedAt: paging.startedAt,
      fetched: rawEntries.length,
      totalCount: total,
      endReached: _endReached(rawEntries.length, total),
    );

    return PlaylistInfo(
      id: jsonString(j['id']) ?? '',
      title: jsonString(j['title']) ?? 'Untitled playlist',
      // `jsonString` rather than a cast, matching how the rest of the codebase
      // reads this payload. A playlist payload comes from the site, so the shape
      // of a field is not something the app controls, and `as String` on a
      // number would throw mid-fetch.
      webUrl:
          jsonString(j['webpage_url']) ?? jsonString(j['original_url']) ?? '',
      kind: resolveCollectionKind(requestedUrl: requestedUrl, payload: j),
      uploader:
          jsonString(j['uploader']) ??
          jsonString(j['channel']) ??
          jsonString(j['playlist_uploader']),
      entries: entries,
      hasFfmpeg: hasFfmpeg,
      canPostprocess: canPostprocess,
      paging: slice,
    );
  }

  /// The collection size the extractor reported, if it reported one that can be
  /// believed.
  ///
  /// Extractors spell this `playlist_count`; some emit it as a string, some as
  /// a float, and a zero or negative value means "not reported" rather than
  /// "empty", so anything that is not a positive whole number is discarded.
  /// A wrong total would be worse than none, because [PlaylistPaging.hasMore]
  /// trusts it.
  static int? _totalCount(Map<String, dynamic> j) {
    final raw = j['playlist_count'];
    final value = raw is num
        ? raw.toInt()
        : (raw is String ? int.tryParse(raw.trim()) : null);
    return (value != null && value > 0) ? value : null;
  }

  /// Whether this response proves the collection has nothing after it.
  ///
  /// Two different signals, because they are not equally trustworthy.
  ///
  /// A window that came back short only means the end when nothing claimed a
  /// total: with a total in hand the arithmetic already answers the question
  /// exactly, and a short page can just as easily be a response the extractor
  /// cut short. Overriding a stated total on that basis would silently hide
  /// videos the site says are there.
  ///
  /// An empty response means it unconditionally. Asking for entries 201-400 of
  /// a collection that stopped at 200 yields nothing, the fetched count stops
  /// growing, and without this the cursor would sit still and the picker would
  /// offer to load the same missing page forever.
  static bool _endReached(int fetched, int? totalCount) =>
      fetched == 0 ||
      (totalCount == null && fetched < PlaylistPaging.sliceSize);

  /// A copy with [entries] and [paging] replaced, used when another slice of a
  /// paged collection arrives.
  ///
  /// Everything else — id, title, capability flags — comes from the slice that
  /// first resolved the collection and is repeated identically by later ones,
  /// so keeping it is both correct and the only way to keep a queued download's
  /// folder name stable if it is downloaded between slices.
  PlaylistInfo copyWith({List<VideoInfo>? entries, PlaylistPaging? paging}) {
    return PlaylistInfo(
      id: id,
      title: title,
      webUrl: webUrl,
      kind: kind,
      uploader: uploader,
      entries: entries ?? this.entries,
      hasFfmpeg: hasFfmpeg,
      canPostprocess: canPostprocess,
      paging: paging ?? this.paging,
    );
  }

  /// Whether yt-dlp flagged this entry as undownloadable.
  ///
  /// Private and members-only items carry an `availability` verdict; some
  /// extractors also emit `ERROR:` entries in flat mode. Neither is recoverable
  /// by retrying, so they never reach the picker.
  static bool _isUnavailable(Map<String, dynamic> e) {
    final availability = (e['availability'] as String?)?.toLowerCase();
    if (availability != null &&
        availability != 'public' &&
        availability != 'unlisted') {
      return true;
    }
    final err = e['error'] as String?;
    if (err != null && err.isNotEmpty) return true;
    return false;
  }
}

/// Video format for a quality tier chosen by the user rather than derived from
/// a source's stream list.
///
/// The selectors mirror the ones [VideoInfo] generates so a batch download
/// behaves identically to picking the same tier for a single video:
///
/// - with ffmpeg: `bv*[height<=H]+ba/b[height<=H]/b` (merge DASH streams)
/// - without: combined-only MP4, since split streams cannot be merged
///
/// A null [height] means "best available".
Format videoFormatForTier(int? height, {required bool hasFfmpeg}) {
  final label = height == null ? 'Best quality' : '$height p';
  final selector = height == null
      ? (hasFfmpeg ? 'bv*+ba/b' : 'b[ext=mp4][acodec!=none]/b[acodec!=none]')
      : (hasFfmpeg
            ? 'bv*[height<=$height]+ba/b[height<=$height]/b'
            : 'b[height<=$height][ext=mp4][acodec!=none]/'
                  'b[height<=$height][acodec!=none]');
  return Format(
    kind: FormatKind.video,
    label: label,
    selector: selector,
    tier: height,
  );
}

/// Audio format for a tier, preferring M4A exactly like the single-video path.
Format audioFormatForTier(int? target) {
  final label = target == null ? 'Best audio' : '$target kbps';
  final selector = target == null
      ? 'ba[ext=m4a]/ba'
      : 'ba[ext=m4a][abr<=$target]/ba[ext=m4a]';
  return Format(
    kind: FormatKind.audio,
    label: label,
    selector: selector,
    tier: target,
  );
}

/// Total duration of a set of entries, as a display string.
String formatPlaylistDuration(int seconds) {
  if (seconds <= 0) return 'unknown length';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h == 0) return '$m min';
  return '$h h $m min';
}
