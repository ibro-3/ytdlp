import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/models/download_record.dart';
import '../../core/models/download_task.dart';
import '../../core/models/video_info.dart';
import '../notifications/notification_service.dart';
import '../settings/settings_service.dart';
import '../ytdlp/progress_parser.dart';
import '../ytdlp/ytdlp_service.dart';
import 'download_layout.dart';
import 'history_service.dart';
import 'queue_store.dart';

/// Runs a bounded queue of downloads with deterministic cancellation.
///
/// A task is created by [enqueue] in `queued` state and is only picked up by
/// the scheduler once a download slot is free. Cancellation marks the task
/// as canceled immediately — a queued task can never start afterwards, and a
/// running task kills its process and cleans up its staging directory.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.ytdlp,
    required this.history,
    required this.downloadsDir,
    this.settings,
    this.notifications,
    this.queueStore,
    this.maxConcurrency = 1,
  }) {
    if (queueStore != null) unawaited(_restore());
  }

  final DownloadEngine ytdlp;
  final HistoryService history;
  final Future<Directory> Function() downloadsDir;
  final SettingsService? settings;
  final NotificationService? notifications;
  final QueueStore? queueStore;
  final int maxConcurrency;

  final List<DownloadTask> _tasks = [];
  final Map<String, DownloadProcess> _processes = {};

  DateTime _lastUiNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _persistDebounce;
  bool _restoring = false;

  /// Per-task throttle state for progress notifications (≤ 1 per 2s, and
  /// only when the percentage actually changed).
  final Map<String, ({int pct, DateTime at})> _progressNotification = {};

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// Tasks that are either queued or actively downloading.
  int get activeCount =>
      _tasks.where((t) => t.status == DownloadStatus.downloading).length;

  /// Tasks waiting for a free slot.
  int get queuedCount =>
      _tasks.where((t) => t.status == DownloadStatus.queued).length;

  /// Restores the persisted queue after a restart.
  ///
  /// Work that was in flight is surfaced as `failed` (its process died with
  /// the app) but keeps its staging directory, so one tap on Retry continues
  /// the partial download. Staging directories no task refers to are deleted
  /// so an interrupted run cannot leak gigabytes forever.
  Future<void> _restore() async {
    final store = queueStore;
    if (store == null) return;
    _restoring = true;
    try {
      final restored = store.load();
      for (final task in restored) {
        if (task.status == DownloadStatus.queued ||
            task.status == DownloadStatus.downloading) {
          task.status = DownloadStatus.failed;
          task.error =
              'Interrupted when the app closed — tap Retry to continue.';
        }
        _tasks.add(task);
      }
      _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await _cleanOrphanStaging(restored.map((t) => t.stagingPath).toSet());
      notifyListeners();
    } catch (_) {
      // A broken store must never prevent the app from starting.
    } finally {
      _restoring = false;
    }
  }

  /// Deletes staging directories under the download root that no task
  /// references.
  Future<void> _cleanOrphanStaging(Set<String?> keep) async {
    try {
      final root = await _downloadRoot();
      final stagingRoot = Directory(p.join(root, '.ytdlp-staging'));
      if (!await stagingRoot.exists()) return;
      final live = keep.whereType<String>().map(p.normalize).toSet();
      await for (final entity in stagingRoot.list()) {
        if (entity is! Directory) continue;
        if (live.contains(p.normalize(entity.path))) continue;
        await _deleteRecursive(entity.path);
      }
      if (await stagingRoot.list().isEmpty) await stagingRoot.delete();
    } catch (_) {}
  }

  /// Persists the queue, debounced so progress updates don't hammer storage.
  void _schedulePersist() {
    if (_restoring || queueStore == null) return;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persist());
    });
  }

  Future<void> _persist() async {
    final store = queueStore;
    if (store == null) return;
    try {
      await store.save(_tasks);
    } catch (_) {
      // Persistence is best-effort; a download must not fail because of it.
    }
  }

  /// Enqueues a download. Returns the created task.
  ///
  /// [stagingPath] lets a retry reuse a previous attempt's staging directory
  /// so yt-dlp can continue its `.part` file instead of starting from zero.
  DownloadTask enqueue({
    required VideoInfo video,
    required Format format,
    String? stagingPath,
  }) {
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      video: video,
      format: format,
      createdAt: DateTime.now(),
      stagingPath: stagingPath,
    );
    _tasks.insert(0, task);
    notifyListeners();
    _pump();
    return task;
  }

  /// Starts at most [maxConcurrency] downloads, oldest queued first.
  void _pump() {
    if (_runningCount >= maxConcurrency) return;
    final candidates = _tasks.reversed.where(
      (t) => t.status == DownloadStatus.queued,
    );
    for (final task in candidates) {
      if (_runningCount >= maxConcurrency) break;
      task.status = DownloadStatus.downloading;
      notifyListeners();
      unawaited(_run(task));
    }
  }

  /// Currently active downloads (started but not yet finished/canceled).
  int get _runningCount =>
      _tasks.where((t) => t.status == DownloadStatus.downloading).length;

  bool _isCanceled(DownloadTask task) => task.status == DownloadStatus.canceled;

  Future<void> _run(DownloadTask task) async {
    final id = task.id;
    Directory? staging;
    try {
      final root = await _downloadRoot();
      if (_isCanceled(task)) return;

      // Each task downloads into an isolated staging directory next to the
      // final location (same filesystem ⇒ the final move is a rename). A retry
      // reuses its previous directory so yt-dlp can continue the .part file.
      final stagingRoot = p.join(root, '.ytdlp-staging');
      staging =
          await _resumeStaging(stagingRoot, task) ??
          Directory(p.join(stagingRoot, id));
      await staging.create(recursive: true);
      task.stagingPath = staging.path;
      if (_isCanceled(task)) return;

      DownloadProcess? dl;
      try {
        dl = await ytdlp.startDownload(
          url: task.video.webUrl,
          format: task.format,
          outputDir: staging.path,
          template: _stagingTemplate(task),
          cookiesPath: settings?.settings.cookiesPath,
        );
      } on YtdlpException catch (e) {
        return _fail(task, e.message);
      } catch (e) {
        return _fail(task, e.toString());
      }
      if (_isCanceled(task)) {
        dl.cancel();
        return;
      }
      _processes[id] = dl;

      String? lastDestination;
      await for (final line in dl.lines) {
        if (_isCanceled(task)) break;
        final dest = YtdlpProgressParser.parseDestination(line);
        if (dest != null) {
          task.destinationPath = dest;
          lastDestination = dest;
          _maybeNotifyUi();
        }
        final merged = YtdlpProgressParser.parseMergedFile(line);
        if (merged != null) {
          task.destinationPath = merged;
          lastDestination = merged;
          _maybeNotifyUi();
        }
        final prog = YtdlpProgressParser.parseProgress(line);
        if (prog != null) {
          task.progress = prog.progress ?? task.progress;
          if (prog.speed != null) task.speed = prog.speed;
          if (prog.eta != null) task.eta = prog.eta;
          _maybeNotifyProgress(task);
          _maybeNotifyUi();
        }
        final err = YtdlpProgressParser.parseError(line);
        if (err != null && task.error == null) {
          task.error = err;
          _maybeNotifyUi();
        }
      }
      if (_isCanceled(task)) return;

      final code = await dl.exitCode;
      _processes.remove(id);
      if (code != 0) {
        return _fail(task, task.error ?? 'yt-dlp exited with code $code');
      }

      // Validate the produced file before reporting completion. Only files
      // inside this task's staging directory count.
      final source = await _findFinalFile(staging, task, lastDestination);
      if (source == null) {
        return _fail(
          task,
          'Download finished but the output file was not found or was empty.',
        );
      }

      final layout = resolveDownloadLayout(root: root, kind: task.format.kind);
      final finalFile = await _moveToFinal(source, layout.directory);
      if (finalFile == null) {
        return _fail(task, 'Could not move the downloaded file into place.');
      }

      task.status = DownloadStatus.completed;
      task.filePath = finalFile.path;
      task.progress = 1;
      task.speed = null;
      task.eta = null;
      _notifyDone(task, success: true);
      _maybeNotifyUi();

      // Persistence must never flip a completed download back to failed.
      try {
        await history.add(
          DownloadRecord(
            id: task.id,
            videoId: task.video.id,
            title: task.video.title,
            author: task.video.author,
            thumbnail: task.video.thumbnail,
            filePath: finalFile.path,
            size: finalFile.size,
            createdAt: task.createdAt,
          ),
        );
      } catch (e) {
        task.warning = 'Downloaded but could not be added to the library: $e';
        _maybeNotifyUi();
      }
    } catch (e) {
      if (!_isCanceled(task)) {
        _fail(task, e.toString());
      }
    } finally {
      _processes.remove(id);
      _progressNotification.remove(id);
      // A failed task keeps its staging directory (and yt-dlp's .part file)
      // so Retry can continue instead of re-downloading from the start.
      // Completed and canceled tasks clean up after themselves.
      final keepForResume = task.status == DownloadStatus.failed;
      if (!keepForResume) {
        final stagingPath = staging?.path ?? task.stagingPath;
        if (stagingPath != null) {
          await _deleteRecursive(stagingPath);
          // Remove the now-empty staging root (best effort; a concurrent
          // task may still be using it, in which case this is a no-op).
          final parent = p.dirname(stagingPath);
          if (p.basename(parent) == '.ytdlp-staging') {
            try {
              await Directory(parent).delete();
            } catch (_) {}
          }
        }
        task.stagingPath = null;
      }
      if (_isCanceled(task)) {
        unawaited(_cancelNotification(id));
      }
      _maybeNotifyUi();
      _pump();
    }
  }

  /// The previous staging directory of [task] when it is still usable, so the
  /// download resumes from its `.part` file. Only directories inside the
  /// current staging root are accepted — a path that no longer matches the
  /// configured download root is ignored.
  Future<Directory?> _resumeStaging(
    String stagingRoot,
    DownloadTask task,
  ) async {
    final path = task.stagingPath;
    if (path == null) return null;
    if (!p.isWithin(stagingRoot, path)) return null;
    final dir = Directory(path);
    return await dir.exists() ? dir : null;
  }

  /// Template used inside the staging directory. Playlists are out of
  /// scope today, so a plain per-video template keeps all output flat.
  String _stagingTemplate(DownloadTask task) => '%(title)s [%(id)s].%(ext)s';

  /// Marks [task] as failed, notifies, and stops the pipeline. Returns void
  /// so callers can `return _fail(...)` and let the `finally` block clean up.
  void _fail(DownloadTask task, String message) {
    task.status = DownloadStatus.failed;
    task.error = message;
    _notifyDone(task, success: false);
    _maybeNotifyUi();
  }

  /// Picks the final file this task produced: the reported destination (or
  /// merged file) when it is valid, otherwise the newest matching file in
  /// the staging directory. Never accepts files outside staging.
  Future<String?> _findFinalFile(
    Directory staging,
    DownloadTask task,
    String? lastDestination,
  ) async {
    if (lastDestination != null &&
        p.isWithin(staging.path, lastDestination) &&
        await _isValidFile(lastDestination)) {
      return lastDestination;
    }
    FileStat? newest;
    String? newestPath;
    try {
      await for (final entity in staging.list()) {
        if (entity is! File) continue;
        if (!entity.path.contains('[${task.video.id}]')) continue;
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file || stat.size <= 0) continue;
        if (newest == null || stat.modified.isAfter(newest.modified)) {
          newest = stat;
          newestPath = entity.path;
        }
      }
    } catch (_) {
      return null;
    }
    return newestPath;
  }

  Future<bool> _isValidFile(String path) async {
    try {
      final stat = await File(path).stat();
      return stat.type == FileSystemEntityType.file && stat.size > 0;
    } catch (_) {
      return false;
    }
  }

  /// Renames [source] into [finalDir] with a unique name, returning the new
  /// path and its size.
  Future<({String path, int size})?> _moveToFinal(
    String source,
    String finalDirPath,
  ) async {
    try {
      final dir = Directory(finalDirPath);
      await dir.create(recursive: true);
      final base = p.basename(source);
      final dot = base.lastIndexOf('.');
      final stem = dot > 0 ? base.substring(0, dot) : base;
      final ext = dot > 0 ? base.substring(dot) : '';
      var candidate = p.join(finalDirPath, base);
      var i = 1;
      while (await File(candidate).exists()) {
        candidate = p.join(finalDirPath, '$stem ($i)$ext');
        i++;
      }
      await File(source).rename(candidate);
      final stat = await File(candidate).stat();
      return (path: candidate, size: stat.size);
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteRecursive(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// UI-driven throttling: task fields update on every stream line, but
  /// widgets are rebuilt at most ~10×/second.
  void _maybeNotifyUi() {
    _schedulePersist();
    final now = DateTime.now();
    if (now.difference(_lastUiNotify).inMilliseconds >= 100) {
      _lastUiNotify = now;
      notifyListeners();
    }
  }

  bool get _notificationsOn => settings?.settings.notificationsEnabled ?? true;

  /// Root folder for downloads: the user-configured one when set, otherwise
  /// the platform default.
  Future<String> _downloadRoot() async {
    final configured = settings?.settings.downloadRoot.trim() ?? '';
    if (configured.isNotEmpty) return configured;
    return (await downloadsDir()).path;
  }

  void _notifyDone(DownloadTask task, {required bool success}) {
    if (!_notificationsOn) return;
    final n = notifications;
    if (n == null) return;
    unawaited(
      n.showDone(
        taskId: task.id,
        title: task.video.title,
        success: success,
        detail: success ? null : task.error,
      ),
    );
  }

  /// Progress notifications, at most one per 2 seconds per task.
  void _maybeNotifyProgress(DownloadTask task) {
    if (!_notificationsOn) return;
    final n = notifications;
    if (n == null) return;
    final pct = (task.progress * 100).round();
    final now = DateTime.now();
    final last = _progressNotification[task.id];
    if (last != null &&
        (last.pct == pct || now.difference(last.at).inSeconds < 2)) {
      return;
    }
    _progressNotification[task.id] = (pct: pct, at: now);
    unawaited(
      n.showProgress(
        taskId: task.id,
        title: task.video.title,
        progress: task.progress,
        speed: task.speed,
        eta: task.eta,
      ),
    );
  }

  Future<void> _cancelNotification(String id) async {
    if (!_notificationsOn) return;
    final n = notifications;
    if (n == null) return;
    try {
      await n.cancel(id);
    } catch (_) {}
  }

  /// Cancels a queued or running task. A canceled task can never resume.
  void cancel(String id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    switch (task.status) {
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        task.status = DownloadStatus.canceled;
        _processes[id]?.cancel();
        unawaited(_cancelNotification(id));
        notifyListeners();
        break;
      case DownloadStatus.completed:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
        break;
    }
  }

  /// Re-enqueues a failed task with a fresh id, reusing its staging directory
  /// so yt-dlp continues the partial download.
  DownloadTask? retry(DownloadTask task) {
    if (task.status != DownloadStatus.failed) return null;
    _tasks.removeWhere((t) => t.id == task.id);
    final next = enqueue(
      video: task.video,
      format: task.format,
      stagingPath: task.stagingPath,
    );
    notifyListeners();
    return next;
  }

  /// Removes a finished/canceled task from the queue without touching the
  /// downloaded file. Any staging directory kept for a resume is reclaimed.
  /// Returns false when the task is still running.
  bool dismiss(String id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return false;
    if (task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.downloading) {
      return false;
    }
    _tasks.removeWhere((t) => t.id == id);
    final staging = task.stagingPath;
    if (staging != null) unawaited(_deleteRecursive(staging));
    notifyListeners();
    return true;
  }

  /// Deletes the downloaded file (when present) and its history record.
  /// Returns false when the file existed but could not be deleted — in that
  /// case the history record is kept.
  Future<bool> deleteTask(DownloadTask task) async {
    final path = task.filePath;
    if (path != null && await File(path).exists()) {
      try {
        await File(path).delete();
      } catch (_) {
        return false;
      }
    }
    try {
      await history.remove(task.id);
    } catch (_) {
      // Even if the record could not be removed, the file is gone.
    }
    _tasks.removeWhere((t) => t.id == task.id);
    final staging = task.stagingPath;
    if (staging != null) await _deleteRecursive(staging);
    notifyListeners();
    return true;
  }

  /// Opens the downloaded file. Returns false when the file is missing or
  /// the platform could not open it.
  Future<bool> openTask(DownloadTask task) async {
    final path = task.filePath;
    if (path == null || !await File(path).exists()) return false;
    try {
      await OpenFilex.open(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Shares the downloaded file. Returns false when it is missing.
  Future<bool> shareTask(DownloadTask task) async {
    final path = task.filePath;
    if (path == null || !await File(path).exists()) return false;
    try {
      await SharePlus.instance.share(
        ShareParams(title: task.video.title, files: [XFile(path)]),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    for (final dl in _processes.values) {
      try {
        dl.cancel();
      } catch (_) {}
    }
    _processes.clear();
    for (final t in _tasks) {
      if (t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.downloading) {
        t.status = DownloadStatus.canceled;
      }
    }
    super.dispose();
  }
}
