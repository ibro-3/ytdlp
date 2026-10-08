class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.videoId,
    required this.title,
    this.author,
    this.thumbnail,
    required this.filePath,
    this.size = 0,
    required this.createdAt,
    this.playlistTitle,
  });

  final String id;
  final String videoId;
  final String title;
  final String? author;
  final String? thumbnail;
  final String filePath;
  final int size;
  final DateTime createdAt;

  /// Set when the file was downloaded as part of a playlist, so the library
  /// can group entries and show where they live on disk.
  final String? playlistTitle;

  Map<String, dynamic> toMap() => {
    'id': id,
    'videoId': videoId,
    'title': title,
    'author': author,
    'thumbnail': thumbnail,
    'filePath': filePath,
    'size': size,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'playlistTitle': playlistTitle,
  };

  /// Reads a stored record.
  ///
  /// Every field goes through a type check rather than a cast. `as String?` throws
  /// on a non-String — it does not coerce — so a single record written by a
  /// different build, or edited by hand, would throw inside the history service
  /// and take the library down with it. `createdAt` also falls back to "now"
  /// rather than the epoch, because a record dated 1970 sorts to the bottom of
  /// "newest first" and renders as a plausible-looking wrong date.
  factory DownloadRecord.fromMap(Map<String, dynamic> m) => DownloadRecord(
    id: _str(m['id']) ?? '',
    videoId: _str(m['videoId']) ?? '',
    title: _str(m['title']) ?? 'Unknown',
    author: _str(m['author']),
    thumbnail: _str(m['thumbnail']),
    filePath: _str(m['filePath']) ?? '',
    size: _num(m['size'])?.toInt() ?? 0,
    // A missing date is "now", not the epoch: a record dated 1970 sorts to the
    // bottom of "newest first" and renders as a plausible-looking wrong date
    // rather than an obviously broken one.
    createdAt: _num(m['createdAt']) == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(_num(m['createdAt'])!.toInt()),
    playlistTitle: _str(m['playlistTitle']),
  );
}

/// A stored string field, or null when it holds anything else.
///
/// Null rather than a cast and null rather than an empty string: the caller
/// decides which, and the two are not interchangeable — `title` falls back to
/// "Unknown" while `author` is genuinely optional.
String? _str(Object? value) => value is String ? value : null;

/// A stored numeric field, or null when it holds anything else.
///
/// `as num?` throws on a String — a hand-edited box, or one written by a build
/// that stored the size as text — and `fromMap` runs at start-up, so that throw
/// would take the whole library down with it.
num? _num(Object? value) => value is num ? value : null;
