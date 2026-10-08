import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/download_record.dart';

void main() {
  group('DownloadRecord round-trip', () {
    final record = DownloadRecord(
      id: 'r1',
      videoId: 'v1',
      title: 'A Video',
      author: 'A Channel',
      thumbnail: 'https://example.com/t.jpg',
      filePath: '/dl/a.mp4',
      size: 4096,
      createdAt: DateTime(2026, 3, 7),
      playlistTitle: 'Road Trip',
    );

    test('survives a save and reload', () {
      final back = DownloadRecord.fromMap(record.toMap());

      expect(back.id, record.id);
      expect(back.videoId, record.videoId);
      expect(back.title, record.title);
      expect(back.author, record.author);
      expect(back.thumbnail, record.thumbnail);
      expect(back.filePath, record.filePath);
      expect(back.size, record.size);
      expect(back.createdAt, record.createdAt);
      expect(back.playlistTitle, record.playlistTitle);
    });
  });

  group('a corrupt record does not break the library', () {
    // These fields are read with a type check rather than a cast: `as String?`
    // throws on a non-String rather than coercing, and `fromMap` runs inside the
    // history service at startup — so one bad entry would otherwise take the
    // whole library down with it.
    test('fields of the wrong type fall back rather than throwing', () {
      late DownloadRecord back;
      expect(
        () => back = DownloadRecord.fromMap({
          'id': 7,
          'videoId': null,
          'title': 42,
          'author': 3.5,
          'thumbnail': true,
          'filePath': ['nope'],
          'size': 'big',
          'createdAt': '2026-03-07',
          'playlistTitle': 9,
        }),
        returnsNormally,
      );

      expect(back.id, '');
      expect(back.videoId, '');
      expect(back.title, 'Unknown');
      expect(back.author, isNull);
      expect(back.thumbnail, isNull);
      expect(back.filePath, '');
      expect(back.size, 0);
      expect(back.playlistTitle, isNull);
    });

    test('a missing date is now, not 1970', () {
      // The epoch fallback sorted a record to the bottom of "newest first" and
      // rendered as Jan 1, 1970 — a plausible-looking wrong date rather than an
      // obviously broken one.
      final back = DownloadRecord.fromMap({'id': 'r1'});

      expect(back.createdAt.year, DateTime.now().year);
    });

    test('a valid date is still honoured exactly', () {
      final back = DownloadRecord.fromMap({
        'id': 'r1',
        'createdAt': DateTime(2026, 3, 7).millisecondsSinceEpoch,
      });

      expect(back.createdAt, DateTime(2026, 3, 7));
    });
  });
}
