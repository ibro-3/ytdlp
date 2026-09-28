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

  factory DownloadRecord.fromMap(Map<String, dynamic> m) => DownloadRecord(
    id: m['id'] as String? ?? '',
    videoId: m['videoId'] as String? ?? '',
    title: m['title'] as String? ?? 'Unknown',
    author: m['author'] as String?,
    thumbnail: m['thumbnail'] as String?,
    filePath: m['filePath'] as String? ?? '',
    size: (m['size'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (m['createdAt'] as num?)?.toInt() ?? 0,
    ),
    playlistTitle: m['playlistTitle'] as String?,
  );
}
