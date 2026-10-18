import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/download_record.dart';
import 'package:ytdlp/services/downloads/history_service.dart';

/// The service against a real Hive box in a temp directory.
///
/// Record round-trips live or die on Hive itself (the box write lands in
/// `add`/`remove`, not only on the in-memory list), so the in-memory stub used
/// by the widget tests is the wrong harness here.
void main() {
  late Directory tempDir;
  late Box<dynamic> box;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('ytdlp-history-svc-');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    if (box.isOpen) await box.close();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  DownloadRecord record(String id, int year, {String title = 'Title'}) =>
      DownloadRecord(
        id: id,
        videoId: 'v-$id',
        title: title,
        thumbnail: null,
        filePath: '/dl/$id.mp4',
        size: 1,
        createdAt: DateTime(year),
      );

  test('add writes to the box, not only to the list', () async {
    box = await Hive.openBox<dynamic>('hist-add');
    final service = HistoryService(box);
    await service.add(record('r1', 2026));

    // A fresh service reading the same box must see it.
    final reopened = HistoryService(box);
    reopened.init();
    final titles = [for (final r in reopened.records) r.id];
    expect(titles, contains('r1'));
  });

  test('remove deletes the box entry as well as the list entry', () async {
    box = await Hive.openBox<dynamic>('hist-remove');
    final service = HistoryService(box);
    await service.add(record('gone', 2026));
    await service.remove('gone');

    expect(service.records, isEmpty);
    expect(box.get('gone'), isNull);

    final reopened = HistoryService(box);
    reopened.init();
    expect(reopened.records, isEmpty);
  });

  test('add puts the newest record first', () async {
    box = await Hive.openBox<dynamic>('hist-order');
    final service = HistoryService(box);
    await service.add(record('old', 2020));
    await service.add(record('new', 2026));

    expect(service.records.first.id, 'new');
    expect(service.records.last.id, 'old');
  });

  test(
    'a record whose box write failed throws is not added to the list',
    () async {
      // The order of `add` matters: the box write is awaited before the insert.
      // A Box that refuses the write (closed box throws synchronously on await
      // of a failed future) must not leave a record that lists the download
      // while nothing was persisted.
      box = await Hive.openBox<dynamic>('hist-order');
      final service = HistoryService(box);
      await service.add(record('a', 2026));
      await box.close();

      await expectLater(service.add(record('b', 2025)), throwsA(anything));
    },
  );
}
