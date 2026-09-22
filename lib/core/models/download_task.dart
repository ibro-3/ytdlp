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
  String? destinationPath;
  String? filePath;
}
