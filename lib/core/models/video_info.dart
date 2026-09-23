import '../utils/formatters.dart';

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

class VideoInfo {
  const VideoInfo({
    required this.id,
    required this.title,
    required this.webUrl,
    this.author,
    this.duration = 0,
    this.uploadDate,
    this.thumbnail,
    this.videoFormats = const [],
    this.audioFormats = const [],
  });

  final String id;
  final String title;
  final String webUrl;
  final String? author;
  final int duration;
  final DateTime? uploadDate;
  final String? thumbnail;
  final List<Format> videoFormats;
  final List<Format> audioFormats;

  factory VideoInfo.fromYtdlpJson(
    Map<String, dynamic> j, {
    required bool hasFfmpeg,
  }) {
    final rawFormats =
        (j['formats'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const <Map<String, dynamic>>[];

    String? thumb;
    final thumbs = j['thumbnails'] as List?;
    if (thumbs != null && thumbs.isNotEmpty) {
      final last = thumbs.last;
      if (last is Map) thumb = last['url'] as String?;
    }
    thumb ??= j['thumbnail'] as String?;

    return VideoInfo(
      id: (j['id'] as String?) ?? '',
      title: (j['title'] as String?) ?? 'Untitled video',
      webUrl: (j['webpage_url'] ?? j['original_url'] ?? '') as String,
      author: (j['uploader'] ?? j['channel']) as String?,
      duration: (j['duration'] as num?)?.round() ?? 0,
      uploadDate: parseUploadDate(j['upload_date'] as String?),
      thumbnail: thumb,
      videoFormats: _buildVideoFormats(rawFormats, hasFfmpeg),
      audioFormats: _buildAudioFormats(rawFormats),
    );
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

  static List<Format> _buildAudioFormats(List<Map<String, dynamic>> formats) {
    final audio =
        formats.where((f) {
          final v = f['vcodec'] as String?;
          final a = f['acodec'] as String?;
          return (v == null || v == 'none') && a != null && a != 'none';
        }).toList()..sort((a, b) {
          final c = ((b['tbr'] as num?)?.toDouble() ?? 0).compareTo(
            (a['tbr'] as num?)?.toDouble() ?? 0,
          );
          if (c != 0) return c;
          final aIsM4a = (a['ext'] == 'm4a') ? 0 : 1;
          final bIsM4a = (b['ext'] == 'm4a') ? 0 : 1;
          return aIsM4a.compareTo(bIsM4a);
        });

    Map<String, dynamic>? bestM4a;
    for (final f in audio) {
      if (f['ext'] == 'm4a') {
        bestM4a = f;
        break;
      }
    }
    if (bestM4a == null) {
      if (audio.isEmpty) return const [];
      bestM4a = audio.first;
    }
    final fs = bestM4a['filesize'] ?? bestM4a['filesize_approx'];
    final size = fs is num ? fs : null;
    final sizeLabel = size == null ? '' : ' · ${formatBytes(size)}';
    return [
      Format(
        kind: FormatKind.audio,
        label: 'M4A · Best audio$sizeLabel',
        selector: 'ba[ext=m4a]/ba',
        filesize: size?.toInt(),
      ),
    ];
  }
}
