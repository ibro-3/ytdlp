import 'package:path/path.dart' as p;

import '../../core/models/video_info.dart';

/// Where a single download lands, relative to the configured download root.
class DownloadLayout {
  const DownloadLayout({
    required this.kind,
    required this.directory,
    required this.template,
  });

  final FormatKind kind;

  /// Absolute directory that must exist before the download starts
  /// (`root/Video` or `root/Audio`). Any per-playlist subfolder deeper than
  /// this is created by yt-dlp itself via the output template.
  final String directory;

  /// Output template passed to yt-dlp (`-o`).
  final String template;
}

/// Resolves the target directory + output template for a download.
///
/// - Video downloads land in `<root>/Video`, audio in `<root>/Audio`.
/// - When [isPlaylist] is true the template prefixes `%(playlist_title)s/`,
///   so yt-dlp groups playlist entries under one folder per playlist inside
///   the matching Video/Audio area. (Playlist support is not wired up yet —
///   callers pass false today.)
DownloadLayout resolveDownloadLayout({
  required String root,
  required FormatKind kind,
  bool isPlaylist = false,
}) {
  final dir = p.join(root, kind == FormatKind.audio ? 'Audio' : 'Video');
  final template = isPlaylist
      ? '%(playlist_title)s/%(title)s [%(id)s].%(ext)s'
      : '%(title)s [%(id)s].%(ext)s';
  return DownloadLayout(kind: kind, directory: dir, template: template);
}
