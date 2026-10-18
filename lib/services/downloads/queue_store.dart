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

  /// Used when the caller does not specify a limit. Matches the Settings
  /// default so a store written before the setting existed keeps behaving the
  /// same way.
  static const defaultMaxTasks = 50;

  /// Most recent tasks are the only ones worth restoring; older ones are
  /// dropped so the box cannot grow without bound.
  static const _maxTasks = 500;

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
    // Snapshots are written newest-first, so the stored order already is the
    // display order. Sorting by createdAt as well makes the invariant explicit
    // and repairs a hand-edited box.
    tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return tasks;
  }

  /// Persists [tasks], keeping the [maxTasks] most recent.
  ///
  /// A caller-supplied limit is clamped to [_maxTasks] so a corrupt settings
  /// value cannot make the box grow without bound. The tasks are already
  /// newest-first (the manager keeps them that way), and the newest are the
  /// ones kept first.
  ///
  /// When the queue is longer than the limit, the *finished* tasks are the
  /// first candidates for dropping — oldest first — and only after every
  /// settled one is gone does truncation start costing unfinished work.
  /// Dropping straight from the front of the newest-first list meets the
  /// limit just the same, but meets it *the wrong way round*: the oldest
  /// entries are usually downloads that the library already holds, while a
  /// long queue keeps its oldest **queued** downloads at the bottom — where a
  /// 60-task queue past the limit used to lose exactly those ten links, and
  /// no card ever said so.
  Future<void> save(
    List<DownloadTask> tasks, {
    int maxTasks = defaultMaxTasks,
  }) {
    final limit = maxTasks.clamp(1, _maxTasks);
    final snapshot = <Map<String, dynamic>>[
      for (final t in _trim(tasks, limit)) t.toMap(),
    ];
    return _box.put(_key, snapshot);
  }

  /// The subset of [tasks] to persist when it exceeds [limit].
  ///
  /// [tasks] arrives newest-first; the oldest are the candidates for dropping,
  /// taken finished-first so finished downloads cost nothing to lose and
  /// queued ones cost everything ([DownloadStatus.failed] counts as
  /// unfinished: its staging directory is the part kept for a retry).
  static List<DownloadTask> _trim(List<DownloadTask> tasks, int limit) {
    if (tasks.length <= limit) return tasks;
    var toDrop = tasks.length - limit;
    final drop = <String>{};
    // Pass 1: the oldest finished tasks first.
    const settled = {DownloadStatus.completed, DownloadStatus.canceled};
    for (final t in tasks.reversed) {
      if (toDrop <= 0) break;
      if (!settled.contains(t.status)) continue;
      drop.add(t.id);
      toDrop--;
    }
    // Pass 2: still over the limit? The oldest of whatever is left goes, at
    // which point work is being lost — but no less than the limit demands.
    for (final t in tasks.reversed) {
      if (toDrop <= 0) break;
      if (drop.contains(t.id)) continue;
      drop.add(t.id);
      toDrop--;
    }
    return [
      for (final t in tasks)
        if (!drop.contains(t.id)) t,
    ];
  }

  Future<void> clear() => _box.delete(_key);
}
