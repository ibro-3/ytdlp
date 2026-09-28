import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/download_record.dart';
import 'package:ytdlp/core/models/library_filter.dart';

DownloadRecord _rec({
  required String id,
  String? title,
  String? author,
  String? playlist,
  String path = '/dl/a.mp4',
  int size = 100,
  DateTime? at,
}) => DownloadRecord(
  id: id,
  videoId: 'v$id',
  title: title ?? 'Title $id',
  author: author,
  thumbnail: null,
  filePath: path,
  size: size,
  createdAt: at ?? DateTime(2026, 1, int.parse(id)),
  playlistTitle: playlist,
);

void main() {
  final records = [
    _rec(id: '1', title: 'Zebra crossing', author: 'Alice', size: 300),
    _rec(
      id: '2',
      title: 'apple pie',
      author: 'Bob',
      path: '/dl/2.m4a',
      size: 100,
    ),
    _rec(
      id: '3',
      title: 'Mango jam',
      author: 'Alice',
      playlist: 'Road Trip',
      size: 200,
    ),
  ];

  group('search', () {
    test('an empty query matches everything', () {
      expect(applyLibraryView(records: records).length, 3);
      expect(
        applyLibraryView(records: records, query: '   ').length,
        3,
        reason: 'whitespace is not a query',
      );
    });

    test('matches the title case-insensitively', () {
      expect(
        applyLibraryView(records: records, query: 'APPLE').single.title,
        'apple pie',
      );
    });

    test('matches the author', () {
      // Newest-first, which is the default order the library shows.
      final found = applyLibraryView(records: records, query: 'alice');
      expect(found.map((r) => r.id), ['3', '1']);
    });

    test('matches the playlist name', () {
      expect(
        applyLibraryView(records: records, query: 'road trip').single.id,
        '3',
      );
    });

    test('a query that matches nothing yields an empty list', () {
      expect(applyLibraryView(records: records, query: 'xyzzy'), isEmpty);
    });

    test('search and filter combine', () {
      final found = applyLibraryView(
        records: records,
        query: 'a',
        filter: LibraryFilter.audio,
      );
      expect(found.map((r) => r.id), ['2']);
    });
  });

  group('filter', () {
    test('all keeps everything', () {
      expect(applyLibraryView(records: records).length, 3);
    });

    test('audio is detected by extension', () {
      final audio = applyLibraryView(
        records: records,
        filter: LibraryFilter.audio,
      );
      expect(audio.map((r) => r.id), ['2']);
      expect(isAudioRecord(records[1]), isTrue);
      expect(isAudioRecord(records[0]), isFalse);
    });

    test('video excludes audio', () {
      final video = applyLibraryView(
        records: records,
        filter: LibraryFilter.video,
      );
      expect(video.map((r) => r.id), ['3', '1']);
    });

    test('extension matching is case-insensitive', () {
      expect(isAudioRecord(_rec(id: '9', path: '/dl/9.MP3')), isTrue);
    });

    test('a file with no extension is treated as video', () {
      // Nothing to go on, and calling it audio would hide it from a video
      // filter for no reason.
      expect(isAudioRecord(_rec(id: '9', path: '/dl/noextension')), isFalse);
    });
  });

  group('sort', () {
    test('newest first is the default', () {
      expect(applyLibraryView(records: records).map((r) => r.id), [
        '3',
        '2',
        '1',
      ]);
    });

    test('oldest first reverses it', () {
      expect(
        applyLibraryView(
          records: records,
          sort: LibrarySort.oldest,
        ).map((r) => r.id),
        ['1', '2', '3'],
      );
    });

    test('largest sorts by size', () {
      expect(
        applyLibraryView(
          records: records,
          sort: LibrarySort.largest,
        ).map((r) => r.id),
        ['1', '3', '2'],
      );
    });

    test('title sorts alphabetically, case-insensitively', () {
      expect(
        applyLibraryView(
          records: records,
          sort: LibrarySort.title,
        ).map((r) => r.title),
        ['apple pie', 'Mango jam', 'Zebra crossing'],
      );
    });

    test('sortRecords mutates in place', () {
      final list = [...records];
      sortRecords(list, LibrarySort.largest);
      expect(list.first.id, '1');
    });
  });

  group('grouping', () {
    test('no grouping returns one flat list', () {
      final view = buildLibraryView(records: records);
      expect(view.groups, isEmpty);
      expect(view.loose, hasLength(3));
      expect(view.total, 3);
    });

    test('grouping splits playlist entries from the rest', () {
      final view = buildLibraryView(
        records: records,
        grouping: LibraryGrouping.playlist,
      );
      expect(view.groups, hasLength(1));
      expect(view.groups.single.title, 'Road Trip');
      expect(view.groups.single.records.single.id, '3');
      // `loose` is whatever was not placed in a section, in sort order.
      expect(view.loose.map((r) => r.id), ['2', '1']);
      expect(view.total, 3, reason: 'one grouped plus two loose');
    });

    test('a group reports its total size', () {
      final view = buildLibraryView(
        records: [
          _rec(id: '1', playlist: 'Mix', size: 100),
          _rec(id: '2', playlist: 'Mix', size: 250),
        ],
        grouping: LibraryGrouping.playlist,
      );
      expect(view.groups.single.totalSize, 350);
      expect(view.totalSize, 350);
    });

    test('groups are ordered by their newest entry', () {
      final view = buildLibraryView(
        records: [
          _rec(id: '1', playlist: 'Old', at: DateTime(2020)),
          _rec(id: '2', playlist: 'New', at: DateTime(2026)),
        ],
        grouping: LibraryGrouping.playlist,
      );
      expect(view.groups.map((g) => g.title), ['New', 'Old']);
    });

    test('a blank playlist name is not a group', () {
      final view = buildLibraryView(
        records: [_rec(id: '1', playlist: '   ')],
        grouping: LibraryGrouping.playlist,
      );
      expect(view.groups, isEmpty);
      expect(view.loose, hasLength(1));
    });

    test('a filter applies before grouping', () {
      final view = buildLibraryView(
        records: [
          _rec(id: '1', playlist: 'Mix', path: '/dl/1.m4a'),
          _rec(id: '2', playlist: 'Mix', path: '/dl/2.mp4'),
        ],
        filter: LibraryFilter.audio,
        grouping: LibraryGrouping.playlist,
      );
      expect(view.groups.single.records, hasLength(1));
      expect(view.groups.single.records.single.id, '1');
    });

    test('an empty input yields an empty view', () {
      final view = buildLibraryView(records: const []);
      expect(view.isEmpty, isTrue);
      expect(view.total, 0);
    });
  });

  group('immutability', () {
    test('the input list is not reordered', () {
      final input = [...records];
      final before = input.map((r) => r.id).toList();
      applyLibraryView(records: input, sort: LibrarySort.largest);
      expect(input.map((r) => r.id), before);
    });
  });
}
