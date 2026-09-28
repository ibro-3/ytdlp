import 'dart:io';

import 'package:path/path.dart' as p;

/// A media file found in the download folder that the library does not know
/// about — copied in from a computer, downloaded by another app, or left
/// behind when the app's own history was cleared.
class DiscoveredFile {
  const DiscoveredFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final int size;
  final DateTime modified;

  /// The folder name, which is `Video` or `Audio` for files the app wrote, and
  /// a playlist title for a file inside one of those.
  String get group => p.basename(p.dirname(path));

  /// Title guessed from the file name: the extension is dropped and the
  /// `Title [id]` suffix the app appends is removed.
  ///
  /// Best-effort only — a file has no embedded title the app can rely on
  /// reading, and doing so for every file in a large folder would be slow.
  String get guessedTitle {
    var name = this.name;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    final bracket = name.lastIndexOf(' [');
    if (bracket > 0 && name.endsWith(']')) {
      name = name.substring(0, bracket);
    }
    return name.isEmpty ? this.name : name;
  }
}

/// Scans the download folder for media the library has no record of.
///
/// The library only knows about files the app downloaded, so anything brought
/// in by other means is invisible. This is read-only and additive: a discovered
/// file is offered, never added to history automatically, so clearing history
/// stays a real reset.
class FolderScanner {
  const FolderScanner();

  /// Extensions treated as media. Deliberately excludes the sidecar types the
  /// app writes alongside media, so a subtitle or thumbnail is not offered as a
  /// playable item.
  static const Set<String> mediaExtensions = {
    'mp4',
    'mkv',
    'webm',
    'mov',
    'avi',
    'm4v',
    'flv',
    'ts',
    'm2ts',
    'wmv',
    'mp3',
    'm4a',
    'opus',
    'ogg',
    'oga',
    'flac',
    'wav',
    'aac',
    'mka',
    'weba',
  };

  /// Files at or below this size are ignored: a zero-byte leftover or a
  /// truncated `.part` is not something to play.
  static const int minSizeBytes = 1024;

  /// Ceiling on files returned, so a 10,000-file folder cannot lock the UI.
  static const int maxResults = 2000;

  /// Walks [root] and returns media files not in [knownPaths].
  ///
  /// [knownPaths] is the set of paths already in the library, compared
  /// normalised so a differing separator or `./` prefix does not produce a
  /// false "new" file.
  ///
  /// Skips the staging directory: its contents are mid-download by definition
  /// and would otherwise show up as playable half-files.
  Future<List<DiscoveredFile>> scan({
    required Directory root,
    Set<String> knownPaths = const {},
  }) async {
    if (!await root.exists()) return const [];
    final known = knownPaths.map(p.normalize).toSet();
    final found = <DiscoveredFile>[];
    final staging = p.normalize(p.join(root.path, '.ytdlp-staging'));

    try {
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (found.length >= maxResults) break;
        if (entity is! File) continue;
        final path = entity.path;
        // Must run before the extension check: the staging root itself is a
        // directory whose children are all partial.
        if (p.normalize(path) == staging ||
            p.normalize(p.dirname(path)) == staging) {
          continue;
        }
        if (!mediaExtensions.contains(
          p.extension(path).toLowerCase().replaceFirst('.', ''),
        )) {
          continue;
        }
        if (p.normalize(path).contains(staging)) continue;
        if (known.contains(p.normalize(path))) continue;

        FileStat stat;
        try {
          stat = await entity.stat();
        } catch (_) {
          continue; // Vanished between listing and stat.
        }
        if (stat.size < minSizeBytes) continue;
        found.add(
          DiscoveredFile(
            path: path,
            name: p.basename(path),
            size: stat.size,
            modified: stat.modified,
          ),
        );
      }
    } catch (_) {
      // An unreadable folder is not an error the user can act on; return what
      // was collected so far.
    }

    // Newest first, so a just-copied file is at the top.
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return found;
  }
}
