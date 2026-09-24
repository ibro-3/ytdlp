import 'video_info.dart';

enum DownloadStatus { queued, downloading, completed, failed, canceled }

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.video,
    required this.format,
    required this.createdAt,
    this.stagingPath,
  });

  final String id;
  final VideoInfo video;
  final Format format;
  final DateTime createdAt;

  DownloadStatus status = DownloadStatus.queued;
  double progress = 0;
  String? speed;
  String? eta;
  String? error;

  /// Non-fatal problem that happened after the download itself succeeded
  /// (for example, the file could not be recorded in the library).
  String? warning;

  /// Path of the final file after a successful download.
  String? filePath;

  /// yt-dlp's most recent reported destination (may be intermediate).
  String? destinationPath;

  /// Staging directory used while this task was running. Kept (not cleared)
  /// after a failure so a retry can continue the partial download.
  String? stagingPath;

  /// Snapshot for the queue store. Enough to show the task after a restart
  /// and to resume it — the format lists are intentionally not persisted
  /// because only the chosen selector is ever needed again.
  Map<String, dynamic> toMap() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'progress': progress,
    'speed': speed,
    'eta': eta,
    'error': error,
    'warning': warning,
    'filePath': filePath,
    'stagingPath': stagingPath,
    'video': {
      'id': video.id,
      'title': video.title,
      'webUrl': video.webUrl,
      'author': video.author,
      'thumbnail': video.thumbnail,
      'duration': video.duration,
    },
    'format': {
      'kind': format.kind.name,
      'label': format.label,
      'selector': format.selector,
      'tier': format.tier,
      'filesize': format.filesize,
    },
  };

  /// Rebuilds a task from a [toMap] snapshot. Any missing or malformed field
  /// falls back to a sane default so one bad record cannot break startup.
  factory DownloadTask.fromMap(Map<String, dynamic> m) {
    final v = Map<String, dynamic>.from(
      (m['video'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    final f = Map<String, dynamic>.from(
      (m['format'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    final kind = f['kind'] == FormatKind.audio.name
        ? FormatKind.audio
        : FormatKind.video;
    return DownloadTask(
        id: (m['id'] as String?) ?? '',
        createdAt:
            DateTime.tryParse((m['createdAt'] as String?) ?? '') ??
            DateTime.now(),
        stagingPath: m['stagingPath'] as String?,
        video: VideoInfo(
          id: (v['id'] as String?) ?? '',
          title: (v['title'] as String?) ?? 'Unknown video',
          webUrl: (v['webUrl'] as String?) ?? '',
          author: v['author'] as String?,
          thumbnail: v['thumbnail'] as String?,
          duration: (v['duration'] as num?)?.toInt() ?? 0,
        ),
        format: Format(
          kind: kind,
          label: (f['label'] as String?) ?? 'Format',
          selector: (f['selector'] as String?) ?? 'b',
          tier: (f['tier'] as num?)?.toInt(),
          filesize: (f['filesize'] as num?)?.toInt(),
        ),
      )
      ..status = _statusFrom(m['status'] as String?)
      ..progress = (m['progress'] as num?)?.toDouble() ?? 0
      ..speed = m['speed'] as String?
      ..eta = m['eta'] as String?
      ..error = m['error'] as String?
      ..warning = m['warning'] as String?
      ..filePath = m['filePath'] as String?;
  }

  static DownloadStatus _statusFrom(String? name) => switch (name) {
    'queued' => DownloadStatus.queued,
    'downloading' => DownloadStatus.downloading,
    'completed' => DownloadStatus.completed,
    'failed' => DownloadStatus.failed,
    'canceled' => DownloadStatus.canceled,
    _ => DownloadStatus.failed,
  };
}
