import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/download_options.dart';
import '../../core/models/download_record.dart';
import '../../core/models/download_task.dart';
import '../../core/models/output_template.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/video_info.dart';
import '../../core/models/yt_prefs.dart';
import '../../core/models/youtube_prefs.dart';
import '../foreground/foreground_service.dart';
import '../notifications/notification_service.dart';
import '../settings/settings_service.dart';
import '../ytdlp/arg_tokenizer.dart';
import '../ytdlp/progress_parser.dart';
import '../ytdlp/ytdlp_service.dart';
import 'download_layout.dart';
import 'network_probe.dart';
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
    this.foregroundService,
    NetworkProbe? networkProbe,
    int maxConcurrency = 1,
  }) : _maxConcurrency = maxConcurrency.clamp(1, 8),
       _networkProbe = networkProbe ?? PluginNetworkProbe() {
    if (queueStore != null) unawaited(_restore());
  }

  final DownloadEngine ytdlp;
  final HistoryService history;
  final Future<Directory> Function() downloadsDir;
  final SettingsService? settings;
  final NotificationService? notifications;
  final QueueStore? queueStore;
  final ForegroundService? foregroundService;

  final List<DownloadTask> _tasks = [];
  final Map<String, DownloadProcess> _processes = {};
  final NetworkProbe _networkProbe;

  /// Distinguishes tasks created within the same microsecond.
  ///
  /// A playlist batch calls `enqueue` in a tight loop, where
  /// `microsecondsSinceEpoch` repeats — and task ids key `_processes`, the
  /// notification id and the queue snapshot, so a collision would cancel or
  /// overwrite the wrong download.
  int _idCounter = 0;

  DateTime _lastUiNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _persistDebounce;
  bool _restoring = false;

  /// When set, no *new* download starts until it is cleared. A running one is
  /// left alone rather than killed: pausing should not throw away a partial
  /// download the user spent bandwidth on. Set by [pause] / cleared by
  /// [resume] / [togglePause].
  bool _paused = false;

  /// Whether the queue is paused. Not persisted — a pause is a decision about
  /// the current session, and silently restoring one on next launch would look
  /// like the app was broken.
  bool get isPaused => _paused;

  /// The concurrency this manager was constructed with. Kept mutable so a
  /// Settings change takes effect without rebuilding the provider, which would
  /// discard the live queue.
  int _maxConcurrency;

  /// Live concurrency limit. Changing it up starts waiting tasks immediately;
  /// changing it down only stops new ones, since a running download is not
  /// interrupted.
  int get maxConcurrency => _maxConcurrency;

  set maxConcurrency(int value) {
    final next = value.clamp(1, 8);
    if (next == _maxConcurrency) return;
    _maxConcurrency = next;
    _pump();
    notifyListeners();
  }

  /// Pauses the queue: no further downloads start until [resume].
  ///
  /// Already-running downloads continue, so this costs nothing that was
  /// already paid for.
  void pause() {
    if (_paused) return;
    _paused = true;
    // Releasing the foreground service while downloads are still running
    // would let Android kill the app mid-download, so it is left up; the
    // completion path stops it.
    notifyListeners();
  }

  /// Resumes a paused queue, starting as many waiting tasks as concurrency
  /// allows.
  void resume() {
    if (!_paused) return;
    _paused = false;
    resumeAllPaused();
    _pump();
    notifyListeners();
  }

  /// Resumes the queue. Also releases anything held by [pauseTask], so a
  /// global "go" cannot leave an individual task stranded behind a
  /// per-card pause the user has since forgotten about.
  void togglePause() => _paused ? resume() : pause();

  /// Tasks whose process is being stopped by [pauseTask] and whose `_run` is
  /// still unwinding.
  ///
  /// Needed because the run loop has to distinguish "stopped because the user
  /// paused this one task" from "stopped because the download failed": the
  /// first keeps its staging directory and lands in [DownloadStatus.paused], the
  /// second is a failure.
  final Set<String> _pausing = {};

  /// Set by [dispose], so a run loop that wakes up afterwards (because
  /// disposing killed its process) stays silent.
  bool _disposed = false;

  /// Per-task throttle state for progress notifications (≤ 1 per 2s, and
  /// only when the percentage actually changed).
  final Map<String, ({int pct, DateTime at})> _progressNotification = {};

  /// Throttle state for the single foreground-service notification.
  ({int pct, DateTime at})? _foregroundNotification;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// Tasks that are either queued or actively downloading.
  int get activeCount =>
      _tasks.where((t) => t.status == DownloadStatus.downloading).length;

  /// Tasks waiting for a free slot.
  int get queuedCount =>
      _tasks.where((t) => t.status == DownloadStatus.queued).length;

  /// Waiting tasks in the order the scheduler will start them: oldest first.
  ///
  /// [tasks] is newest-first for display, so this is that order reversed among
  /// the queued subset. Exposed so the queue UI can show "next up" truthfully
  /// rather than re-deriving the ordering.
  List<DownloadTask> get queueInStartOrder => _tasks
      .where((t) => t.status == DownloadStatus.queued)
      .toList()
      .reversed
      .toList();

  /// Tasks that have reached a terminal state.
  int get completedCount =>
      _tasks.where((t) => t.status == DownloadStatus.completed).length;

  int get failedCount =>
      _tasks.where((t) => t.status == DownloadStatus.failed).length;

  /// Reorders a waiting task within the queue, moving it [offset] places
  /// earlier (negative) or later (positive) among the *queued* tasks only.
  ///
  /// Only queued tasks are considered: a running download cannot be reprioritised
  /// meaningfully, and reordering the whole list would be confusing because
  /// finished tasks are interleaved. Returns false when the task is not queued
  /// or the move would leave the queue.
  bool reorder(String id, int offset) {
    if (offset == 0) return false;
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status != DownloadStatus.queued) return false;

    // The scheduler picks the oldest queued task and [tasks] is newest-first,
    // so "earlier in the queue" is a higher index.
    final queued = queueInStartOrder;
    final index = queued.indexWhere((t) => t.id == id);
    if (index < 0) return false;

    final target = (index + offset).clamp(0, queued.length - 1);
    if (target == index) return false;

    // Re-stamp the queued tasks' createdAt so the scheduler's "oldest first"
    // ordering follows the new sequence, then re-sort into display order.
    for (var i = 0; i < queued.length; i++) {
      queued[i].createdAt = DateTime.fromMicrosecondsSinceEpoch(i + 1);
    }
    final moved = queued.removeAt(index);
    queued.insert(target, moved);
    for (var i = 0; i < queued.length; i++) {
      queued[i].createdAt = DateTime.fromMicrosecondsSinceEpoch(i + 1);
    }
    _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
    return true;
  }

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
            task.status == DownloadStatus.downloading ||
            // A hold was a decision about the session that just ended, the same
            // as the global pause, so it is not silently restored either.
            task.status == DownloadStatus.paused) {
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
      await store.save(
        _tasks,
        maxTasks: settings?.settings.maxQueueSize ?? QueueStore.defaultMaxTasks,
      );
    } catch (_) {
      // Persistence is best-effort; a download must not fail because of it.
    }
  }

  /// Persists right away rather than on the debounce timer, for changes that
  /// shrink the queue and would otherwise be lost if the app died first.
  Future<void> _schedulePersistNow() async {
    _persistDebounce?.cancel();
    await _persist();
  }

  /// Enqueues a download. Returns the created task.
  ///
  /// [stagingPath] lets a retry reuse a previous attempt's staging directory
  /// so yt-dlp can continue its `.part` file instead of starting from zero.
  DownloadTask enqueue({
    required VideoInfo video,
    required Format format,
    DownloadOptions options = const DownloadOptions(),
    String? stagingPath,
    String? playlistId,
    String? playlistTitle,
    List<String> extraArgs = const [],
    String outputTemplate = '',
    YtPrefs? prefs,
    YoutubePrefs? youtube,
  }) {
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}',
      video: video,
      format: format,
      createdAt: DateTime.now(),
      options: options,
      // An empty override means "whatever Settings says when this runs", so a
      // later default change still applies to a task enqueued before it.
      extraArgs: extraArgs,
      outputTemplate: outputTemplate,
      prefs: prefs ?? settings?.settings.ytPrefs ?? const YtPrefs(),
      youtube: youtube ?? settings?.settings.youtube ?? const YoutubePrefs(),
      stagingPath: stagingPath,
      playlistId: playlistId,
      playlistTitle: playlistTitle,
    );
    _tasks.insert(0, task);
    notifyListeners();
    _pump();
    return task;
  }

  /// Enqueues one task per selected entry of [playlist], all sharing the same
  /// [format] and [options].
  ///
  /// Each entry becomes its own yt-dlp process rather than one
  /// `--yes-playlist` run, so every video keeps its own progress, retry and
  /// cancel, and one unavailable entry cannot fail the rest. `--no-playlist`
  /// therefore stays in the args: each URL here is a single video.
  ///
  /// Returns the created tasks in playlist order.
  List<DownloadTask> enqueuePlaylist({
    required PlaylistInfo playlist,
    required List<VideoInfo> selected,
    required Format format,
    DownloadOptions options = const DownloadOptions(),
  }) {
    if (selected.isEmpty) return const [];
    // One id shared by every entry, so the queue can group them and
    // "cancel all in this playlist" has something to match on. A playlist
    // without a usable id falls back to its title, then to a unique value.
    final groupId = playlist.id.isNotEmpty
        ? playlist.id
        : (playlist.title.isNotEmpty
              ? playlist.title
              : 'playlist-${DateTime.now().microsecondsSinceEpoch}');
    final title = playlist.title;

    final created = <DownloadTask>[];
    for (final video in selected) {
      created.add(
        enqueue(
          video: video,
          format: format,
          options: options,
          playlistId: groupId,
          playlistTitle: title,
        ),
      );
    }
    return created;
  }

  /// Cancels every queued or running task, leaving finished ones alone.
  /// Returns how many were affected.
  int cancelAll() {
    var n = 0;
    for (final task in _tasks.toList()) {
      final status = task.status;
      if (status != DownloadStatus.queued &&
          status != DownloadStatus.paused &&
          status != DownloadStatus.downloading) {
        continue;
      }
      cancel(task.id);
      n++;
    }
    return n;
  }

  /// Removes every finished task — completed, failed or canceled — from the
  /// queue without touching downloaded files. Returns how many were removed.
  ///
  /// Paused tasks are left alone: they still have work to do, and silently
  /// dropping a held download would be the opposite of what the user asked for.
  ///
  /// Staging directories kept for a resume are reclaimed, so a long-lived
  /// queue cannot accumulate them after a batch of failures.
  int clearFinished() {
    final removable = _tasks
        .where(
          (t) =>
              t.status == DownloadStatus.completed ||
              t.status == DownloadStatus.failed ||
              t.status == DownloadStatus.canceled,
        )
        .toList();
    for (final task in removable) {
      final staging = task.stagingPath;
      if (staging != null) unawaited(_deleteRecursive(staging));
    }
    _tasks.removeWhere((t) => removable.contains(t));
    if (removable.isNotEmpty) {
      unawaited(_schedulePersistNow());
      notifyListeners();
    }
    return removable.length;
  }

  /// Number of tasks that [clearFinished] would remove.
  int get finishedCount => _tasks
      .where(
        (t) =>
            t.status == DownloadStatus.completed ||
            t.status == DownloadStatus.failed ||
            t.status == DownloadStatus.canceled,
      )
      .length;

  /// Cancels every task belonging to [playlistId]. Returns how many were
  /// affected. Used by the playlist group's "Cancel all" action.
  int cancelPlaylist(String playlistId) {
    var n = 0;
    for (final task in _tasks.toList()) {
      if (task.playlistId != playlistId) continue;
      if (task.status != DownloadStatus.queued &&
          task.status != DownloadStatus.paused &&
          task.status != DownloadStatus.downloading) {
        continue;
      }
      cancel(task.id);
      n++;
    }
    return n;
  }

  /// Starts as many waiting downloads as the concurrency limit and
  /// pause state allow, oldest queued first.
  void _pump() {
    // A run loop calls this from its `finally`, which can happen
    // after dispose.
    if (_disposed) return;
    // A paused queue holds everything until resumed; running tasks
    // are untouched.
    if (_paused) return;
    if (_runningCount >= _maxConcurrency) return;
    final candidates = _tasks.reversed.where(
      (t) => t.status == DownloadStatus.queued,
    );
    // Metered-data guard, consulted once per pump rather than per
    // task: the setting is identical for every candidate, and the
    // probe answers from the connectivity it last saw. Consulted per
    // pump rather than polled on a timer, so nothing runs between a
    // network change and the next natural pump.
    if (!_networkProbe.mayStart(wifiOnly: _wifiOnlyFromSettings())) {
      notifyListeners();
      return;
    }
    for (final task in candidates) {
      if (_runningCount >= _maxConcurrency) break;
      task.status = DownloadStatus.downloading;
      // Start the foreground service so the OS doesn't kill us. The throttle is
      // reset so the very first progress update is never swallowed by a
      // percentage recorded for a previous task.
      _foregroundNotification = null;
      unawaited(_startForeground(task));
      notifyListeners();
      unawaited(_run(task));
    }
  }

  /// Re-examines the queue, e.g. because the network just changed.
  ///
  /// The metered-data gate is consulted on every pump, but a pump only
  /// happens when work is queued, finishes or is resumed — so a queue
  /// held back by the "unmetered only" rule stays held until something
  /// calls this. The connectivity stream does; a test can too.
  void onConnectivityChanged() {
    unawaited(
      // Refresh first so the gate answers on the new connectivity,
      // not the one the previous pump saw.
      _networkProbe.refresh().then((_) => _pump()),
    );
  }

  /// Currently active downloads (started but not yet finished/canceled).
  int get _runningCount =>
      _tasks.where((t) => t.status == DownloadStatus.downloading).length;

  bool _isCanceled(DownloadTask task) => task.status == DownloadStatus.canceled;

  /// Whether [task] is mid-pause: its process is being stopped so it can be
  /// released later, rather than having genuinely failed.
  bool _isPausing(DownloadTask task) => _pausing.contains(task.id);

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
          options: task.options,
          outputDir: staging.path,
          template: _stagingTemplate(task),
          cookiesPath: settings?.settings.cookiesPath,
          cookieBrowser: settings?.settings.cookieBrowser,
          cookieBrowserProfile: settings?.settings.cookieBrowserProfile ?? '',
          extraArgs: _extraArgsFor(task),
          prefs: task.prefs,
          youtube: task.youtube,
          archivePath: await _archivePathFor(task),
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
        // yt-dlp warnings are non-fatal (e.g. "webm doesn't support
        // embedding a thumbnail, mkv will be used") but worth showing so a
        // surprising container change or skipped embed is explainable.
        final warn = YtdlpProgressParser.parseWarning(line);
        if (warn != null && task.warning == null) {
          task.warning = warn;
          _maybeNotifyUi();
        }
      }
      if (_isCanceled(task)) return;

      final code = await dl.exitCode;
      _processes.remove(id);
      if (_isPausing(task)) {
        // Stopped on purpose by pauseTask. A non-zero exit is just the kill, so
        // it is not treated as a failure: the task is held with its .part
        // intact and releasing it continues from there.
        _pausing.remove(id);
        task.status = DownloadStatus.paused;
        task.speed = null;
        task.eta = null;
        return;
      }
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

      final layout = resolveDownloadLayout(
        root: root,
        kind: task.format.kind,
        playlistTitle: task.playlistTitle,
      );
      final finalFile = await _moveToFinal(source, layout.targetDirectory);
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
            playlistTitle: task.playlistTitle,
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
      // An interrupted task keeps its staging directory (and yt-dlp's .part
      // file) so Retry can continue instead of re-downloading from the start:
      // a failure, a pause, and a cancel all qualify, since the "Cancel all"
      // dialog and the per-card retry both promise the partial survives. A
      // completed task has nothing left to resume, so it cleans up.
      final keepForResume =
          task.status == DownloadStatus.failed ||
          task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.canceled;
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
      unawaited(_stopForegroundIfIdle());
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

  /// Template used inside the staging directory.
  ///
  /// Always flat, even for a playlist entry: each entry is its own task with
  /// its own staging directory, so yt-dlp writes exactly one media file (plus
  /// its sidecars) and `_findFinalFile` can scan one directory. The per-playlist
  /// grouping is applied by `_moveToFinal`, which appends the sanitized
  /// playlist folder to the final destination.
  ///
  /// A user template that names a playlist folder (`%(playlist_title)s/…`) has
  /// it stripped here: the folder is created by the app on the way out, and
  /// leaving it in would make yt-dlp write into a staging subdirectory that
  /// `_findFinalFile` does not scan.
  ///
  /// The task's own override wins over the Settings default, so a download
  /// started from the sheet's one-off template keeps the name it was given.
  String _stagingTemplate(DownloadTask task) => stripPlaylistPrefix(
    OutputTemplate(
      task.outputTemplate.trim().isNotEmpty
          ? task.outputTemplate
          : (settings?.settings.outputTemplate ?? ''),
    ).effective,
  );

  /// Path of the `--download-archive` ledger, kept in the app support dir so it
  /// survives the download folder being moved or cleared.
  ///
  /// The archive is what makes "skip what I already have" work across
  /// sessions, so it needs a stable path rather than one derived from the
  /// download root. Whether it is actually passed is decided by
  /// [YtPrefs.downloadArchive]; this only resolves the location.
  Future<String?> _archivePath() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return p.join(dir.path, 'downloaded.txt');
    } catch (_) {
      // Without a writable support dir the archive is simply not used; the
      // download itself must still work.
      return null;
    }
  }

  /// The archive path only when this task actually wants one, so the common
  /// case does not touch the filesystem at all.
  Future<String?> _archivePathFor(DownloadTask task) =>
      task.prefs.downloadArchive ? _archivePath() : Future.value(null);

  /// Extra arguments for [task]: its own override when the sheet supplied one,
  /// otherwise the Settings field tokenised now.
  ///
  /// Captured on the task so a retry repeats the command that failed. The
  /// Settings path is tokenised per run so editing the default takes effect
  /// without a migration.
  List<String> _extraArgsFor(DownloadTask task) {
    if (task.extraArgs.isNotEmpty) return task.extraArgs;
    final raw = settings?.settings.extraArgs ?? '';
    if (raw.trim().isEmpty) return const [];
    try {
      return tokenizeArgs(raw);
    } on ArgSyntaxException {
      // The UI refuses to start a download with an unparseable field, so this
      // is only reachable if the value changed outside the app. Ignoring it is
      // better than failing the download over a malformed extra flag.
      return const [];
    }
  }

  /// Marks [task] as failed, notifies, and stops the pipeline. Returns void
  /// so callers can `return _fail(...)` and let the `finally` block clean up.
  void _fail(DownloadTask task, String message) {
    task.status = DownloadStatus.failed;
    task.error = message;
    _notifyDone(task, success: false);
    _maybeNotifyUi();
  }

  /// Extensions that are never the media file itself: subtitle sidecars,
  /// thumbnails and yt-dlp partials. The final file is only ever picked
  /// from the remaining extensions so a `[download] Destination:` line for
  /// a `.vtt` or a lingering `.part` can never be reported as the result.
  static const Set<String> _nonMediaExtensions = {
    'srt',
    'vtt',
    'ass',
    'lrc',
    'jpg',
    'jpeg',
    'png',
    'webp',
    'part',
    'ytdl',
    'temp',
    'json',
  };

  /// Extensions worth keeping next to the media file once it lands in the
  /// final folder: subtitle sidecars and thumbnails. Deliberately excludes
  /// partials (`.part`/`.ytdl`/`.temp`) — nothing half-written should ever
  /// be moved into the library, and the staging cleanup removes them.
  static const Set<String> _movableArtifactExtensions = {
    'srt',
    'vtt',
    'ass',
    'lrc',
    'jpg',
    'jpeg',
    'png',
    'webp',
  };

  bool _isSidecar(String path, Set<String> extensions) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return extensions.contains(ext);
  }

  /// Picks the final file this task produced: the reported destination (or
  /// merged file) when it is a media file, otherwise the newest matching
  /// media file in the staging directory. Never accepts files outside
  /// staging, and never a sidecar or partial.
  ///
  /// The destination line is the primary signal and is independent of the
  /// output template. The directory scan is only a fallback for when that line
  /// is missing or unusable, and it filters by whatever the active template
  /// uses to identify the file — see [OutputTemplate.identityFragment], which
  /// returns null for a template that cannot distinguish one video's output
  /// from another's. Each task owns its staging directory, so an unfiltered
  /// scan is still safe; the filter only guards against a stray file that
  /// belongs to something else.
  Future<String?> _findFinalFile(
    Directory staging,
    DownloadTask task,
    String? lastDestination,
  ) async {
    if (lastDestination != null &&
        p.isWithin(staging.path, lastDestination) &&
        !_isSidecar(lastDestination, _nonMediaExtensions) &&
        await _isValidFile(lastDestination)) {
      return lastDestination;
    }
    final fragment = _identityFragment(task);
    FileStat? newest;
    String? newestPath;
    try {
      await for (final entity in staging.list()) {
        if (entity is! File) continue;
        // A null fragment means the template names every file identically, so
        // there is nothing to match on and every candidate is considered.
        if (fragment != null && !entity.path.contains(fragment)) continue;
        if (_isSidecar(entity.path, _nonMediaExtensions)) continue;
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

  /// The substring the active output template guarantees a finished file's
  /// name will contain. Mirrors the old hard-coded `[<id>]` check, but derived
  /// from the template so a user template that omits `%(id)s` still resolves.
  String? _identityFragment(DownloadTask task) => OutputTemplate(
    task.outputTemplate.trim().isNotEmpty
        ? task.outputTemplate
        : (settings?.settings.outputTemplate ?? ''),
  ).identityFragment(video: task.video);

  Future<bool> _isValidFile(String path) async {
    try {
      final stat = await File(path).stat();
      return stat.type == FileSystemEntityType.file && stat.size > 0;
    } catch (_) {
      return false;
    }
  }

  /// Moves [source] (the media file) and every sibling artifact in its
  /// staging directory — subtitle sidecars, thumbnails — into [finalDirPath],
  /// returning the moved media file and its size. The media rename is
  /// critical; moving sidecars is best-effort so a stubborn subtitle can
  /// never fail an otherwise completed download.
  Future<({String path, int size})?> _moveToFinal(
    String source,
    String finalDirPath,
  ) async {
    try {
      final dir = Directory(finalDirPath);
      await dir.create(recursive: true);
      // Move the media file first; if that fails there is nothing to
      // complete with.
      final media = await _moveUnique(source, finalDirPath);
      final staging = p.dirname(source);
      try {
        await for (final entity in Directory(staging).list()) {
          if (entity is! File || entity.path == source) continue;
          if (!_isSidecar(entity.path, _movableArtifactExtensions)) continue;
          try {
            await _moveUnique(entity.path, finalDirPath);
          } catch (_) {
            // Best effort: a sidecar that cannot be moved is left behind for
            // the staging cleanup to remove.
          }
        }
      } catch (_) {}
      final stat = await File(media).stat();
      return (path: media, size: stat.size);
    } catch (_) {
      return null;
    }
  }

  /// Renames a single file into [finalDirPath] with a unique name (appending
  /// " (n)" before the extension on collision, like the OS file manager).
  Future<String> _moveUnique(String source, String finalDirPath) async {
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
    return candidate;
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
    // A run loop can wake up after dispose: disposing cancels the processes,
    // which makes them exit, which unwinds the loop. Notifying then would throw
    // from a disposed ChangeNotifier, so every exit is dropped.
    if (_disposed) return;
    _schedulePersist();
    _updateForegroundNotification();
    final now = DateTime.now();
    if (now.difference(_lastUiNotify).inMilliseconds >= 100) {
      _lastUiNotify = now;
      notifyListeners();
    }
  }

  /// Starts the foreground service for a download task.
  Future<void> _startForeground(DownloadTask task) async {
    final fg = foregroundService;
    if (fg == null) return;
    try {
      await fg.startService(title: task.video.title, progress: task.progress);
    } catch (_) {
      // Foreground service failure must never break a download.
    }
  }

  /// Updates the foreground service notification with the latest progress.
  ///
  /// Throttled to a changed percentage and at most one update every 2 seconds.
  /// `_maybeNotifyUi` runs on every yt-dlp output line (capped at ~10/s), and
  /// each service update is a platform round trip — pushing all of them
  /// through floods the channel and makes the service slow to respond. A
  /// percentage ticking 10 times a second is also unreadable in a notification.
  void _updateForegroundNotification() {
    final fg = foregroundService;
    if (fg == null) return;
    // The oldest downloading task is the one the service was started for.
    DownloadTask? task;
    for (final t in _tasks) {
      if (t.status == DownloadStatus.downloading) {
        task = t;
        break;
      }
    }
    if (task == null) return;

    final pct = (task.progress * 100).round();
    final now = DateTime.now();
    final last = _foregroundNotification;
    if (last != null &&
        (last.pct == pct || now.difference(last.at).inSeconds < 2)) {
      return;
    }
    _foregroundNotification = (pct: pct, at: now);
    unawaited(
      fg.updateService(title: task.video.title, progress: task.progress),
    );
  }

  /// Stops the foreground service when no downloads are active.
  Future<void> _stopForegroundIfIdle() async {
    final fg = foregroundService;
    if (fg == null) return;
    final hasActive = _tasks.any(
      (t) =>
          t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.queued,
    );
    if (!hasActive) {
      // Clear the throttle too, so a later download's first update is not
      // suppressed by a percentage left over from the previous one.
      _foregroundNotification = null;
      try {
        await fg.stopService();
      } catch (_) {}
    }
  }

  bool get _notificationsOn => settings?.settings.notificationsEnabled ?? true;

  /// Whether the user asked for downloads to start only on an
  /// unmetered network. Read per pump so a Settings change takes
  /// effect without rebuilding the provider (which would discard the
  /// live queue).
  bool _wifiOnlyFromSettings() => settings?.settings.wifiOnly ?? false;

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

  /// Cancels a queued, paused or running task. A canceled task can never resume.
  void cancel(String id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    switch (task.status) {
      case DownloadStatus.queued:
      case DownloadStatus.paused:
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

  /// Holds a task back without stopping the rest of the queue.
  ///
  /// A waiting task simply stops being a scheduler candidate. A running one
  /// cannot be suspended — dart:io exposes no way to signal a child process —
  /// so its process is stopped, its staging directory and `.part` file are
  /// kept, and it is re-queued as [DownloadStatus.paused]. Releasing it restarts
  /// yt-dlp, which continues from the partial because `--continue` is on by
  /// default and the same staging directory is reused.
  ///
  /// Returns false for a task that is not running or waiting.
  bool pauseTask(String id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return false;
    switch (task.status) {
      case DownloadStatus.queued:
        task.status = DownloadStatus.paused;
        notifyListeners();
        // A slot may have just freed up for a task further back in the queue.
        _pump();
        return true;
      case DownloadStatus.downloading:
        // Stopping the process unwinds _run, which leaves the staging
        // directory alone for a paused task and then sets the status here.
        _pausing.add(id);
        _processes[id]?.cancel();
        return true;
      case DownloadStatus.paused:
      case DownloadStatus.completed:
      case DownloadStatus.failed:
      case DownloadStatus.canceled:
        return false;
    }
  }

  /// Releases a paused task so the scheduler can start it again.
  ///
  /// Goes back to the *back* of the queue rather than to where it was before,
  /// since anything that was waiting behind it may since have started.
  bool resumeTask(String id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status != DownloadStatus.paused) return false;
    task.status = DownloadStatus.queued;
    notifyListeners();
    _pump();
    return true;
  }

  /// Releases every paused task. Wired to the app's global resume, so a
  /// "Paused" chip never leaves work held when the user says go.
  int resumeAllPaused() {
    final held = _tasks
        .where((t) => t.status == DownloadStatus.paused)
        .map((t) => t.id)
        .toList();
    for (final id in held) {
      _tasks.where((t) => t.id == id).firstOrNull?.status =
          DownloadStatus.queued;
    }
    if (held.isNotEmpty) {
      notifyListeners();
      _pump();
    }
    return held.length;
  }

  /// How many tasks are held back by [pauseTask].
  int get pausedCount =>
      _tasks.where((t) => t.status == DownloadStatus.paused).length;

  /// Re-enqueues a failed or canceled task with a fresh id, reusing its
  /// staging directory so yt-dlp continues the partial download.
  ///
  /// Completed tasks are refused: re-running a finished download is a new
  /// download, and silently offering it behind a retry icon would be a trap.
  DownloadTask? retry(DownloadTask task) {
    if (task.status != DownloadStatus.failed &&
        task.status != DownloadStatus.canceled) {
      return null;
    }
    _tasks.removeWhere((t) => t.id == task.id);
    final next = enqueue(
      video: task.video,
      format: task.format,
      options: task.options,
      // Preserved so a retried download repeats the command that failed
      // rather than silently picking up a changed default, and so a playlist
      // entry still lands in its playlist folder and still groups with its
      // siblings in the queue.
      extraArgs: task.extraArgs,
      outputTemplate: task.outputTemplate,
      prefs: task.prefs,
      youtube: task.youtube,
      stagingPath: task.stagingPath,
      playlistId: task.playlistId,
      playlistTitle: task.playlistTitle,
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
    // A paused task is safe to drop: its process is already stopped, so
    // nothing is left running behind the removal.
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
    _disposed = true;
    _persistDebounce?.cancel();
    for (final dl in _processes.values) {
      try {
        dl.cancel();
      } catch (_) {}
    }
    _processes.clear();
    for (final t in _tasks) {
      if (t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.paused ||
          t.status == DownloadStatus.downloading) {
        t.status = DownloadStatus.canceled;
      }
    }
    super.dispose();
  }
}
