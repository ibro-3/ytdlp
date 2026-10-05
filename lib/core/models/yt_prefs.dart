/// First-class controls for the yt-dlp capabilities the UI does not otherwise
/// model.
///
/// Everything here is also reachable through the raw extra-arguments field, but
/// a hand-typed flag is a poor substitute for a control that has to be right:
/// `--concurrent-fragments 16` on a phone with 2 GB of RAM can fail the
/// download outright, and `--extract-audio` silently does nothing useful
/// without a matching `--audio-format`.
///
/// Kept separate from [AppSettings] (the persistent defaults) and
/// [DownloadOptions] (subtitles/thumbnails for one download), because this is
/// the layer in between: app-wide preferences that shape the command line.
class YtPrefs {
  const YtPrefs({
    this.concurrentFragments = 1,
    this.limitRate = '',
    this.proxy = '',
    this.referer = '',
    this.extractAudio = false,
    this.audioFormat = 'm4a',
    this.remuxVideo = '',
    this.embedMetadata = false,
    this.embedChapters = false,
    this.sponsorblockRemove = false,
    this.liveFromStart = false,
    this.downloadArchive = false,
    this.noPart = false,
    this.sleepRequests = 0,
    this.retries = 10,
    this.fragmentRetries = 10,
  });

  /// Parallel fragment downloads for DASH/HLS (`-N`).
  ///
  /// 1 is yt-dlp's own default and the app's previous behaviour. Higher values
  /// help a lot on a good connection and can fail a download on a constrained
  /// device, so the cap is deliberately modest.
  final int concurrentFragments;

  /// Download rate ceiling in yt-dlp's `RATE` syntax (`-r`), e.g. `2M`.
  /// Empty means unlimited.
  final String limitRate;

  /// HTTP/SOCKS proxy URL (`--proxy`).
  final String proxy;

  /// `Referer` header, required by some hosts (`--referer`).
  final String referer;

  /// Re-encode to an audio-only container (`-x`).
  final bool extractAudio;

  /// Target container for [extractAudio] (`--audio-format`).
  final String audioFormat;

  /// Change container without re-encoding (`--remux-video`), e.g. `mkv`.
  final String remuxVideo;

  /// Write title/artist/etc. into the file (`--embed-metadata`).
  final bool embedMetadata;

  /// Write chapter markers in (`--embed-chapters`).
  final bool embedChapters;

  /// Cut out sponsor segments (`--sponsorblock-remove`).
  final bool sponsorblockRemove;

  /// Record a livestream from its start rather than joining live
  /// (`--live-from-start`).
  final bool liveFromStart;

  /// Skip anything already recorded in the archive file
  /// (`--download-archive`).
  final bool downloadArchive;

  /// Write straight to the final name instead of a `.part` file
  /// (`--no-part`). Trades resumability for a visible file during download.
  final bool noPart;

  /// Seconds to wait between requests (`--sleep-requests`). 0 = no delay.
  final int sleepRequests;

  /// Retries for HTTP failures (`--retries`). The default of 10 is yt-dlp's.
  final int retries;

  /// Retries for individual DASH/HLS fragments (`--fragment-retries`).
  final int fragmentRetries;

  /// Fragment parallelism bounds. Above 4 the gain is small and the memory
  /// cost is not, so the picker stops there.
  static const int maxConcurrentFragments = 4;

  static const int minRetries = 0;
  static const int maxRetries = 20;

  /// Containers yt-dlp can extract audio into without extra encoders.
  static const List<String> audioFormats = [
    'm4a', // stream copy of AAC, the safe default
    'mp3',
    'opus',
    'flac',
    'wav',
  ];

  /// Containers a remux can target without re-encoding.
  static const List<String> remuxFormats = ['mkv', 'mp4', 'webm'];

  /// Containers that can carry an embedded thumbnail and chapter markers.
  ///
  /// MP4 cannot hold a cover image in the way MP3/FLAC/M4A metadata readers
  /// expect, so those toggles are gated on a container that can.
  static const Set<String> embeddableContainers = {
    'm4a',
    'mp3',
    'flac',
    'opus',
    'ogg',
    'mkv',
    'webm',
    'mka',
  };

  /// Whether the file this configuration produces can carry a cover image.
  bool get canEmbedThumbnail {
    final target = (extractAudio ? audioFormat : remuxVideo).toLowerCase();
    // No conversion means the source container decides, which the format sheet
    // already accounts for.
    if (target.isEmpty) return true;
    return embeddableContainers.contains(target);
  }

  /// Whether anything here needs ffmpeg, i.e. postprocessing.
  ///
  /// Remux, extract-audio, metadata and chapter embedding all run through
  /// yt-dlp's postprocessor, which probes with ffprobe. Offering them without
  /// it would produce a download that fails with "ffprobe not found".
  bool get needsPostprocessing =>
      extractAudio ||
      remuxVideo.isNotEmpty ||
      embedMetadata ||
      embedChapters ||
      sponsorblockRemove;

