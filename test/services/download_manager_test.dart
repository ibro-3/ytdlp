import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
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
  }) async {
    return _FakeProcess(lines: const ['[download] Destination: missing.mp4']);
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
}
