import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/services/downloads/queue_store.dart';

import '../support/memory_box.dart';

VideoInfo _video(String id) =>
    VideoInfo(id: id, title: 'Video $id', webUrl: 'https://example.com/$id');

/// Builds one task snapshot with a distinct creation time. The returned list
/// is oldest-first ([DateTime] grows with the index); [sortNewestFirst] is
/// what the manager applies before handing a list to the store.
List<DownloadTask> _tasks(int count) => [
  for (var i = 0; i < count; i++)
    DownloadTask(
      id: 't$i',
      video: _video('v$i'),
      format: const Format(
        kind: FormatKind.video,
        label: 'Best',
        selector: 'b',
      ),
      createdAt: DateTime(2026, 3, 1, 0, 0, i),
    ),
];

List<DownloadTask> _newestFirst(List<DownloadTask> tasks) =>
    tasks..sort((a, b) => b.createdAt.compareTo(a.createdAt));

void main() {
  // `save` persists the list exactly as given (the manager hands it over
  // newest-first), so each test sorts the same way the manager does.
  test(
    'a queue at or under the limit round-trips whole and in order',
    () async {
      final store = QueueStore(MemoryBox());
      final tasks = _newestFirst(_tasks(10));
      await store.save(tasks);

      final restored = store.load();
      expect(restored, hasLength(10));
      expect(
        [for (final t in restored) t.id],
        ['t9', 't8', 't7', 't6', 't5', 't4', 't3', 't2', 't1', 't0'],
        reason: 'newest first, matching what the manager keeps',
      );
    },
  );

  test(
    'a queue over the limit drops finished tasks before queued ones',
    () async {
      // The regression this pins: truncation used to cut straight from the
      // newest-first list, so the oldest *queued* links were the ones lost
      // while finished downloads — already in the library — kept their slots.
      final tasks = _tasks(60);
      for (final t in tasks) {
        t.status = DownloadStatus.completed;
      }
      // The five oldest are the queued ones: losing them would be losing work
      // that has never started, while t5..t9 are just finished history.
      for (final t in tasks.take(5)) {
        t.status = DownloadStatus.queued;
      }

      final store = QueueStore(MemoryBox());
      await store.save(_newestFirst(tasks));

      final ids = [for (final t in store.load()) t.id];
      expect(ids, hasLength(50));
      // Every queued task survived, plus the 45 newest completed.
      final queuedIds = ['t0', 't1', 't2', 't3', 't4'];
      for (final id in queuedIds) {
        expect(ids, contains(id));
      }
      expect(
        ids.where(queuedIds.contains),
        hasLength(5),
        reason: 'nothing else may have hijacked a kept slot',
      );
    },
  );

  test(
    'even with nothing finished, the limit is still honored exactly',
    () async {
      final tasks = _newestFirst(_tasks(60));
      for (final t in tasks) {
        t.status = DownloadStatus.queued;
      }
      final store = QueueStore(MemoryBox());
      await store.save(tasks, maxTasks: 50);

      final restored = store.load();
      expect(restored, hasLength(50));
      // All queued: the newest 50 are what is left — the oldest 10 go the
      // documented way once there is nothing finished to spend first.
      expect(
        [for (final t in restored) t.id],
        [
          't59',
          't58',
          't57',
          't56',
          't55',
          't54',
          't53',
          't52',
          't51',
          't50',
          't49',
          't48',
          't47',
          't46',
          't45',
          't44',
          't43',
          't42',
          't41',
          't40',
          't39',
          't38',
          't37',
          't36',
          't35',
          't34',
          't33',
          't32',
          't31',
          't30',
          't29',
          't28',
          't27',
          't26',
          't25',
          't24',
          't23',
          't22',
          't21',
          't20',
          't19',
          't18',
          't17',
          't16',
          't15',
          't14',
          't13',
          't12',
          't11',
          't10',
        ],
      );
    },
  );

  test('failed tasks are treated as work, not history', () async {
    // A failed download kept its staging directory so Retry can continue it;
    // saving must not prefer finished downloads over the resumable ones.
    final tasks = _newestFirst(_tasks(60));
    for (final t in tasks) {
      t.status = t.id == 't0'
          ? DownloadStatus.failed
          : DownloadStatus.completed;
    }
    final store = QueueStore(MemoryBox());
    await store.save(tasks);

    expect([for (final t in store.load()) t.id], contains('t0'));
  });

  test('a caller-supplied limit cannot push the box past the clamp', () async {
    final tasks = _newestFirst(_tasks(10));
    final store = QueueStore(MemoryBox());
    await store.save(tasks, maxTasks: 999999);
    expect(store.load(), hasLength(10));

    await store.save(tasks, maxTasks: 0);
    expect(store.load(), hasLength(1), reason: 'clamped to the minimum');
  });
}
