import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
import 'package:ytdlp/services/downloads/queue_store.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

/// A fake yt-dlp process for deterministic manager tests.
class _FakeProcess implements DownloadProcess {
  _FakeProcess({this._lines = const [], Future<int>? exitCode})
    : _exitCode = exitCode ?? Future<int>.value(0);

  final List<String> _lines;
  final Future<int> _exitCode;
  int cancelCount = 0;

  @override
  Stream<String> get lines async* {
    for (final line in _lines) {
      yield line;
    }
  }

  @override
  Future<int> get exitCode => _exitCode;

  @override
  void cancel() => cancelCount++;
}

class _EngineCall {
  _EngineCall(this.url, this.outputDir, this.process);
  final String url;
  final String outputDir;
  final _FakeProcess process;
}

/// Writes the expected output file into the staging dir so the manager can
/// validate and move it, mirroring what yt-dlp would do.
class _FakeEngine implements DownloadEngine {
  _FakeEngine({this.exitCode});

  final Future<int>? exitCode;
  final List<_EngineCall> calls = [];
  int started = 0;

  @override
  Future<_FakeProcess> startDownload({
    required String url,
    required Format format,
    required String outputDir,
    required String template,
    String? cookiesPath,
  }) async {
    started++;
    final file = File(p.join(outputDir, 'Title [abc123].mp4'));
    await file.parent.create(recursive: true);
    await file.writeAsString('video-bytes');
    final call = _EngineCall(
      url,
      outputDir,
      _FakeProcess(
        lines: ['[download] Destination: ${file.path}'],
        exitCode: exitCode ?? Future<int>.value(0),
      ),
    );
    calls.add(call);
    return call.process;
  }
}

/// Engine that never creates an output file (simulates a "0 exit, no file"
/// yt-dlp run).
class _NoFileEngine implements DownloadEngine {
  @override
  Future<DownloadProcess> startDownload({
    required String url,
    required Format format,
    required String outputDir,
    required String template,
    String? cookiesPath,
  }) async {
    return _FakeProcess(lines: const ['[download] Destination: missing.mp4']);
  }
}

/// Engine that writes a `.part` file and then fails, the way a dropped
/// connection looks: a partial download that should be resumable. The first
/// attempt fails immediately; later attempts hang until the test cancels them.
class _FailingAfterPartEngine implements DownloadEngine {
  final List<_EngineCall> calls = [];
  final Completer<int> _hang = Completer<int>();

  @override
  Future<DownloadProcess> startDownload({
    required String url,
    required Format format,
    required String outputDir,
    required String template,
    String? cookiesPath,
  }) async {
    final part = File(p.join(outputDir, 'Title [abc123].mp4.part'));
    await part.parent.create(recursive: true);
    await part.writeAsString('partial');
    final attempt = calls.length;
    final call = _EngineCall(
      url,
      outputDir,
      _FakeProcess(
        lines: ['[download] Destination: ${part.path}'],
        exitCode: attempt == 0 ? Future<int>.value(1) : _hang.future,
      ),
    );
    calls.add(call);
    return call.process;
  }
}

VideoInfo _video(String id) => VideoInfo(
  id: id,
  title: 'Title',
  webUrl: 'https://example.com/video?id=$id',
  videoFormats: const [
    Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
  ],
);