  Map<String, dynamic> toMap() => {
    'concurrentFragments': concurrentFragments,
    'limitRate': limitRate,
    'proxy': proxy,
    'referer': referer,
    'extractAudio': extractAudio,
    'audioFormat': audioFormat,
    'remuxVideo': remuxVideo,
    'embedMetadata': embedMetadata,
    'embedChapters': embedChapters,
    'sponsorblockRemove': sponsorblockRemove,
    'liveFromStart': liveFromStart,
    'downloadArchive': downloadArchive,
    'noPart': noPart,
    'sleepRequests': sleepRequests,
    'retries': retries,
    'fragmentRetries': fragmentRetries,
  };

  factory YtPrefs.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const YtPrefs();
    return YtPrefs(
      concurrentFragments: _clampFragments(
        (m['concurrentFragments'] as num?)?.toInt(),
      ),
      limitRate: m['limitRate'] as String? ?? '',
      proxy: m['proxy'] as String? ?? '',
      referer: m['referer'] as String? ?? '',
      extractAudio: m['extractAudio'] as bool? ?? false,
      audioFormat: _validFormat(m['audioFormat'], audioFormats, 'm4a'),
      remuxVideo: _validFormat(m['remuxVideo'], remuxFormats, ''),
      embedMetadata: m['embedMetadata'] as bool? ?? false,
      embedChapters: m['embedChapters'] as bool? ?? false,
      sponsorblockRemove: m['sponsorblockRemove'] as bool? ?? false,
      liveFromStart: m['liveFromStart'] as bool? ?? false,
      downloadArchive: m['downloadArchive'] as bool? ?? false,
      noPart: m['noPart'] as bool? ?? false,
      sleepRequests: ((m['sleepRequests'] as num?)?.toInt() ?? 0).clamp(0, 60),
      retries: ((m['retries'] as num?)?.toInt() ?? 10).clamp(
        minRetries,
        maxRetries,
      ),
      fragmentRetries: ((m['fragmentRetries'] as num?)?.toInt() ?? 10).clamp(
        minRetries,
        maxRetries,
      ),
    );
  }

  /// Clamps a stored fragment count into the supported range, so an
  /// out-of-range value from a future build or a hand-edited box cannot reach
  /// the command line.
  static int _clampFragments(int? value) {
    return (value ?? 1).clamp(1, maxConcurrentFragments);
  }

  /// Accepts a stored format only when it is one the app offers, so an unknown
  /// value cannot produce a nonsense `--audio-format`.
  static String _validFormat(
    String? value,
    List<String> allowed,
    String fallback,
  ) {
    final v = (value ?? '').toLowerCase();
    return allowed.contains(v) ? v : fallback;
  }

  YtPrefs copyWith({
    int? concurrentFragments,
    String? limitRate,
    String? proxy,
    String? referer,
    bool? extractAudio,
    String? audioFormat,
    String? remuxVideo,
    bool? embedMetadata,
    bool? embedChapters,
    bool? sponsorblockRemove,
    bool? liveFromStart,
    bool? downloadArchive,
    bool? noPart,
    int? sleepRequests,
    int? retries,
    int? fragmentRetries,
  }) {
    return YtPrefs(
      concurrentFragments: _clampFragments(
        concurrentFragments ?? this.concurrentFragments,
      ),
      limitRate: limitRate ?? this.limitRate,
      proxy: proxy ?? this.proxy,
      referer: referer ?? this.referer,
      extractAudio: extractAudio ?? this.extractAudio,
      audioFormat: audioFormat ?? this.audioFormat,
      remuxVideo: remuxVideo ?? this.remuxVideo,
      embedMetadata: embedMetadata ?? this.embedMetadata,
      embedChapters: embedChapters ?? this.embedChapters,
      sponsorblockRemove: sponsorblockRemove ?? this.sponsorblockRemove,
      liveFromStart: liveFromStart ?? this.liveFromStart,
      downloadArchive: downloadArchive ?? this.downloadArchive,
      noPart: noPart ?? this.noPart,
      sleepRequests: sleepRequests ?? this.sleepRequests,
      retries: (retries ?? this.retries).clamp(minRetries, maxRetries),
      fragmentRetries: (fragmentRetries ?? this.fragmentRetries).clamp(
        minRetries,
        maxRetries,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is YtPrefs &&
      other.concurrentFragments == concurrentFragments &&
      other.limitRate == limitRate &&
      other.proxy == proxy &&
      other.referer == referer &&
      other.extractAudio == extractAudio &&
      other.audioFormat == audioFormat &&
      other.remuxVideo == remuxVideo &&
      other.embedMetadata == embedMetadata &&
      other.embedChapters == embedChapters &&
      other.sponsorblockRemove == sponsorblockRemove &&
      other.liveFromStart == liveFromStart &&
      other.downloadArchive == downloadArchive &&
      other.noPart == noPart &&
      other.sleepRequests == sleepRequests &&
      other.retries == retries &&
      other.fragmentRetries == fragmentRetries;

  @override
  int get hashCode => Object.hashAll([
    concurrentFragments,
    limitRate,
    proxy,
    referer,
    extractAudio,
    audioFormat,
    remuxVideo,
    embedMetadata,
    embedChapters,
    sponsorblockRemove,
    liveFromStart,
    downloadArchive,
    noPart,
    sleepRequests,
    retries,
    fragmentRetries,
  ]);
}
