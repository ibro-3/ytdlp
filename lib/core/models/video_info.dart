import '../utils/formatters.dart';
import '../utils/json_utils.dart';

enum FormatKind { video, audio }

class Format {
  const Format({
    required this.kind,
    required this.label,
    required this.selector,
    this.tier,
    this.filesize,
  });

  final FormatKind kind;
  final String label;
  final String selector;
  final int? tier;
  final int? filesize;
}

/// One subtitle/caption track offered by the source, keyed by language.
class SubtitleTrack {
  const SubtitleTrack({
    required this.lang,
    required this.name,
    required this.isAutoOnly,
    required this.exts,
  });

  /// ISO language code, e.g. `en`.
  final String lang;

  /// Human-readable name, e.g. `English`.
  final String name;

  /// Only machine-generated captions (`automatic_captions`) exist for this
  /// language — there is no manually authored subtitle track.
  final bool isAutoOnly;

  /// Extensions yt-dlp can deliver for this track (srt/vtt/ttml/…). Manual
  /// tracks usually offer srt; auto-generated ones are often vtt-only.
  final List<String> exts;

  bool get hasSrt => exts.contains('srt');
}

/// Display names for the most common subtitle languages, shown first in the
/// picker. Languages outside this map keep their ISO code.
const Map<String, String> commonSubtitleLanguages = {
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'pt': 'Portuguese',
  'it': 'Italian',
  'ar': 'Arabic',
  'hi': 'Hindi',
  'ja': 'Japanese',
  'ko': 'Korean',
  'ru': 'Russian',
  'tr': 'Turkish',
  'pl': 'Polish',
  'nl': 'Dutch',
  'vi': 'Vietnamese',
  'id': 'Indonesian',
  'th': 'Thai',
  'zh': 'Chinese',
  'uk': 'Ukrainian',
  'sv': 'Swedish',
};

class VideoInfo {
  const VideoInfo({
    required this.id,
    required this.title,
    required this.webUrl,
    this.author,
    this.duration = 0,
    this.uploadDate,
    this.thumbnail,
    this.hasFfmpeg = false,
    // Defaults to [hasFfmpeg] because they coincide on desktop, where a system
    // ffmpeg always ships ffprobe beside it. They can differ on Android, where
    // the bundled pair may be incomplete, so callers that know should say so.
    bool? canPostprocess,
    this.videoFormats = const [],
    this.audioFormats = const [],
    this.subtitleTracks = const [],
  }) : canPostprocess = canPostprocess ?? hasFfmpeg;

  final String id;
  final String title;
  final String webUrl;
  final String? author;
  final int duration;
  final DateTime? uploadDate;
  final String? thumbnail;

  /// Whether the app can reach ffmpeg (bundled on Android, PATH on desktop).
  /// Deciding between split streams that must be merged and single-file
  /// combined streams depends on it.
  final bool hasFfmpeg;

  /// Whether yt-dlp can run *postprocessing* here — embedding subtitles or a
  /// thumbnail cover, converting subtitle formats.
  ///
  /// This is stricter than [hasFfmpeg]: it also needs **ffprobe**, which yt-dlp
  /// uses to probe the output. Merging only needs ffmpeg, so the two can differ
  /// (notably on Android, where the bundled pair may be incomplete). Offering
  /// the embed toggles when this is false would produce a download that fails
  /// with "Postprocessing: ffprobe not found".
  final bool canPostprocess;

  final List<Format> videoFormats;
  final List<Format> audioFormats;

  /// Subtitle/caption tracks the source offers, common languages first.
  final List<SubtitleTrack> subtitleTracks;

  /// Number of tracks surfaced directly; an "all languages" option covers
  /// the rest so the sheet stays compact.
  static const int subtitleTrackLimit = 8;

