import 'download_options.dart';
import 'video_info.dart';
import 'youtube_prefs.dart';
import 'yt_prefs.dart';

/// [paused] is a task the user held back: the download is not running and the
/// scheduler will not start it until it is released, but unlike
/// [DownloadStatus.canceled] it still has a resumable partial file.
enum DownloadStatus { queued, downloading, paused, completed, failed, canceled }

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.video,
    required this.format,
    required this.createdAt,
    this.options = const DownloadOptions(),
    this.extraArgs = const [],
    this.outputTemplate = '',
    this.prefs = const YtPrefs(),
    this.youtube = const YoutubePrefs(),
    this.stagingPath,
    this.playlistId,
    this.playlistTitle,
  });

  final String id;
  final VideoInfo video;
  final Format format;

  /// When the task was enqueued, which is also its queue ordering: the
  /// scheduler starts the oldest waiting task first.
  ///
  /// Mutable only so `DownloadManager.reorder` can re-stamp a waiting task to
  /// move it in the queue. Nothing else changes it.
  DateTime createdAt;

  /// Subtitle/thumbnail extras chosen when this download was enqueued.
  final DownloadOptions options;

  /// Extra yt-dlp arguments for this download, already tokenised. Empty means
  /// "use whatever Settings says at run time", so a later settings change
  /// still applies to a task enqueued before it.
  ///
  /// Captured on the task rather than read at spawn time so a retry repeats
  /// the command that failed instead of silently changing under the user.
  final List<String> extraArgs;

  /// Output template for this download. Empty means the Settings default.
  final String outputTemplate;

  /// First-class yt-dlp preferences captured for this download, so a retry
  /// repeats the same command. Empty for a task enqueued before this existed.
  final YtPrefs prefs;

  /// YouTube-specific preferences, captured so a retry repeats the command.
  final YoutubePrefs youtube;

  /// Set when the download came from a playlist. Every entry of one playlist
  /// shares the same id so the queue can group them, and the title decides the
  /// folder the finished files are grouped into.
  final String? playlistId;
  final String? playlistTitle;

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
    'playlistId': playlistId,
    'playlistTitle': playlistTitle,
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
    'options': options.toMap(),
    'extraArgs': extraArgs,
    'outputTemplate': outputTemplate,
    'prefs': prefs.toMap(),
    'youtube': youtube.toMap(),
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
        playlistId: m['playlistId'] as String?,
        playlistTitle: m['playlistTitle'] as String?,
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
        options: DownloadOptions.fromMap(
          (m['options'] as Map?)?.cast<String, dynamic>(),
        ),
        // Tolerates a stored value of the wrong type: a corrupt snapshot must
        // not be able to break queue restore, matching how every other field
        // in this factory falls back to a sane default.
        extraArgs: switch (m['extraArgs']) {
          final List<dynamic> list => list.whereType<String>().toList(),
          _ => const <String>[],
        },
        outputTemplate: m['outputTemplate'] as String? ?? '',
        youtube: YoutubePrefs.fromMap(
          // Pattern-matched rather than cast, like `prefs` below: a corrupt
          // snapshot must not be able to break queue restore.
          switch (m['youtube']) {
            final Map<dynamic, dynamic> map => Map<String, dynamic>.from(map),
            _ => null,
          },
        ),
        prefs: YtPrefs.fromMap(
          // Pattern-matched rather than cast: a snapshot whose 'prefs' is not
          // a map must still restore, same as every other field here.
          switch (m['prefs']) {
            final Map<dynamic, dynamic> map => Map<String, dynamic>.from(map),
            _ => null,
          },
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
    'paused' => DownloadStatus.paused,
    'canceled' => DownloadStatus.canceled,
    _ => DownloadStatus.failed,
  };
}
