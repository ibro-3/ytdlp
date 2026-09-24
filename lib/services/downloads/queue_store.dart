import 'package:hive/hive.dart';

import '../../core/models/download_task.dart';

/// Persists the download queue so a killed app (backgrounded on Android,
/// low memory, a reboot) does not lose in-flight work.
///
/// Only task snapshots are stored — never downloaded files. A task that was
/// running when the process died comes back as `failed` with a resume hint,
/// because the old child process is long gone; its staging directory is kept
/// so Retry continues the partial download instead of starting over.
class QueueStore {
  QueueStore(this._box);

  final Box<dynamic> _box;

  static const _key = 'queue';

  /// Most recent tasks are the only ones worth restoring; older ones are
  /// dropped so the box cannot grow without bound.
  static const _maxTasks = 50;

  List<DownloadTask> load() {
    final raw = _box.get(_key);
    if (raw is! List) return const [];
    final tasks = <DownloadTask>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      try {
        final task = DownloadTask.fromMap(Map<String, dynamic>.from(entry));
        if (task.id.isEmpty) continue;
        tasks.add(task);
      } catch (_) {
        // A single corrupt record must not break the whole queue.
      }
    }
    return tasks;
  }

  Future<void> save(List<DownloadTask> tasks) {
    final snapshot = [for (final t in tasks.take(_maxTasks)) t.toMap()];
    return _box.put(_key, snapshot);
  }

  Future<void> clear() => _box.delete(_key);
}
