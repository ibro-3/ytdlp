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

  bool get isBest => tier == null;
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

  factory VideoInfo.fromYtdlpJson(Map<String, dynamic> j,
      {required bool hasFfmpeg}) {
    final rawFormats = (j['formats'] as List?)
            ?.map((e) => e as Map<String, dynamic>)
            .toList() ??
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

  static List<Format> _buildVideoFormats(
      List<Map<String, dynamic>> formats, bool hasFfmpeg) {
    final combined = formats.where(_isCombined).toList();
    if (combined.isEmpty) return [];
    const tiers = [2160, 1440, 1080, 720, 480, 360, 240];
    final result = <Format>[];

    // Best first
    result.add(_videoFormat(combined, null, hasFfmpeg, labelBase: 'Best quality'));

    for (final t in tiers) {
      final anyAtOrBelow = combined.any(
          (f) => ((f['height'] as num?)?.toInt() ?? 0) <= t);
      if (!anyAtOrBelow) continue;
      // avoid duplicates: if the best height already equals t, skip Best duplicate
      final bestHeight = combined
          .map((f) => (f['height'] as num?)?.toInt() ?? 0)
          .fold<int>(0, (a, b) => a > b ? a : b);
      if (bestHeight == t && result.length == 1) continue;
      final labelBase = t >= 1400 ? '${t}p · MP4' : '${t}p · MP4';
      // For 2160 show 2160p (or 4K label). Keep consistent: 2160p.
      result.add(_videoFormat(combined, t, hasFfmpeg, labelBase: labelBase));
      if (result.length >= 7) break;
    }
    return result;
  }

  static Format _videoFormat(List<Map<String, dynamic>> combined, int? maxHeight,
      bool hasFfmpeg,
      {required String labelBase}) {
    var pool = combined;
    if (maxHeight != null) {
      pool = pool
          .where((f) => ((f['height'] as num?)?.toInt() ?? 0) <= maxHeight)
          .toList();
    }
    pool = List.of(pool)
      ..sort((a, b) {
        final c = ((b['height'] as num?)?.toInt() ?? 0)
            .compareTo((a['height'] as num?)?.toInt() ?? 0);
        if (c != 0) return c;
        final aIsMp4 = (a['ext'] == 'mp4') ? 0 : 1;
        final bIsMp4 = (b['ext'] == 'mp4') ? 0 : 1;
        return aIsMp4.compareTo(bIsMp4);
      });

    final best = pool.isEmpty ? null : pool.first;
    final h = (best?['height'] as num?)?.toInt();
    final filesize = best?['filesize'] ?? best?['filesize_approx'];

    final selector = hasFfmpeg
        ? (h == null
            ? 'bv*+ba/b'
            : 'bv*[height<=$h]+ba/b[height<=$h]/b')
        : (h == null
            ? 'b[ext=mp4]/b'
            : 'b[height<=$h][ext=mp4]/b[height<=$h]/b');

    final sizeLabel =
        filesize == null ? '' : ' · ${formatBytes(filesize as num)}';

    return Format(
      kind: FormatKind.video,
      label: '$labelBase$sizeLabel',
      selector: selector,
      tier: h,
      filesize: (filesize as num?)?.toInt(),
    );
  }

  static List<Format> _buildAudioFormats(
      List<Map<String, dynamic>> formats) {
    final audio = formats.where((f) {
      final v = f['vcodec'] as String?;
      final a = f['acodec'] as String?;
      return (v == null || v == 'none') && a != null && a != 'none';
    }).toList()
      ..sort((a, b) {
        final c = ((b['tbr'] as num?)?.toDouble() ?? 0)
            .compareTo((a['tbr'] as num?)?.toDouble() ?? 0);
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
    bestM4a ??= audio.isEmpty ? null : audio.first;
    final fs = bestM4a?['filesize'] ?? bestM4a?['filesize_approx'];
    final sizeLabel = fs == null ? '' : ' · ${formatBytes(fs as num)}';
    return [
      Format(
        kind: FormatKind.audio,
        label: 'M4A · Best audio$sizeLabel',
        selector: 'ba[ext=m4a]/ba',
        filesize: (fs as num?)?.toInt(),
      ),
    ];
  }
}
