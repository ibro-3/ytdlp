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
  final bool embedThumb;

  /// Save the thumbnail as a sidecar .jpg next to the media file.
  final bool writeThumb;

  bool get subsEnabled => embedSubs || writeSubs;

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
