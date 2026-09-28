import 'video_info.dart';

/// Per-download extras chosen in the format sheet: subtitles and thumbnails.
///
/// Seeded from `AppSettings` defaults every time the sheet opens, then
/// captured on the [DownloadTask] so a restored or retried download repeats
/// the same choices.
class DownloadOptions {
  const DownloadOptions({
    this.embedSubs = false,
    this.writeSubs = false,
    this.includeAutoSubs = false,
    this.subLanguages = const [],
    this.embedThumb = false,
    this.writeThumb = false,
  });

  /// Embed subtitles into the media file (requires ffmpeg; video mode only).
  final bool embedSubs;

  /// Save subtitles as a sidecar (.srt/.vtt) next to the media file.
  final bool writeSubs;

  /// Also fetch machine-generated (`automatic_captions`) tracks.
  final bool includeAutoSubs;

  /// Explicitly chosen languages. Empty means "all available".
  final List<String> subLanguages;

  /// Embed the thumbnail as cover art (requires ffmpeg).
  ///
  /// No longer user-settable — see [coverArtDefault], which is what every
  /// enqueue site now uses. The field stays because it is persisted on a task,
  /// so a download queued before the toggle was removed still embeds.
  final bool embedThumb;

  /// Save the thumbnail as a sidecar .jpg next to the media file.
  ///
  /// Unreachable from the UI for the same reason as [embedThumb], and kept
  /// working so a task restored from an older snapshot still gets its sidecar.
  final bool writeThumb;

  bool get subsEnabled => embedSubs || writeSubs;

  /// Whether a download of this kind embeds the thumbnail as cover art.
  ///
  /// There is no toggle for this: an audio file is expected to carry cover art
  /// (music players show it as the album art, and without it a downloaded track
  /// looks broken in a library view), while a video file's cover art is at best
  /// redundant with the frame you see when you open it, and at worst forces a
  /// container change — yt-dlp warns "mkv will be used" for an MP4 that cannot
  /// hold an image. So audio embeds, video does not.
  ///
  /// Still gated downstream on ffmpeg being reachable and on the target
  /// container being able to hold an image, so this says *what should happen*,
  /// not that it always will.
  static bool coverArtDefault(FormatKind kind) => kind == FormatKind.audio;

  /// Value handed to yt-dlp's `--sub-langs`.
  String get subLangsTarget =>
      subLanguages.isEmpty ? 'all' : subLanguages.join(',');

  Map<String, dynamic> toMap() => {
    'embedSubs': embedSubs,
    'writeSubs': writeSubs,
    'includeAutoSubs': includeAutoSubs,
    'subLanguages': subLanguages,
    'embedThumb': embedThumb,
    'writeThumb': writeThumb,
  };

  factory DownloadOptions.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const DownloadOptions();
    return DownloadOptions(
      embedSubs: (m['embedSubs'] as bool?) ?? false,
      writeSubs: (m['writeSubs'] as bool?) ?? false,
      includeAutoSubs: (m['includeAutoSubs'] as bool?) ?? false,
      subLanguages:
          (m['subLanguages'] as List?)?.whereType<String>().toList() ??
          const [],
      embedThumb: (m['embedThumb'] as bool?) ?? false,
      writeThumb: (m['writeThumb'] as bool?) ?? false,
    );
  }
}
