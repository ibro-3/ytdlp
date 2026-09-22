import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/download_record.dart';
import '../../core/models/download_task.dart';
import '../../core/models/video_info.dart';
import '../ytdlp/progress_parser.dart';
import '../ytdlp/ytdlp_service.dart';
import 'history_service.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.ytdlp,
    required this.history,
    required this.downloadsDir,
  });

  final YtdlpService ytdlp;
  final HistoryService history;
  final Future<Directory> Function() downloadsDir;

  final List<DownloadTask> _tasks = [];
  final Map<String, YtdlpProcess> _processes = {};

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  Future<void> enqueue({required VideoInfo video, required Format format}) async {
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      video: video,
      format: format,
      createdAt: DateTime.now(),
    );
    _tasks.insert(0, task);
    notifyListeners();
    unawaited(_run(task));
  }

  Future<void> _run(DownloadTask task) async {
    try {
      final dir = await downloadsDir();
      await dir.create(recursive: true);
      task.status = DownloadStatus.downloading;
      notifyListeners();

      final dl = await ytdlp.startDownload(
        url: task.video.webUrl,
        format: task.format,
        outputDir: dir.path,
        template: '%(title)s [%(id)s].%(ext)s',
      );
      _processes[task.id] = dl;

      String? lastDestination;
      await for (final line in dl.lines) {
        final dest = YtdlpProgressParser.parseDestination(line);
        if (dest != null) {
          lastDestination = dest;
          task.destinationPath = dest;
        }
        final merged = YtdlpProgressParser.parseMergedFile(line);
        if (merged != null) {
          lastDestination = merged;
          task.destinationPath = merged;
        }
        final prog = YtdlpProgressParser.parseProgress(line);
        if (prog != null && prog.progress != null) {
          task.progress = prog.progress!;
          task.speed = prog.speed;
          task.eta = prog.eta;
          notifyListeners();
        }
        final err = YtdlpProgressParser.parseError(line);
        if (err != null && task.error == null) {
          task.error = err;
        }
      }

      final code = await dl.exitCode;
      if (code == 0) {
        final path = lastDestination ?? await _resolveOutputFile(dir, task);
        if (path != null && await File(path).exists()) {
          task.filePath = path;
          task.progress = 1;
          task.speed = null;
          task.eta = null;
          task.status = DownloadStatus.completed;
          final size = await File(path).length();
          await history.add(DownloadRecord(
            id: task.id,
            videoId: task.video.id,
            title: task.video.title,
            author: task.video.author,
            thumbnail: task.video.thumbnail,
            filePath: path,
            size: size,
            createdAt: task.createdAt,
          ));
        } else {
          task.status = DownloadStatus.failed;
          task.error ??= 'Download finished but the output file could not be found.';
        }
      } else if (task.status != DownloadStatus.canceled) {
        task.status = DownloadStatus.failed;
        task.error ??= 'yt-dlp exited with code $code';
      }
    } catch (e) {
      if (task.status != DownloadStatus.canceled) {
        task.status = DownloadStatus.failed;
        task.error = e.toString();
      }
    } finally {
      _processes.remove(task.id);
      if (task.status != DownloadStatus.completed) {
        _cleanupPartial(task);
      }
      notifyListeners();
    }
  }

  Future<String?> _resolveOutputFile(Directory dir, DownloadTask task) async {
    try {
      final id = task.video.id;
      final candidates = <FileSystemEntity>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (entity.path.contains('[$id]')) candidates.add(entity);
      }
      if (candidates.isEmpty) return null;
      candidates.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return (candidates.first as File).path;
    } catch (_) {
      return null;
    }
  }

  void _cleanupPartial(DownloadTask task) {
    final dest = task.destinationPath;
    if (dest == null) return;
    for (final p in [dest, '$dest.part']) {
      try {
        final f = File(p);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  void cancel(String id) {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued) {
      task.status = DownloadStatus.canceled;
      _processes[id]?.cancel();
      notifyListeners();
    }
  }

  void retry(DownloadTask task) {
    _tasks.remove(task);
    notifyListeners();
    unawaited(enqueue(video: task.video, format: task.format));
  }

  void dismiss(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  Future<void> openTask(DownloadTask task) async {
    final path = task.filePath;
    if (path == null) return;
    await OpenFilex.open(path);
  }

  Future<void> shareTask(DownloadTask task) async {
    final path = task.filePath;
    if (path == null) return;
    await SharePlus.instance.share(ShareParams(
      title: task.video.title,
      files: [XFile(path)],
    ));
  }

  Future<void> deleteTask(DownloadTask task) async {
    try {
      final f = File(task.filePath ?? '');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    await history.remove(task.id);
    _tasks.removeWhere((t) => t.id == task.id);
    notifyListeners();
  }
}
