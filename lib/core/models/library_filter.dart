/// Search, sort and grouping over the download history.
///
/// Pure functions over `List<DownloadRecord>`, with no filesystem access, so
/// the library view can be exercised without touching disk. Existence checking
/// stays in the page (it is async) and is passed in separately.
library;

import 'download_record.dart';

/// How the library list is ordered.
enum LibrarySort {
  newest('Newest first'),
  oldest('Oldest first'),
  largest('Largest first'),
  title('Title (A–Z)');

  const LibrarySort(this.label);
  final String label;
}

/// Which kind of file to show.
enum LibraryFilter {
  all('All'),
  video('Video'),
  audio('Audio');

  const LibraryFilter(this.label);
  final String label;
}

/// How playlist downloads are presented.
enum LibraryGrouping {
  none('No grouping'),
  playlist('Group by playlist');

  const LibraryGrouping(this.label);
  final String label;
}

/// A playlist section in the library, with the entries that belong to it.
class PlaylistGroup {
  const PlaylistGroup({required this.title, required this.records});

  final String title;
  final List<DownloadRecord> records;

  int get totalSize => records.fold(0, (sum, r) => sum + r.size);
}

/// The result of applying search, filter, sort and grouping.
class LibraryView {
  const LibraryView({this.groups = const [], this.loose = const []});

  /// Playlist sections; empty unless grouping is on and matches exist.
  final List<PlaylistGroup> groups;

  /// Records not in any playlist section, in the chosen sort order.
  final List<DownloadRecord> loose;

  bool get isEmpty => groups.isEmpty && loose.isEmpty;

  int get total =>
      groups.fold(0, (sum, g) => sum + g.records.length) + loose.length;

  int get totalSize =>
      groups.fold(0, (sum, g) => sum + g.totalSize) +
      loose.fold(0, (sum, r) => sum + r.size);
}

/// Searches [records], then filters, sorts and groups them.
///
/// Search is case-insensitive and matches the title or the author. An empty
/// [query] matches everything, so the caller needs no special case.
List<DownloadRecord> applyLibraryView({
  required List<DownloadRecord> records,
  String query = '',
  LibraryFilter filter = LibraryFilter.all,
  LibrarySort sort = LibrarySort.newest,
}) {
  final q = query.trim().toLowerCase();
  final filtered = records.where((r) {
    if (filter == LibraryFilter.video && _isAudio(r)) return false;
    if (filter == LibraryFilter.audio && !_isAudio(r)) return false;
    if (q.isEmpty) return true;
    return r.title.toLowerCase().contains(q) ||
        (r.author ?? '').toLowerCase().contains(q) ||
        (r.playlistTitle ?? '').toLowerCase().contains(q);
  }).toList();

  sortRecords(filtered, sort);
  return filtered;
}

/// Applies [filter], [sort] and [grouping] to already-searched [records].
LibraryView buildLibraryView({
  required List<DownloadRecord> records,
  String query = '',
  LibraryFilter filter = LibraryFilter.all,
  LibrarySort sort = LibrarySort.newest,
  LibraryGrouping grouping = LibraryGrouping.none,
}) {
  final filtered = applyLibraryView(
    records: records,
    query: query,
    filter: filter,
    sort: sort,
  );
  if (grouping == LibraryGrouping.none) {
    return LibraryView(loose: filtered);
  }

  // Groups keep their own internal order and the sections are ordered by their
  // newest entry, so a just-downloaded playlist surfaces at the top.
  final byPlaylist = <String, List<DownloadRecord>>{};
  final loose = <DownloadRecord>[];
  for (final r in filtered) {
    final key = r.playlistTitle;
    if (key == null || key.trim().isEmpty) {
      loose.add(r);
    } else {
      byPlaylist.putIfAbsent(key, () => []).add(r);
    }
  }

  final groups =
      [
        for (final entry in byPlaylist.entries)
          PlaylistGroup(title: entry.key, records: entry.value),
      ]..sort((a, b) {
        final aNewest = a.records.isEmpty
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : a.records.first.createdAt;
        final bNewest = b.records.isEmpty
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : b.records.first.createdAt;
        return bNewest.compareTo(aNewest);
      });

  return LibraryView(groups: groups, loose: loose);
}

/// Sorts [records] in place by [sort].
void sortRecords(List<DownloadRecord> records, LibrarySort sort) {
  switch (sort) {
    case LibrarySort.newest:
      records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    case LibrarySort.oldest:
      records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    case LibrarySort.largest:
      records.sort((a, b) => b.size.compareTo(a.size));
    case LibrarySort.title:
      records.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
  }
}

/// Whether a record is an audio file, by extension.
///
/// The extension is the only reliable signal: `DownloadRecord` has no media
/// kind, and yt-dlp can put audio in a container named `.mp4` or video in
/// `.m4a` after a conversion.
bool _isAudio(DownloadRecord record) {
  final dot = record.filePath.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = record.filePath.substring(dot + 1).toLowerCase();
  return const {
    'm4a',
    'mp3',
    'opus',
    'ogg',
    'oga',
    'flac',
    'wav',
    'aac',
    'mka',
    'weba',
  }.contains(ext);
}

/// Whether [record] is an audio file. Exposed for the filter chips' labels.
bool isAudioRecord(DownloadRecord record) => _isAudio(record);