  factory VideoInfo.fromYtdlpJson(
    Map<String, dynamic> j, {
    required bool hasFfmpeg,
    // Defaults to [hasFfmpeg] because they coincide on desktop, where a system
    // ffmpeg always ships ffprobe beside it. They can differ on Android, where
    // the bundled pair may be incomplete, so callers that know should say so.
    bool? canPostprocess,
  }) {
    final rawFormats = jsonList<Map<String, dynamic>>(j['formats']);

    // Prefer yt-dlp's own pick (a .jpg for YouTube) over the last raw
    // thumbnail entry, which is often a maxresdefault.webp that 404s on
    // older videos.
    var thumb = jsonString(j['thumbnail']);
    if (thumb == null) {
      final thumbs = jsonList<Object>(j['thumbnails']);
      if (thumbs.isNotEmpty) {
        final last = jsonMap(thumbs.last);
        thumb = jsonString(last['url']);
      }
    }

    return VideoInfo(
      id: jsonString(j['id']) ?? '',
      title: jsonString(j['title']) ?? 'Untitled video',
      // `url` is the last resort: in a full extraction it is the direct media
      // URL and is shadowed by `webpage_url`, but a `--flat-playlist` entry
      // only carries `url`, and that is exactly what has to be downloaded.
      webUrl:
          jsonString(j['webpage_url']) ??
          jsonString(j['original_url']) ??
          jsonString(j['url']) ??
          '',
      author: jsonString(j['uploader']) ?? jsonString(j['channel']),
      duration: jsonNum(j['duration'])?.round() ?? 0,
      uploadDate: parseUploadDate(jsonString(j['upload_date'])),
      thumbnail: thumb,
      hasFfmpeg: hasFfmpeg,
      canPostprocess: canPostprocess ?? hasFfmpeg,
      videoFormats: _buildVideoFormats(rawFormats, hasFfmpeg),
      audioFormats: _buildAudioFormats(rawFormats),
      subtitleTracks: _parseSubtitleTracks(j),
    );
  }

  /// Merges `subtitles` (manual) and `automatic_captions` (auto) into one
  /// list per language, ordered with the common languages first.
  static List<SubtitleTrack> _parseSubtitleTracks(Map<String, dynamic> j) {
    final byLang = <String, ({Set<String> exts, bool manual})>{};

    void merge(Object? source, {required bool manual}) {
      if (source is! Map) return;
      for (final MapEntry(:key, :value) in source.entries) {
        if (key is! String) continue;
        final formats = jsonList<Object>(value);
        final exts = formats
            .map((f) => jsonString(jsonMap(f)['ext']) ?? '')
            .where((e) => e.isNotEmpty)
            .toSet();
        if (exts.isEmpty) continue;
        final cur = byLang[key];
        byLang[key] = (
          exts: {...?cur?.exts, ...exts},
          manual: cur?.manual ?? manual,
        );
      }
    }

    merge(j['subtitles'], manual: true);
    merge(j['automatic_captions'], manual: false);

    final tracks = <SubtitleTrack>[];
    final emitted = <String>{};

    void emit(String lang, Set<String> exts, bool manual) {
      if (!emitted.add(lang)) return;
      tracks.add(
        SubtitleTrack(
          lang: lang,
          name: commonSubtitleLanguages[lang] ?? lang,
          isAutoOnly: !manual,
          exts: exts.toList()..sort(),
        ),
      );
    }

    // Common languages first, in a stable priority order.
    for (final lang in commonSubtitleLanguages.keys) {
      final entry = byLang[lang];
      if (entry != null) emit(lang, entry.exts, entry.manual);
    }
    // Whatever else the site offers, in insertion order.
    for (final MapEntry(:key, :value) in byLang.entries) {
      emit(key, value.exts, value.manual);
    }

    return tracks.take(subtitleTrackLimit).toList();
  }

  static bool _isCombined(Map<String, dynamic> f) {
    final v = f['vcodec'] as String?;
    final a = f['acodec'] as String?;
    return v != null && v != 'none' && a != null && a != 'none';
  }

  static bool _hasVideo(Map<String, dynamic> f) {
    final v = f['vcodec'] as String?;
    return v != null && v != 'none';
  }

