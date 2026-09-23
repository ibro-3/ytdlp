import 'video_info.dart';

enum DownloadStatus { queued, downloading, completed, failed, canceled }

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.video,
    required this.format,
    required this.createdAt,
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

  /// Staging directory used while this task was running.
  String? stagingPath;
}