void main() {
  late Directory tempRoot;
  late HistoryService history;
  late Box<dynamic> historyBox;

  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('ytdlp-test-');
    tempRoot = dir;
    Hive.init(dir.path);
    historyBox = await Hive.openBox<dynamic>('history');
    history = HistoryService(historyBox);
  });

  tearDown(() async {
    await historyBox.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> waitUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('waitUntil timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  DownloadManager manager(DownloadEngine engine, {int maxConcurrency = 1}) {
    return DownloadManager(
      ytdlp: engine,
      history: history,
      downloadsDir: () async => tempRoot,
      maxConcurrency: maxConcurrency,
    );
  }

  group('DownloadManager scheduling', () {
    test(
      'runs at most maxConcurrency downloads, oldest queued first',
      () async {
        final engine = _FakeEngine();
        final m = manager(engine, maxConcurrency: 1);
        addTearDown(m.dispose);

        final a = m.enqueue(
          video: _video('a'),
          format: _video('a').videoFormats.first,
        );
        final b = m.enqueue(
          video: _video('b'),
          format: _video('b').videoFormats.first,
        );
        final c = m.enqueue(
          video: _video('c'),
          format: _video('c').videoFormats.first,
        );

        expect(a.status, DownloadStatus.downloading);
        expect(b.status, DownloadStatus.queued);
        expect(c.status, DownloadStatus.queued);
        // The first task has been picked up; the other two must still be
        // waiting for a free slot.
        await waitUntil(() => engine.started >= 1);
        expect(engine.started, 1);

        await waitUntil(
          () => m.tasks.every((t) => t.status == DownloadStatus.completed),
        );

        expect(engine.started, 3);
        expect(engine.calls.map((c) => c.url), [
          'https://example.com/video?id=a',
          'https://example.com/video?id=b',
          'https://example.com/video?id=c',
        ]);
        // Files land in the final Video/ folder and staging is cleaned up.
        expect(
          File(p.join(tempRoot.path, 'Video', 'Title [abc123].mp4'))
              .existsSync(),
          isTrue,
        );
        // A task flips to `completed` just before its `finally` block removes
        // staging, so wait for the directory to actually go away rather than
        // assuming the cleanup already ran when the status changed.
        await waitUntil(
          () =>
              !Directory(p.join(tempRoot.path, '.ytdlp-staging')).existsSync(),
        );
        expect(
          Directory(p.join(tempRoot.path, '.ytdlp-staging')).existsSync(),
          isFalse,
        );
      },
    );

    test('queued tasks cancel without ever starting a process', () async {
      final engine = _FakeEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final a = m.enqueue(
        video: _video('a'),
        format: _video('a').videoFormats.first,
      );
      final b = m.enqueue(
        video: _video('b'),
        format: _video('b').videoFormats.first,
      );

      m.cancel(b.id);

      await waitUntil(
        () =>
            a.status == DownloadStatus.completed &&
            b.status == DownloadStatus.canceled,
      );

      expect(b.status, DownloadStatus.canceled);
      expect(b.filePath, isNull);
      expect(engine.started, 1);
      expect(engine.calls.single.url, contains('id=a'));
    });

    test(
      'canceled running task kills its process and never completes',
      () async {
        final code = Completer<int>();
        final engine = _FakeEngine(exitCode: code.future);
        final m = manager(engine);
        addTearDown(m.dispose);

        final t = m.enqueue(
          video: _video('x'),
          format: _video('x').videoFormats.first,
        );
        await waitUntil(() => engine.started == 1);

        m.cancel(t.id);
        await waitUntil(() => t.status == DownloadStatus.canceled);

        expect(engine.calls.single.process.cancelCount, 1);
        expect(t.status, DownloadStatus.canceled);
        expect(t.filePath, isNull);
        // The task's process is gone from the manager's registry.
        expect(t.progress, 0);

        // Let the process "exit" so the manager's await chain unwinds cleanly.
        code.complete(143);
        await waitUntil(
          () => m.tasks.every(
            (x) =>
                x.status == DownloadStatus.canceled ||
                x.status == DownloadStatus.completed,
          ),
        );
      },
    );

    test('exit code 0 without an output file fails the task', () async {
      final engine = _NoFileEngine();
      final m = manager(engine);
      addTearDown(m.dispose);
      final t = m.enqueue(
        video: _video('nofile'),
        format: _video('nofile').videoFormats.first,
      );
      await waitUntil(() => t.status == DownloadStatus.failed);
      expect(t.error, contains('output file'));
    });

    test(
      'a failed task keeps its staging dir and retry resumes in it',
      () async {
        // First attempt fails after writing a .part file, like a dropped
        // connection would.
        final engine = _FailingAfterPartEngine();
        final m = manager(engine);
        addTearDown(m.dispose);

        final t = m.enqueue(
          video: _video('resume'),
          format: _video('resume').videoFormats.first,
        );
        await waitUntil(() => t.status == DownloadStatus.failed);
        final staging = t.stagingPath;
        expect(staging, isNotNull, reason: 'staging kept for resume');
        final part = File(p.join(staging!, 'Title [abc123].mp4.part'));
        expect(part.existsSync(), isTrue, reason: '.part survives the failure');

        // Retrying reuses the same directory so yt-dlp can continue.
        final retried = m.retry(t)!;
        expect(retried.id, isNot(t.id));
        expect(retried.stagingPath, staging, reason: 'seeded for resume');
        await waitUntil(() => engine.calls.length == 2);
        expect(engine.calls[1].outputDir, staging);

        // Dismissing the retried task reclaims the kept directory.
        m.cancel(retried.id);
        await waitUntil(() => retried.status == DownloadStatus.canceled);
        expect(m.dismiss(retried.id), isTrue);
        // Cancelling is synchronous but cleanup runs in the task's finally.
        await waitUntil(() => !Directory(staging).existsSync());
      },
    );
  });

  group('DownloadManager cleanup and ops', () {
    test('deleteTask removes the file and history entry', () async {
      final engine = _FakeEngine();
      final m = manager(engine);
      addTearDown(m.dispose);
      final t = m.enqueue(
        video: _video('del'),
        format: _video('del').videoFormats.first,
      );
      await waitUntil(() => t.status == DownloadStatus.completed);

      expect(await m.deleteTask(t), isTrue);
      expect(m.tasks.where((x) => x.id == t.id), isEmpty);
      expect(
        File(p.join(tempRoot.path, 'Video', 'Title [abc123].mp4')).existsSync(),
        isFalse,
      );
      expect(history.records, isEmpty);
    });

    test('retry starts a fresh task', () async {
      final engine = _NoFileEngine();
      final m = manager(engine);
      addTearDown(m.dispose);
      final t = m.enqueue(
        video: _video('r'),
        format: _video('r').videoFormats.first,
      );
      await waitUntil(() => t.status == DownloadStatus.failed);

      final retried = m.retry(t);
      expect(retried, isNotNull);
      expect(retried!.id, isNot(t.id));
      expect(m.tasks.where((x) => x.id == t.id), isEmpty);
    });

    test('dismiss rejects running tasks', () async {
      final code = Completer<int>();
      final engine = _FakeEngine(exitCode: code.future);
      final m = manager(engine);
      addTearDown(m.dispose);
      final t = m.enqueue(
        video: _video('d'),
        format: _video('d').videoFormats.first,
      );
      await waitUntil(() => engine.started == 1);

      expect(m.dismiss(t.id), isFalse);
      expect(m.tasks.where((x) => x.id == t.id), hasLength(1));
      code.complete(0);
      await waitUntil(
        () =>
            t.status == DownloadStatus.completed ||
            t.status == DownloadStatus.failed,
      );
    });

    test(
      'history failure keeps the download completed with a warning',
      () async {
        final engine = _FakeEngine();
        final m = manager(engine);
        addTearDown(m.dispose);
        // Break persistence: history.add will throw on the closed box.
        await historyBox.close();

        final t = m.enqueue(
          video: _video('nowarn'),
          format: _video('nowarn').videoFormats.first,
        );
        await waitUntil(
          () =>
              t.status == DownloadStatus.completed ||
              t.status == DownloadStatus.failed,
        );

        expect(t.status, DownloadStatus.completed);
        expect(t.filePath, isNotNull);
        expect(t.warning, isNotNull);
        expect(t.warning, contains('library'));
      },
    );
  });

  group('DownloadManager persistence', () {
    test(
      'restores an interrupted task as failed and keeps it resumable',
      () async {
        final store = QueueStore(historyBox);
        final live = Directory(
          p.join(tempRoot.path, '.ytdlp-staging', 'live-task'),
        )..createSync(recursive: true);
        File(p.join(live.path, 'Title [abc123].mp4.part'))
            .writeAsStringSync('part');
        final orphan = Directory(
          p.join(tempRoot.path, '.ytdlp-staging', 'orphan'),
        )..createSync(recursive: true);

        // A task that was mid-download when the process died, plus an orphan
        // staging directory no task refers to.
        final video = _video('abc123');
        final interrupted = DownloadTask(
          id: 'live-task',
          video: video,
          format: video.videoFormats.first,
          createdAt: DateTime(2026, 1, 1),
          stagingPath: live.path,
        )..status = DownloadStatus.downloading;
        await store.save([interrupted]);

        final engine = _FakeEngine();
        final m = DownloadManager(
          ytdlp: engine,
          history: history,
          downloadsDir: () async => tempRoot,
          queueStore: store,
        );
        addTearDown(m.dispose);

        await waitUntil(() => m.tasks.isNotEmpty && !orphan.existsSync());
        final restored = m.tasks.single;
        expect(restored.id, 'live-task');
        expect(restored.status, DownloadStatus.failed);
        expect(restored.error, contains('Interrupted'));
        expect(restored.stagingPath, live.path);
        expect(live.existsSync(), isTrue, reason: 'partial download preserved');
        expect(engine.started, 0, reason: 'restored tasks do not auto-start');
      },
    );

    test('a persisted task round-trips its fields', () async {
      final store = QueueStore(historyBox);
      final video = _video('abc123');
      final task =
          DownloadTask(
              id: 'snap',
              video: video,
              format: const Format(
                kind: FormatKind.audio,
                label: 'M4A · Best audio',
                selector: 'ba[ext=m4a]/ba',
                filesize: 1234,
              ),
              createdAt: DateTime(2026, 5, 4, 3, 2, 1),
            )
            ..status = DownloadStatus.failed
            ..error = 'boom'
            ..progress = 0.42;
      await store.save([task]);

      final back = store.load().single;
      expect(back.id, 'snap');
      expect(back.video.title, video.title);
      expect(back.video.webUrl, video.webUrl);
      expect(back.format.kind, FormatKind.audio);
      expect(back.format.selector, 'ba[ext=m4a]/ba');
      expect(back.format.filesize, 1234);
      expect(back.status, DownloadStatus.failed);
      expect(back.error, 'boom');
      expect(back.progress, closeTo(0.42, 0.0001));
      expect(back.createdAt, task.createdAt);
    });

    test('a corrupt record does not break loading', () async {
      final store = QueueStore(historyBox);
      await historyBox.put('queue', [
        'not a map',
        {'id': 'ok'},
        {'id': ''},
      ]);
      final loaded = store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'ok');
    });
  });
}