  static List<Format> _buildVideoFormats(
    List<Map<String, dynamic>> formats,
    bool hasFfmpeg,
  ) {
    // YouTube (and others) mostly serve split streams now: video-only +
    // audio-only with zero combined formats. With ffmpeg we merge, so every
    // video-bearing stream is a candidate. Without ffmpeg only single-file
    // combined streams are playable.
    final pool = hasFfmpeg
        ? formats.where(_hasVideo).toList()
        : formats.where(_isCombined).toList();
    if (pool.isEmpty) return [];

    final heights =
        pool
            .map((f) => (f['height'] as num?)?.toInt() ?? 0)
            .where((h) => h > 0)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    final best = heights.isEmpty ? null : heights.first;

    final result = <Format>[
      _videoFormat(
        pool,
        null,
        formats,
        hasFfmpeg: hasFfmpeg,
        labelBase: 'Best quality',
      ),
    ];
    // One row per distinct source resolution below the best one, so labels
    // always match what the selector will actually pick (no fake "2160p"
    // rows above the video's real max resolution).
    for (final h in heights) {
      if (result.length >= 7) break;
      if (best != null && h >= best) continue;
      result.add(
        _videoFormat(
          pool,
          h,
          formats,
          hasFfmpeg: hasFfmpeg,
          labelBase: '${h}p',
        ),
      );
    }
    return result;
  }

  static Format _videoFormat(
    List<Map<String, dynamic>> candidates,
    int? maxHeight,
    List<Map<String, dynamic>> allFormats, {
    required bool hasFfmpeg,
    required String labelBase,
  }) {
    var pool = candidates;
    if (maxHeight != null) {
      pool = pool
          .where((f) => ((f['height'] as num?)?.toInt() ?? 0) <= maxHeight)
          .toList();
    }
    pool = List.of(pool)
      ..sort((a, b) {
        final c = ((b['height'] as num?)?.toInt() ?? 0).compareTo(
          (a['height'] as num?)?.toInt() ?? 0,
        );
        if (c != 0) return c;
        final aIsMp4 = (a['ext'] == 'mp4') ? 0 : 1;
        final bIsMp4 = (b['ext'] == 'mp4') ? 0 : 1;
        return aIsMp4.compareTo(bIsMp4);
      });

    final best = pool.isEmpty ? null : pool.first;
    final h = (best?['height'] as num?)?.toInt();
    final filesize = best?['filesize'] ?? best?['filesize_approx'];

    final selector = hasFfmpeg
        ? (h == null ? 'bv*+ba/b' : 'bv*[height<=$h]+ba/b[height<=$h]/b')
        : (h == null
              ? 'b[ext=mp4][acodec!=none]/b[acodec!=none]'
              : 'b[height<=$h][ext=mp4][acodec!=none]/'
                    'b[height<=$h][acodec!=none]');

    // Only claim a container when it is unambiguous for the row's streams.
    final container = _containerLabel(pool, allFormats, hasFfmpeg);
    final size = filesize is num ? filesize : null;
    final sizeLabel = size == null ? '' : ' · ${formatBytes(size)}';

    return Format(
      kind: FormatKind.video,
      label: '$labelBase · $container$sizeLabel',
      selector: selector,
      tier: h,
      filesize: size?.toInt(),
    );
  }

  /// Best-effort container label for a row. With ffmpeg the output
  /// container is decided by merging the row's video stream with the best
  /// audio stream, so we only claim MP4/WebM when every involved stream is
  /// that container, otherwise we say MKV (yt-dlp's generic fallback).
  static String _containerLabel(
    List<Map<String, dynamic>> rowPool,
    List<Map<String, dynamic>> allFormats,
    bool hasFfmpeg,
  ) {
    final exts = <String>{};
    for (final f in rowPool) {
      final e = f['ext'];
      if (e is String && e.isNotEmpty) exts.add(e);
    }
    if (!hasFfmpeg) {
      if (exts.every((e) => e == 'mp4')) return 'MP4';
      if (exts.every((e) => e == 'webm')) return 'WebM';
      return 'MKV';
    }
    for (final f in allFormats) {
      final v = f['vcodec'] as String?;
      final a = f['acodec'] as String?;
      final isAudio = (v == null || v == 'none') && a != null && a != 'none';
      if (isAudio) {
        final e = f['ext'];
        if (e is String && e.isNotEmpty) exts.add(e);
      }
    }
    if (exts.every((e) => e == 'mp4' || e == 'm4a')) return 'MP4';
    if (exts.every((e) => e == 'webm')) return 'WebM';
    return 'MKV';
  }

  /// Named quality tiers for audio downloads, best first. [target] is the
  /// bitrate ceiling in kbps; null means "best available" with no ceiling.
  static const List<(String, int?)> audioTiers = [
    ('Best audio', null),
    ('High', 192),
    ('Medium', 128),
    ('Low', 96),
  ];

