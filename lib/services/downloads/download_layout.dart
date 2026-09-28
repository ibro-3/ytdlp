import 'package:path/path.dart' as p;

import '../../core/models/video_info.dart';

/// Where a single download lands, relative to the configured download root.
class DownloadLayout {
  const DownloadLayout({
    required this.kind,
    required this.directory,
    required this.template,
    this.subdirectory,
  });

  final FormatKind kind;

  /// Area a download of this kind belongs to (`root/Video` or `root/Audio`).
  /// Use [targetDirectory] to get the folder a file is actually moved into.
  final String directory;

  /// Output template passed to yt-dlp (`-o`).
  final String template;

  /// Sanitized per-playlist folder name, when the download belongs to a
  /// playlist. `null` for a single video, in which case files land directly in
  /// [directory].
  final String? subdirectory;

  /// [directory] joined with [subdirectory] when present — the folder a
  /// finished file is actually moved into.
  String get targetDirectory =>
      subdirectory == null ? directory : p.join(directory, subdirectory!);
}

/// Resolves the target directory + output template for a download.
///
/// - Video downloads land in `<root>/Video`, audio in `<root>/Audio`.
/// - When [playlistTitle] is given, entries are grouped into one folder per
///   playlist inside the matching Video/Audio area, and the template keeps the
///   `%(playlist_title)s/` prefix so the flat staging layout still resolves.
DownloadLayout resolveDownloadLayout({
  required String root,
  required FormatKind kind,
  String? playlistTitle,
}) {
  final dir = p.join(root, kind == FormatKind.audio ? 'Audio' : 'Video');
  final isPlaylist = playlistTitle != null && playlistTitle.trim().isNotEmpty;
  return DownloadLayout(
    kind: kind,
    directory: dir,
    template: isPlaylist
        ? '%(playlist_title)s/%(title)s [%(id)s].%(ext)s'
        : '%(title)s [%(id)s].%(ext)s',
    subdirectory: isPlaylist ? sanitizeFolderName(playlistTitle) : null,
  );
}

/// Characters no mainstream filesystem accepts in a name, plus the path
/// separators and control characters that would let a title escape the
/// download root.
///
/// This mirrors what yt-dlp does to `%(playlist_title)s` in its own output
/// template. The app has to do it itself because a completed download is moved
/// from staging by `DownloadManager` rather than written straight to its final
/// path by yt-dlp, so no template sanitization ever runs for us.
final RegExp _unsafeInFolderName = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Characters reserved by Windows, which stay reserved on every platform we
/// ship to so a library folder is portable between them.
const _windowsReserved = {
  'CON', 'PRN', 'AUX', 'NUL', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Longest folder name we produce. Most filesystems cap a single path
/// component at 255 bytes; titles in several locales are multi-byte, so the
/// limit is applied to characters and then trimmed to a safe byte length.
const _maxFolderNameLength = 120;

/// Makes a playlist title usable as a single folder name.
///
/// Returns `Playlist` when the title is empty or sanitizes away entirely, so
/// entries never land in the download root itself.
String sanitizeFolderName(String title) {
  var name = title.replaceAll(_unsafeInFolderName, '_');
  // Collapse the whitespace runs that replacement tends to produce.
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  // A trailing dot or space is silently dropped by Windows, which would make
  // the folder unreachable there.
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) return 'Playlist';
  if (_windowsReserved.contains(name.toUpperCase())) return '_$name';
  if (name.length > _maxFolderNameLength) {
    name = name.substring(0, _maxFolderNameLength).trim();
  }
  // Leave room for the '. (n)' suffix _moveUnique may append on a collision.
  if (name.codeUnits.every((u) => u > 0x7F) && name.length > 40) {
    name = name.substring(0, 40);
  }
  return name;
}
