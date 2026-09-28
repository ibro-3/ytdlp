import '../utils/json_utils.dart';
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
    this.uploader,
    this.entries = const [],
    this.hasFfmpeg = false,
    this.canPostprocess = false,
  });

  final String id;
  final String title;
  final String webUrl;
  final String? uploader;
  final List<VideoInfo> entries;

  /// Device capability flags, copied from the device-wide probe so the batch
  /// options UI can gate embed toggles the same way the single-video sheet
  /// does. Flat entries carry no formats, so these cannot be derived per entry.
  final bool hasFfmpeg;
  final bool canPostprocess;

  int get count => entries.length;

  bool get isEmpty => entries.isEmpty;

  /// Sum of the entries whose duration is known. Entries without a duration
  /// (live streams, some extractors) contribute nothing, so this is a lower
  /// bound rather than an exact total.
  int get totalDuration => entries.fold(0, (sum, e) => sum + e.duration);

  /// Builds a format list for a whole batch from a quality tier, mirroring the
  /// selectors the single-video path produces in [VideoInfo].
  ///
  /// `tier` is a height in pixels for video (null = best available) and a
  /// bitrate ceiling in kbps for audio.
  List<Format> formatsFor({required FormatKind kind, int? tier}) {
    return [
      switch (kind) {
        FormatKind.video => videoFormatForTier(tier, hasFfmpeg: hasFfmpeg),
        FormatKind.audio => audioFormatForTier(tier),
      },
    ];
  }

  factory PlaylistInfo.fromYtdlpJson(
    Map<String, dynamic> j, {
    required bool hasFfmpeg,
    required bool canPostprocess,
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

    return PlaylistInfo(
      id: (j['id'] as String?) ?? '',
      title: (j['title'] as String?) ?? 'Untitled playlist',
      webUrl: (j['webpage_url'] ?? j['original_url'] ?? '') as String,
      uploader:
          (j['uploader'] ?? j['channel'] ?? j['playlist_uploader']) as String?,
      entries: entries,
      hasFfmpeg: hasFfmpeg,
      canPostprocess: canPostprocess,
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