  static List<Format> _buildAudioFormats(List<Map<String, dynamic>> formats) {
    final audio = formats.where(_isAudioOnly).toList();
    if (audio.isEmpty) return const [];

    // Prefer M4A (AAC) for convenience and compatibility, exactly like the
    // historical single "M4A · Best audio" row. Sites without m4a fall back
    // to their best audio container (Opus/MP3/…).
    final m4a = audio.where((f) => f['ext'] == 'm4a').toList();
    final pool = m4a.isNotEmpty ? m4a : audio;
    final sorted = _sortAudioBestFirst(pool);
    final best = sorted.first;

    final rows = <Format>[];
    final seenIds = <String>{};
    for (final (name, target) in audioTiers) {
      final picked = _resolveAudioTier(sorted, best, target);
      final id = picked['format_id'] as String?;
      // A tier is only interesting when it delivers a stream we have not
      // already offered — sites with two distinct bitrates (YouTube) would
      // otherwise show four rows for the same two files, and a tier whose
      // fallback reuses an earlier tier's stream would too.
      if (id != null && !seenIds.add(id)) continue;
      final size = picked['filesize'] ?? picked['filesize_approx'];
      final sizeLabel = size is num ? ' · ${formatBytes(size)}' : '';
      rows.add(
        Format(
          kind: FormatKind.audio,
          label: '${_audioRowLabel(name, picked)}$sizeLabel',
          selector: _audioSelector(pool, target),
          tier: target,
          filesize: size is num ? size.toInt() : null,
        ),
      );
    }
    return rows;
  }

  /// The stream a tier's selector would actually pick: the best one at or
  /// below [target], falling back to the best overall (yt-dlp's `/ba` tail).
  static Map<String, dynamic> _resolveAudioTier(
    List<Map<String, dynamic>> sortedBestFirst,
    Map<String, dynamic> best,
    int? target,
  ) {
    if (target == null) return best;
    for (final f in sortedBestFirst) {
      if (_audioBitrate(f) <= target) return f;
    }
    return best;
  }

  static List<Map<String, dynamic>> _sortAudioBestFirst(
    List<Map<String, dynamic>> pool,
  ) => List.of(pool)
    ..sort((a, b) {
      final c = _audioBitrate(b).compareTo(_audioBitrate(a));
      if (c != 0) return c;
      final aM4a = a['ext'] == 'm4a' ? 0 : 1;
      final bM4a = b['ext'] == 'm4a' ? 0 : 1;
      return aM4a.compareTo(bM4a);
    });

  /// A stream's audio bitrate in kbps (`abr`), falling back to the total
  /// bitrate for audio-only streams that report only `tbr`.
  static double _audioBitrate(Map<String, dynamic> f) =>
      (f['abr'] as num?)?.toDouble() ?? (f['tbr'] as num?)?.toDouble() ?? 0;

  static bool _isAudioOnly(Map<String, dynamic> f) {
    final v = f['vcodec'] as String?;
    final a = f['acodec'] as String?;
    return (v == null || v == 'none') && a != null && a != 'none';
  }

  static String _audioRowLabel(String tierName, Map<String, dynamic> picked) {
    final abr = _audioBitrate(picked).round();
    final ext = picked['ext'] as String? ?? 'audio';
    final extLabel = switch (ext) {
      'm4a' => 'M4A',
      'webm' => 'WebM',
      'opus' => 'Opus',
      'ogg' => 'OGG',
      'mp3' => 'MP3',
      'aac' => 'AAC',
      _ => ext.toUpperCase(),
    };
    return '$tierName · $extLabel · ${abr}kbps';
  }

  /// Selector for a tier, preferring m4a when the site offers it so the
  /// fallback behaves the same as the historical `ba[ext=m4a]/ba` row.
  static String _audioSelector(List<Map<String, dynamic>> pool, int? target) {
    final isM4a = pool.any((f) => f['ext'] == 'm4a');
    if (target == null) return isM4a ? 'ba[ext=m4a]/ba' : 'ba/b';
    return isM4a
        ? 'ba[ext=m4a][abr<=$target]/ba[ext=m4a]'
        : 'ba[abr<=$target]/ba';
  }
}
