import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/download_options.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/models/yt_prefs.dart';
import 'package:ytdlp/core/models/youtube_prefs.dart';
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
import 'package:ytdlp/services/downloads/download_layout.dart';
import 'package:ytdlp/services/downloads/network_probe.dart';
import 'package:ytdlp/services/downloads/queue_store.dart';
import 'package:ytdlp/services/settings/settings_service.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

/// A fake yt-dlp process for deterministic manager tests.
class _FakeProcess implements DownloadProcess {
  _FakeProcess({
    this._lines = const [],
    Future<int>? exitCode,
    bool exitOnCancel = false,
  }) : _exitCode = exitCode ?? Future<int>.value(0) {
    if (exitOnCancel) _killed = Completer<int>();
  }

  final List<String> _lines;
  final Future<int> _exitCode;

  /// Completed with a non-zero code when [cancel] is called, so a run loop that
  /// is blocked on [exitCode] unwinds the way a real killed process would.
  Completer<int>? _killed;
  int cancelCount = 0;

  @override
  Stream<String> get lines async* {
    for (final line in _lines) {
      yield line;
    }
  }

  @override
  Future<int> get exitCode => _killed?.future ?? _exitCode;

  /// Completes the exit with [code] for a test that needs the process to finish
  /// on demand rather than on cancel.
  void finish(int code) {
    if (!(_killed?.isCompleted ?? true)) _killed!.complete(code);
  }

  @override
  void cancel() {
    cancelCount++;
    finish(1);
  }
}

/// Every download writes the *same* output filename, so two concurrent
/// completions collide on the final destination.
class _SameNameEngine implements DownloadEngine {
  int started = 0;

  @override
  Future<DownloadProcess> startDownload({
    required String url,
    required Format format,
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    String? cookieBrowser,
    String cookieBrowserProfile = '',
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
    YoutubePrefs youtube = const YoutubePrefs(),
  }) async {
    started++;
    // The id rides in the query string, matching `_video`.
    final name = Uri.parse(url).queryParameters['id'];
    final file = File(p.join(outputDir, 'Title [abc123].mp4'));
    await file.parent.create(recursive: true);
    await file.writeAsString('video-$name');
    return _FakeProcess(
      lines: ['[download] Destination: ${file.path}'],
      exitCode: Future<int>.value(0),
    );
  }
}

/// Emits progress lines steadily for [duration] and then finishes successfully.
///
/// The lines have to be *spaced out in time*, not just numerous: a burst of
/// them all arriving in one microtask would still let a debounce timer fire
/// afterwards, which is exactly what a real download does not do.
class _PacedProcess implements DownloadProcess {
  _PacedProcess(this._exit, this.period, this.lines);

  final Future<int> _exit;
  final Duration period;
  final List<String> lines;

  @override
  Stream<String> get lines async* {
    for (final line in lines) {
      await Future<void>.delayed(period);
      yield line;
    }
  }

  @override
  Future<int> get exitCode => _exit;

  @override
  void cancel() {}
}

class _PacedProgressEngine implements DownloadEngine {
  final Completer<int> _exit = Completer<int>();
  int started = 0;

  /// Long enough to outlive several throttle windows.
  Duration duration = const Duration(milliseconds: 900);

  @override
  Future<DownloadProcess> startDownload({
    required String url,
    required Format format,
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    String? cookieBrowser,
    String cookieBrowserProfile = '',
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
    YoutubePrefs youtube = const YoutubePrefs(),
  }) async {
    started++;
    final file = File(p.join(outputDir, 'Title [abc123].mp4'));
    await file.parent.create(recursive: true);
    await file.writeAsString('video-bytes');
    // 10ms apart: well inside any plausible debounce interval, so a debounce
    // that restarts per line would be reset ~90 times over this run.
    return _PacedProcess(_exit.future, const Duration(milliseconds: 10), [
      '[download] Destination: ${file.path}',
      for (var i = 0; i < duration.inMilliseconds ~/ 10; i++)
        '[download]  50.0% of 10.00MiB at 1.00MiB/s ETA 00:05',
    ]);
  }
}

/// A process whose `lines` stream keeps emitting after the consumer has walked
/// away, which is what a cancel does: the run loop breaks out of the `await for`
/// and nothing is left listening.
class _EndlessProcess implements DownloadProcess {
  final Completer<int> _killed = Completer<int>();
  int cancelCount = 0;

  /// Emitted forever, so the manager's line loop only ever ends by being
  /// abandoned — which is exactly what a cancel does.
  static Stream<String> _endless() async* {
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield '[download]  10.0% of 10MiB at 1.00MiB/s ETA 00:09';
    }
  }

  @override
  Stream<String> get lines => _endless();

  @override
  Future<int> get exitCode => _killed.future;

  @override
  void cancel() {
    cancelCount++;
    if (!_killed.isCompleted) _killed.complete(143);
  }
}

/// Hands back one specific process, so a test can observe it directly.
class _FixedProcessEngine implements DownloadEngine {
  _FixedProcessEngine(this.process);

  final DownloadProcess process;
  int started = 0;

  @override
  Future<DownloadProcess> startDownload({
    required String url,
    required Format format,
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    String? cookieBrowser,
    String cookieBrowserProfile = '',
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
    YoutubePrefs youtube = const YoutubePrefs(),
  }) async {
    started++;
    return process;
  }
}

class _EngineCall {
  _EngineCall(this.url, this.outputDir, this.process);
  final String url;
  final String outputDir;
  final _FakeProcess process;
}

/// Records the extra arguments the manager hands the engine, and produces a
/// valid file so the task completes.
class _RecordingArgsEngine extends _FakeEngine {
  _RecordingArgsEngine({super.exitCode});

  List<String> extraArgs = const [];
  String template = '';
  YtPrefs prefs = const YtPrefs();
  YoutubePrefs youtube = const YoutubePrefs();
  String? archivePath;

  @override
  Future<_FakeProcess> startDownload({
    required String url,
    required Format format,
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    String? cookieBrowser,
    String cookieBrowserProfile = '',
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
    YoutubePrefs youtube = const YoutubePrefs(),
  }) {
    this.extraArgs = extraArgs;
    this.template = template;
    this.prefs = prefs;
    this.youtube = youtube;
    this.archivePath = archivePath;
    return super.startDownload(
      url: url,
      format: format,
      options: options,
      outputDir: outputDir,
      template: template,
      cookiesPath: cookiesPath,
      extraArgs: extraArgs,
      prefs: prefs,
      archivePath: archivePath,
      youtube: youtube,
    );
  }
}

/// Writes the expected output file into the staging dir so the manager can
/// validate and move it, mirroring what yt-dlp would do.
///
/// With [sidecars] it also writes subtitle/thumbnail/partial files, with the
/// sidecars newer than the media file (mirroring yt-dlp writing subs first
/// and thumbnails last). With [destinationIsSidecar] the reported
/// `Destination:` line points at the subtitle, the trap the real CLI falls
/// into when subtitles are written before the media.
class _FakeEngine implements DownloadEngine {
  _FakeEngine({
    this.exitCode,
    this.sidecars = false,
    this.destinationIsSidecar = false,
    this.exitOnCancel = false,
  });

  final Future<int>? exitCode;
  final bool sidecars;
  final bool destinationIsSidecar;

  /// Make cancelling actually end the process.
  ///
  /// Needed by anything that stops a *running* download — cancel or hold —
  /// because [exitCode] is then awaited and must resolve for the run loop to
  /// finish and free its slot.
  final bool exitOnCancel;
  final List<_EngineCall> calls = [];
  int started = 0;

  @override
  Future<_FakeProcess> startDownload({
    required String url,
    required Format format,
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    String? cookieBrowser,
    String cookieBrowserProfile = '',
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
    YoutubePrefs youtube = const YoutubePrefs(),
  }) async {
    started++;
    final file = File(p.join(outputDir, 'Title [abc123].mp4'));
    await file.parent.create(recursive: true);
    await file.writeAsString('video-bytes');
    final lines = <String>[];
    String? subPath;
    if (sidecars) {
      // Written after the media file so they are NEWER — the old "newest
      // file matching [id]" heuristic would have picked one of these.
      subPath = p.join(outputDir, 'Title [abc123].en.srt');
      await File(subPath)
          .writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHi\n');
      final jpg = File(p.join(outputDir, 'Title [abc123].jpg'));
      await jpg.writeAsString('thumb');
      await File(p.join(outputDir, 'Title [abc123].mp4.part'))
          .writeAsString('stale partial');
    }
    if (destinationIsSidecar && subPath != null) {
      lines.add('[download] Destination: $subPath');
    } else {
      lines.add('[download] Destination: ${file.path}');
    }
    final call = _EngineCall(
      url,
      outputDir,
      _FakeProcess(
        lines: lines,
        exitCode: exitCode ?? Future<int>.value(0),
        exitOnCancel: exitOnCancel,
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
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    String? cookieBrowser,
    String cookieBrowserProfile = '',
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
    YoutubePrefs youtube = const YoutubePrefs(),
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
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    String? cookieBrowser,
    String cookieBrowserProfile = '',
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
    YoutubePrefs youtube = const YoutubePrefs(),
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

/// A [NetworkProbe] whose answer the test controls, so the gate can
/// be exercised without the platform channel.
class _FakeProbe implements NetworkProbe {
  _FakeProbe({required this.allowed});

  bool allowed;
  int refreshCalls = 0;

  @override
  bool mayStart({required bool wifiOnly}) {
    if (!wifiOnly) return true;
    return allowed;
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }
}

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

    test('a canceled download waits for its process to actually exit', () async {
      // The regression this guards: cancellation returned from the run loop
      // without awaiting the exit status, and the `finally` then dropped the
      // only handle on the child. A real yt-dlp handles SIGTERM by finishing the
      // fragment it is on, and its ffmpeg children never see the signal at all,
      // so the process outlived the task and could keep writing into a staging
      // directory the UI was already free to delete.
      final process = _EndlessProcess();
      final engine = _FixedProcessEngine(process);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final t = m.enqueue(
        video: _video('x'),
        format: _video('x').videoFormats.first,
      );
      // Wait for the run loop to register the process, not merely to have
      // spawned it: `cancel` only reaches the child through that registry.
      await waitUntil(() => t.status == DownloadStatus.downloading);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      m.cancel(t.id);

      // The signal reached the child exactly once.
      await waitUntil(() => process.cancelCount == 1);
      // And the run loop finished unwinding, having waited for that child to
      // exit rather than dropping its handle.
      await waitUntil(() => t.status == DownloadStatus.canceled);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(t.status, DownloadStatus.canceled);
      expect(t.filePath, isNull);
      expect(process.cancelCount, 1, reason: 'not signalled twice');
    });

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

  group('DownloadManager queue control', () {
    test('pausing holds the queue and resuming releases it', () async {
      // maxConcurrency 1 so exactly one task is in flight and two wait.
      final engine = _FakeEngine(
        exitCode: Completer<int>().future, // held open
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.pause();
      expect(m.isPaused, isTrue);

      for (final id in ['a', 'b', 'c']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      // Nothing starts while paused, not even the first task.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engine.started, 0);
      expect(m.queuedCount, 3);

      m.resume();
      await waitUntil(() => engine.started == 1);
      expect(m.isPaused, isFalse);
      // Still serial, so the rest wait.
      expect(engine.started, 1);
    });

    test('pause leaves a running download alone', () async {
      // Pausing must not throw away a partial the user paid bandwidth for.
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(() => engine.started == 1);

      m.pause();
      m.enqueue(video: _video('b'), format: _video('b').videoFormats.first);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engine.started, 1, reason: 'the running task is unaffected');
      expect(
        m.tasks.firstWhere((t) => t.video.id == 'a').status,
        DownloadStatus.downloading,
      );
    });

    test('togglePause flips the state', () {
      final m = manager(_FakeEngine());
      addTearDown(m.dispose);
      expect(m.isPaused, isFalse);
      m.togglePause();
      expect(m.isPaused, isTrue);
      m.togglePause();
      expect(m.isPaused, isFalse);
    });

    test('raising concurrency starts waiting tasks', () async {
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      m.enqueue(video: _video('b'), format: _video('b').videoFormats.first);
      m.enqueue(video: _video('c'), format: _video('c').videoFormats.first);
      await waitUntil(() => engine.started == 1);

      // Raising the live limit lets more start without rebuilding the manager,
      // so the existing queue survives the settings change.
      m.maxConcurrency = 3;
      await waitUntil(() => engine.started == 3);
      expect(m.maxConcurrency, 3);
    });

    test(
      'lowering concurrency does not interrupt a running download',
      () async {
        final engine = _FakeEngine(exitCode: Completer<int>().future);
        final m = manager(engine, maxConcurrency: 3);
        addTearDown(m.dispose);

        for (final id in ['a', 'b', 'c']) {
          m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
        }
        await waitUntil(() => engine.started == 3);

        m.maxConcurrency = 1;
        expect(
          m.tasks.where((t) => t.status == DownloadStatus.downloading).length,
          3,
          reason: 'running work is never killed by a settings change',
        );
      },
    );

    test('concurrency is clamped to a sane range', () {
      final m = manager(_FakeEngine());
      addTearDown(m.dispose);
      m.maxConcurrency = 0;
      expect(m.maxConcurrency, 1);
      m.maxConcurrency = 99;
      expect(m.maxConcurrency, 8);
    });

    test(
      'cancelAll cancels queued and running, leaving finished alone',
      () async {
        final engine = _FakeEngine();
        final m = manager(engine, maxConcurrency: 1);
        addTearDown(m.dispose);

        m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
        await waitUntil(
          () => m.tasks.every((t) => t.status == DownloadStatus.completed),
        );
        expect(m.completedCount, 1);

        m.enqueue(video: _video('b'), format: _video('b').videoFormats.first);
        m.enqueue(video: _video('c'), format: _video('c').videoFormats.first);
        expect(m.cancelAll(), greaterThanOrEqualTo(2));
        await waitUntil(
          () => m.tasks.every(
            (t) =>
                t.status == DownloadStatus.canceled ||
                t.status == DownloadStatus.completed,
          ),
        );
        // The completed one is untouched.
        expect(m.completedCount, 1);
      },
    );

    test('clearFinished removes finished tasks and reclaims staging', () async {
      final engine = _FakeEngine(exitCode: Future<int>.value(1));
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      m.enqueue(video: _video('b'), format: _video('b').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.failed),
      );
      expect(m.failedCount, 2);
      expect(m.finishedCount, 2);

      final staging = m.tasks.map((t) => t.stagingPath).whereType<String>();
      expect(staging, isNotEmpty);

      expect(m.clearFinished(), 2);
      expect(m.tasks, isEmpty);
      // The kept-for-resume directories are reclaimed too, so a long-lived
      // queue cannot accumulate them. The deletion is scheduled rather than
      // awaited by clearFinished, hence the wait.
      await waitUntil(
        () => staging.every((path) => !Directory(path).existsSync()),
      );
    });

    test('clearFinished leaves queued and running work', () async {
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      m.enqueue(video: _video('b'), format: _video('b').videoFormats.first);
      await waitUntil(() => engine.started == 1);

      expect(m.clearFinished(), 0);
      expect(m.tasks, hasLength(2));
    });

    test('reorder moves a waiting task within the queue', () async {
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      // With concurrency 1 the first runs and the rest stay queued, which is
      // the only state where reordering is meaningful.
      for (final id in ['a', 'b', 'c']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      await waitUntil(() => engine.started == 1);

      final b = m.tasks.firstWhere((t) => t.video.id == 'b');
      // 'b' is ahead of 'c' in the queue, so a positive offset pushes it back.
      expect(m.reorder(b.id, 1), isTrue);

      expect(m.queueInStartOrder.map((t) => t.video.id), ['c', 'b']);
    });

    test('a staging path outside the staging root is never deleted', () async {
      // `stagingPath` comes back from the queue snapshot, so it is
      // corruption- or hand-edit-controlled. The resume path already refused a
      // path outside the staging root; the destructive ones did not, so
      // dismissing a card could recursively delete an arbitrary directory.
      final outside = Directory('${tempRoot.path}/precious')
        ..createSync(recursive: true);
      final canary = File('${outside.path}/keep.txt')..writeAsStringSync('keep');
      final video = _video('abc123');
      final task = DownloadTask(
        id: 'tampered',
        video: video,
        format: video.videoFormats.first,
        createdAt: DateTime(2026),
        stagingPath: outside.path,
      )..status = DownloadStatus.failed;

      final store = QueueStore(historyBox);
      await store.save([task]);
      final m = DownloadManager(
        ytdlp: _FakeEngine(),
        history: history,
        downloadsDir: () async => tempRoot,
        queueStore: store,
      );
      addTearDown(m.dispose);
      await waitUntil(() => m.tasks.isNotEmpty);

      expect(m.dismiss('tampered'), isTrue);

      expect(
        canary.existsSync(),
        isTrue,
        reason: 'a path outside .ytdlp-staging must not be deleted',
      );
      expect(outside.existsSync(), isTrue);
    });

    test('reorder leaves creation time alone', () async {
      // Reordering used to re-stamp `createdAt` to epoch microseconds. That
      // value is what reaches the library as the download's date, so a
      // reordered-then-completed task was filed under 1970.
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      for (final id in ['a', 'b', 'c']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      await waitUntil(() => engine.started == 1);

      final before = {
        for (final t in m.tasks) t.id: t.createdAt,
      };
      expect(m.reorder('b', 1), isTrue);
      expect(
        {for (final t in m.tasks) t.id: t.createdAt},
        before,
        reason: 'a move must not rewrite when the task was enqueued',
      );
    });

    test('reorder does not sink the queued block below finished cards', () async {
      final engine = _FakeEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      // One task finishes, then two more are queued behind it.
      m.enqueue(video: _video('done'), format: _video('done').videoFormats.first);
      await waitUntil(() => m.completedCount == 1);
      for (final id in ['b', 'c']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      await waitUntil(() => m.queuedCount == 2);

      // Re-stamping to epoch sent every waiting task below the finished one,
      // because the list is sorted by creation time for display.
      expect(m.reorder('c', 1), isTrue);
      final order = m.tasks.map((t) => t.video.id).toList();
      expect(order.last, 'c', reason: 'the moved task stays in the display list');
      expect(
        order.indexOf('b'),
        lessThan(order.indexOf('c')),
        reason: 'display order is by creation time, unaffected by the move',
      );
    });

    test('reorder refuses a running or unknown task', () async {
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(() => engine.started == 1);

      final running = m.tasks.single;
      expect(
        m.reorder(running.id, 1),
        isFalse,
        reason: 'it is already running',
      );
      expect(m.reorder('no-such-id', 1), isFalse);
      expect(m.reorder(running.id, 0), isFalse, reason: 'a no-op move');
    });

    test('reorder clamps at the end of the queue', () async {
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      for (final id in ['a', 'b']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      await waitUntil(() => engine.started == 1);

      final b = m.tasks.firstWhere((t) => t.video.id == 'b');
      // Pushing the last queued task further back is a no-op, not an error that
      // corrupts the order.
      expect(m.reorder(b.id, 5), isFalse);
      expect(m.queueInStartOrder.map((t) => t.video.id), ['b']);
    });
  });

  group('DownloadManager per-task hold', () {
    test(
      'a waiting task is held and the rest of the queue keeps going',
      () async {
        final engine = _FakeEngine(
          exitCode: Completer<int>().future,
          exitOnCancel: true,
        );
        final m = manager(engine, maxConcurrency: 1);
        addTearDown(m.dispose);

        for (final id in ['a', 'b', 'c']) {
          m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
        }
        await waitUntil(() => engine.started == 1);

        // 'a' runs; hold the next one waiting, so 'c' may take the freed slot.
        final b = m.tasks.firstWhere((t) => t.video.id == 'b');
        expect(m.pauseTask(b.id), isTrue);
        expect(b.status, DownloadStatus.paused);
        expect(m.pausedCount, 1);

        final a = m.tasks.firstWhere((t) => t.video.id == 'a');
        m.cancel(a.id);
        await waitUntil(() => engine.started == 2);
        expect(
          m.tasks.firstWhere((t) => t.video.id == 'c').status,
          DownloadStatus.downloading,
          reason: 'holding one task must not stall the rest of the queue',
        );
      },
    );

    test('a held task goes back to waiting on release, at the back', () async {
      final engine = _FakeEngine(
        exitCode: Completer<int>().future,
        exitOnCancel: true,
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      for (final id in ['a', 'b', 'c']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      await waitUntil(() => engine.started == 1);

      final c = m.tasks.firstWhere((t) => t.video.id == 'c');
      expect(m.pauseTask(c.id), isTrue);
      expect(m.resumeTask(c.id), isTrue);
      expect(c.status, DownloadStatus.queued);

      // Back of the queue, not where it was: 'b' was waiting behind it and may
      // have started, so restoring the old position would be a lie.
      expect(m.queueInStartOrder.map((t) => t.video.id), ['b', 'c']);
    });

    test('holding a running download stops it and keeps its staging', () async {
      // dart:io cannot suspend a child process, so this stops yt-dlp and relies
      // on --continue picking the .part back up on release.
      final engine = _FakeEngine(
        exitCode: Completer<int>().future,
        exitOnCancel: true,
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(() => engine.started == 1);
      final task = m.tasks.single;
      final staging = task.stagingPath!;
      await File(p.join(staging, 'Title [abc123].mp4.part'))
          .writeAsString('half');

      expect(m.pauseTask(task.id), isTrue);
      await waitUntil(() => task.status == DownloadStatus.paused);
      expect(engine.calls.first.process.cancelCount, 1);

      // The partial is what makes a release a resume rather than a restart, so
      // it must survive — and the task must not be reported as failed.
      expect(task.status, isNot(DownloadStatus.failed));
      expect(task.error, isNull);
      expect(
        File(p.join(staging, 'Title [abc123].mp4.part')).existsSync(),
        isTrue,
      );

      // Released, it reuses the same staging directory.
      expect(m.resumeTask(task.id), isTrue);
      await waitUntil(() => engine.started == 2);
      expect(engine.calls.last.outputDir, staging);
    });

    test('resumeAllPaused releases every held task', () async {
      final engine = _FakeEngine(
        exitCode: Completer<int>().future,
        exitOnCancel: true,
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      for (final id in ['a', 'b', 'c', 'd']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      await waitUntil(() => engine.started == 1);

      for (final id in ['b', 'c', 'd']) {
        m.pauseTask(m.tasks.firstWhere((t) => t.video.id == id).id);
      }
      expect(m.pausedCount, 3);

      expect(m.resumeAllPaused(), 3);
      expect(m.pausedCount, 0);
    });

    test('the queue-wide resume also releases held tasks', () async {
      // Otherwise a global "go" could leave a per-card hold stranded.
      final engine = _FakeEngine(
        exitCode: Completer<int>().future,
        exitOnCancel: true,
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      m.enqueue(video: _video('b'), format: _video('b').videoFormats.first);
      m.pauseTask(m.tasks.firstWhere((t) => t.video.id == 'b').id);
      expect(m.pausedCount, 1);

      m.pause();
      m.resume();
      expect(m.pausedCount, 0);
    });

    test('clearFinished keeps held work', () async {
      final engine = _FakeEngine(
        exitCode: Completer<int>().future,
        exitOnCancel: true,
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      m.enqueue(video: _video('b'), format: _video('a').videoFormats.first);
      m.pauseTask(m.tasks.firstWhere((t) => t.video.id == 'b').id);

      expect(m.clearFinished(), 0, reason: 'a held task still has work to do');
      expect(m.tasks, hasLength(2));
    });

    test('cancelAll and cancel take a held task', () async {
      final engine = _FakeEngine(
        exitCode: Completer<int>().future,
        exitOnCancel: true,
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      m.enqueue(video: _video('b'), format: _video('a').videoFormats.first);
      m.pauseTask(m.tasks.firstWhere((t) => t.video.id == 'b').id);
      m.cancelAll();

      await waitUntil(
        () => m.tasks.every(
          (t) =>
              t.status == DownloadStatus.canceled ||
              t.status == DownloadStatus.completed,
        ),
      );
      expect(m.pausedCount, 0);
    });

    test('pausing refuses a task that is not active', () async {
      final m = manager(_FakeEngine(exitCode: Future<int>.value(1)));
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.failed),
      );
      final failed = m.tasks.single;
      expect(m.pauseTask(failed.id), isFalse);
      expect(m.resumeTask(failed.id), isFalse);
      expect(m.pauseTask('no-such-id'), isFalse);
    });

    test(
      'retry is offered for a canceled download but not a finished one',
      () async {
        final engine = _FakeEngine(
          exitCode: Completer<int>().future,
          exitOnCancel: true,
        );
        final m = manager(engine, maxConcurrency: 1);
        addTearDown(m.dispose);

        m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
        await waitUntil(() => engine.started == 1);
        final canceled = m.tasks.single;
        final staging = canceled.stagingPath!;
        m.cancel(canceled.id);
        await waitUntil(() => canceled.status == DownloadStatus.canceled);

        // Cancel keeps the partial, so this continues rather than restarting.
        final retried = m.retry(canceled);
        expect(retried, isNotNull);
        expect(
          retried!.status,
          anyOf(DownloadStatus.queued, DownloadStatus.downloading),
        );
        expect(
          engine.calls.last.outputDir,
          staging,
          reason: 'a retry must reuse the staging directory to continue',
        );

        m.cancel(retried.id);
        await waitUntil(() => retried.status == DownloadStatus.canceled);
        m.pauseTask(retried.id);
        expect(m.pauseTask(retried.id), isFalse, reason: 'canceled twice');

        // A completed download is refused: re-running it is a new download, and
        // offering it behind a retry icon would be a trap.
        final other = _FakeEngine();
        final done = manager(other);
        addTearDown(done.dispose);
        done.enqueue(
          video: _video('z'),
          format: _video('z').videoFormats.first,
        );
        await waitUntil(
          () => done.tasks.every((t) => t.status == DownloadStatus.completed),
        );
        expect(done.retry(done.tasks.single), isNull);
      },
    );
  });

  group('DownloadManager output template', () {
    /// A settings service backed by a real box, so the manager reads the
    /// user's template and extra-args field the way it would in the app.
    Future<(SettingsService, Box<dynamic>)> settingsWith(
      AppSettings settings,
    ) async {
      final box = await Hive.openBox<dynamic>(
        'tpl-${DateTime.now().microsecondsSinceEpoch}',
      );
      final service = SettingsService(box);
      await service.update(settings);
      return (service, box);
    }

    test('youtube prefs reach the engine and default from Settings', () async {
      final engine = _RecordingArgsEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(
          youtube: YoutubePrefs(extraClients: [YoutubeClient.ios]),
        ),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      expect(engine.youtube.extraClients, [YoutubeClient.ios]);
      // Captured on the task, so a retry repeats the same command.
      expect(m.tasks.single.youtube.extraClients, [YoutubeClient.ios]);
    });

    test('a custom template names the finished file', () async {
      final engine = _FakeEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(outputTemplate: '%(uploader)s - %(title)s.%(ext)s'),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      // The engine writes to whatever path it is given, so the real assertion
      // is that the template reached it and the file moved into Video/.
      expect(
        engine.calls.single.outputDir,
        startsWith(p.join(tempRoot.path, '.ytdlp-staging')),
      );
      expect(
        Directory(p.join(tempRoot.path, 'Video')).listSync(),
        isNotEmpty,
        reason: 'the custom-named file still lands in the Video area',
      );
    });

    test('a template without an id still resolves its finished file', () async {
      // The old hard-coded check looked for '[<id>]' in the name, which a
      // user template may not contain. This is the regression that would make
      // every such download report "output file not found".
      final engine = _FakeEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(outputTemplate: '%(title)s.%(ext)s'),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      expect(m.tasks.single.status, DownloadStatus.completed);
      expect(m.tasks.single.filePath, isNotNull);
      expect(m.tasks.single.error, isNull);
    });

    test('stripPlaylistPrefix only removes a leading playlist segment', () {
      // The staging directory must stay flat, or _findFinalFile — which scans
      // only its top level — cannot see the file yt-dlp wrote.
      expect(
        stripPlaylistPrefix('%(playlist_title)s/%(title)s.%(ext)s'),
        '%(title)s.%(ext)s',
      );
      expect(
        stripPlaylistPrefix(
          '%(playlist_title)s/%(playlist_index)s-%(title)s.%(ext)s',
        ),
        '%(playlist_index)s-%(title)s.%(ext)s',
      );
      // A slash that is not a playlist field is left alone: a title can
      // legitimately contain one.
      expect(
        stripPlaylistPrefix('%(uploader)s/%(title)s.%(ext)s'),
        '%(uploader)s/%(title)s.%(ext)s',
      );
      expect(stripPlaylistPrefix('%(title)s.%(ext)s'), '%(title)s.%(ext)s');
    });

    test('a playlist prefix is stripped from the staging template', () async {
      // Otherwise yt-dlp writes into a staging subdirectory and the manager,
      // which scans the top level, cannot find the file.
      final engine = _FakeEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(
          outputTemplate: '%(playlist_title)s/%(title)s.%(ext)s',
        ),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );
      expect(m.tasks.single.status, DownloadStatus.completed);
    });

    test('extra args are passed through to the engine', () async {
      final engine = _RecordingArgsEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(extraArgs: '--concurrent-fragments 4'),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      expect(engine.extraArgs, ['--concurrent-fragments', '4']);
    });

    test('yt prefs reach the engine and default from Settings', () async {
      final engine = _RecordingArgsEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(
          ytPrefs: YtPrefs(
            concurrentFragments: 3,
            limitRate: '2M',
            extractAudio: true,
            audioFormat: 'opus',
          ),
        ),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      expect(engine.prefs.concurrentFragments, 3);
      expect(engine.prefs.audioFormat, 'opus');
      // Captured on the task as well, so a retry repeats the same command.
      expect(m.tasks.single.prefs.concurrentFragments, 3);
    });

    test('the archive path is optional and never breaks a download', () async {
      // path_provider has no implementation in a plain unit test, so the
      // manager cannot resolve the support dir. The download must still
      // succeed with the archive simply omitted — the flag is an optimisation,
      // not a requirement.
      final engine = _RecordingArgsEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueue(
        video: _video('a'),
        format: _video('a').videoFormats.first,
        prefs: const YtPrefs(downloadArchive: true),
      );
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );
      expect(
        m.tasks.single.status,
        DownloadStatus.completed,
        reason: 'an unresolvable archive path must not fail the download',
      );
    });

    test('two archive-using tasks do not run at the same time', () async {
      // yt-dlp loads the ledger when a download starts and rewrites the whole
      // file when it finishes, so two tasks sharing one path lose whichever set
      // of entries is written first — "skip what I already have" degraded to a
      // race under the desktop default concurrency of two.
      final engine = _FakeEngine(exitOnCancel: true);
      final m = manager(engine, maxConcurrency: 2);
      addTearDown(m.dispose);

      for (final id in ['a', 'b']) {
        m.enqueue(
          video: _video(id),
          format: _video(id).videoFormats.first,
          prefs: const YtPrefs(downloadArchive: true),
        );
      }
      await waitUntil(() => engine.started == 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        engine.started,
        1,
        reason: 'the second archive-using task waits its turn',
      );

      engine.calls.first.process.finish(0);
      await waitUntil(() => engine.started == 2);
      expect(
        m.tasks.where((t) => t.status == DownloadStatus.downloading),
        hasLength(1),
      );
    });

    test('a per-task prefs override beats the Settings default', () async {
      final engine = _RecordingArgsEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(ytPrefs: YtPrefs(concurrentFragments: 3)),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(
        video: _video('a'),
        format: _video('a').videoFormats.first,
        prefs: const YtPrefs(concurrentFragments: 1),
      );
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );
      expect(engine.prefs.concurrentFragments, 1);
    });

    test('a per-task template override beats the Settings default', () async {
      final engine = _RecordingArgsEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(outputTemplate: '%(title)s.%(ext)s'),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(
        video: _video('a'),
        format: _video('a').videoFormats.first,
        outputTemplate: '%(uploader)s/%(title)s.%(ext)s',
      );
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      expect(engine.template, '%(uploader)s/%(title)s.%(ext)s');
      expect(
        m.tasks.single.status,
        DownloadStatus.completed,
        reason: 'the override must also drive the identity check',
      );
    });

    test('a retry repeats the original template and args', () async {
      // A retry that silently picked up a changed default would no longer
      // resume the .part file it is meant to continue.
      final engine = _RecordingArgsEngine(exitCode: Future<int>.value(1));
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final task = m.enqueue(
        video: _video('a'),
        format: _video('a').videoFormats.first,
        extraArgs: const ['--concurrent-fragments', '4'],
        outputTemplate: '%(title)s.%(ext)s',
      );
      await waitUntil(() => task.status == DownloadStatus.failed);

      final retried = m.retry(task);
      expect(retried, isNotNull);
      expect(retried!.extraArgs, ['--concurrent-fragments', '4']);
      expect(retried.outputTemplate, '%(title)s.%(ext)s');
      await waitUntil(() => retried.status != DownloadStatus.queued);
    });

    test('unparseable extra args are ignored rather than failing', () async {
      final engine = _RecordingArgsEngine();
      final (settingsService, box) = await settingsWith(
        const AppSettings(extraArgs: "--a 'unterminated"),
      );
      addTearDown(box.deleteFromDisk);
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settingsService,
      );
      addTearDown(m.dispose);

      m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      expect(engine.extraArgs, isEmpty);
      expect(
        m.tasks.single.status,
        DownloadStatus.completed,
        reason: 'a malformed field must not break the download',
      );
    });
  });

  group('DownloadManager playlists', () {
    PlaylistInfo playlist(
      List<VideoInfo> entries, {
      String title = 'Road Trip',
    }) => PlaylistInfo(
      id: 'PL1',
      title: title,
      webUrl: 'https://example.com/playlist?list=PL1',
      entries: entries,
    );

    VideoInfo entry(String id) => VideoInfo(
      id: 'abc123',
      title: 'Title $id',
      webUrl: 'https://example.com/video?id=$id',
    );

    test('enqueuePlaylist creates one task per selected entry', () async {
      final engine = _FakeEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final chosen = [entry('a'), entry('b'), entry('c')];
      final created = m.enqueuePlaylist(
        playlist: playlist(chosen),
        selected: chosen,
        format: _video('a').videoFormats.first,
      );

      expect(created, hasLength(3));
      // Every task carries the same group id so the queue can group them.
      expect(created.map((t) => t.playlistId).toSet(), {'PL1'});
      expect(created.map((t) => t.playlistTitle).toSet(), {'Road Trip'});

      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );
    });

    test('tasks created in one batch get unique ids', () async {
      final engine = _FakeEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final chosen = [entry('a'), entry('b'), entry('c')];
      final created = m.enqueuePlaylist(
        playlist: playlist(chosen),
        selected: chosen,
        format: _video('a').videoFormats.first,
      );

      // microsecondsSinceEpoch repeats within a tight loop; ids key the
      // process map and the notification id, so they must not collide.
      expect(created.map((t) => t.id).toSet(), hasLength(3));

      // Let the pipeline drain before the manager is disposed.
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );
    });

    test('an empty selection enqueues nothing', () async {
      final engine = _FakeEngine();
      final m = manager(engine);
      addTearDown(m.dispose);

      expect(
        m.enqueuePlaylist(
          playlist: playlist(const []),
          selected: const [],
          format: _video('a').videoFormats.first,
        ),
        isEmpty,
      );
      expect(m.tasks, isEmpty);
    });

    test('entries land in a folder named after the playlist', () async {
      final engine = _FakeEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final chosen = [entry('a'), entry('b')];
      m.enqueuePlaylist(
        playlist: playlist(chosen),
        selected: chosen,
        format: _video('a').videoFormats.first,
      );

      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );

      // Grouped under Video/Road Trip/, not loose in Video/.
      expect(
        Directory(p.join(tempRoot.path, 'Video', 'Road Trip')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(tempRoot.path, 'Video', 'Road Trip', 'Title [abc123].mp4'))
            .existsSync(),
        isTrue,
      );
    });

    test(
      'a playlist title with separators is sanitized into the folder',
      () async {
        final engine = _FakeEngine();
        final m = manager(engine, maxConcurrency: 1);
        addTearDown(m.dispose);

        final chosen = [entry('a')];
        m.enqueuePlaylist(
          playlist: playlist(chosen, title: 'Mix/Tapes: 2026'),
          selected: chosen,
          format: _video('a').videoFormats.first,
        );

        await waitUntil(
          () => m.tasks.every((t) => t.status == DownloadStatus.completed),
        );

        // The title must not have created nested directories.
        final videoDir = Directory(p.join(tempRoot.path, 'Video'));
        expect(videoDir.existsSync(), isTrue);
        final names = videoDir
            .listSync()
            .whereType<Directory>()
            .map((d) => p.basename(d.path))
            .toList();
        expect(names, ['Mix_Tapes_ 2026']);
      },
    );

    test('the history record remembers the playlist', () async {
      final engine = _FakeEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final chosen = [entry('a')];
      m.enqueuePlaylist(
        playlist: playlist(chosen),
        selected: chosen,
        format: _video('a').videoFormats.first,
      );

      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.completed),
      );
      await waitUntil(() => history.records.isNotEmpty);

      expect(history.records.single.playlistTitle, 'Road Trip');
    });

    test(
      'retry keeps the playlist so the entry lands in the same folder',
      () async {
        final engine = _FakeEngine(exitCode: Future<int>.value(1));
        final m = manager(engine, maxConcurrency: 1);
        addTearDown(m.dispose);

        final chosen = [entry('a')];
        final task = m
            .enqueuePlaylist(
              playlist: playlist(chosen),
              selected: chosen,
              format: _video('a').videoFormats.first,
            )
            .single;

        await waitUntil(() => task.status == DownloadStatus.failed);
        expect(task.playlistTitle, 'Road Trip');

        // A retry of a failed task carries the provenance forward.
        final retried = m.retry(task);
        expect(retried, isNotNull);
        expect(retried!.playlistId, task.playlistId);
        expect(retried.playlistTitle, 'Road Trip');
      },
    );

    test('cancelPlaylist cancels the running and queued entries', () async {
      // maxConcurrency 1 so one entry runs and the rest queue behind it.
      final engine = _FakeEngine(
        exitCode: Completer<int>().future, // never completes on its own
      );
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      final chosen = [entry('a'), entry('b'), entry('c')];
      m.enqueuePlaylist(
        playlist: playlist(chosen),
        selected: chosen,
        format: _video('a').videoFormats.first,
      );
      await waitUntil(() => engine.started == 1);

      expect(m.cancelPlaylist('PL1'), 3);
      await waitUntil(
        () => m.tasks.every((t) => t.status == DownloadStatus.canceled),
      );
    });

    test('a listener that removes a task mid-pump does not break the scheduler',
        () async {
      // `_pump` used to iterate the live task list lazily while calling
      // `notifyListeners` inside that loop. A listener that removes a task — the
      // queue UI does exactly this when a card is dismissed — mutated the list
      // mid-iteration, raising ConcurrentModificationError out of an async
      // callback, where it surfaces as an unhandled error.
      final engine = _FakeEngine(exitCode: Completer<int>().future);
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      for (final id in ['a', 'b', 'c']) {
        m.enqueue(video: _video(id), format: _video(id).videoFormats.first);
      }
      await waitUntil(() => engine.started == 1);

      var removals = 0;
      m.addListener(() {
        if (removals >= 1) return;
        final waiting = m.tasks.where((t) => t.status == DownloadStatus.queued);
        if (waiting.isEmpty) return;
        removals++;
        m.dismiss(waiting.first.id);
      });

      // Enqueuing pumps again, which is where the mutation happens. Concurrency
      // is 1 and one task is already running, so this pump starts nothing and
      // simply has to survive the notification.
      m.enqueue(video: _video('d'), format: _video('d').videoFormats.first);
      await waitUntil(() => removals == 1);

      // The manager is still usable and the queue is intact.
      expect(removals, 1);
      expect(m.tasks, isNotEmpty);
      expect(
        m.queuedCount,
        greaterThanOrEqualTo(1),
        reason: 'the other waiting tasks were not lost',
      );

      // Releasing the running slot drains the rest of the queue.
      final running = m.tasks.firstWhere(
        (t) => t.status == DownloadStatus.downloading,
      );
      m.cancel(running.id);
      await waitUntil(() => m.queuedCount == 0);
    });

    test('cancelPlaylist ignores tasks from another playlist', () async {
      final engine = _FakeEngine();
      final m = manager(engine, maxConcurrency: 1);
      addTearDown(m.dispose);

      m.enqueuePlaylist(
        playlist: playlist([entry('a')]),
        selected: [entry('a')],
        format: _video('a').videoFormats.first,
      );
      m.enqueue(video: entry('solo'), format: _video('a').videoFormats.first);

      expect(m.cancelPlaylist('PL1'), 1);
      // The unrelated single video is untouched.
      final solo = m.tasks.firstWhere((t) => t.playlistId == null);
      expect(solo.status, isNot(DownloadStatus.canceled));
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

    test(
      'sidecar subtitles/thumbnails move with the media file; partials stay',
      () async {
        final engine = _FakeEngine(sidecars: true);
        final m = manager(engine);
        addTearDown(m.dispose);

        final t = m.enqueue(
          video: _video('abc123'),
          format: _video('abc123').videoFormats.first,
        );
        await waitUntil(() => t.status == DownloadStatus.completed);

        // All three artifacts land in the final Video/ folder...
        bool inFinal(String name) =>
            File(p.join(tempRoot.path, 'Video', name)).existsSync();
        await waitUntil(() => inFinal('Title [abc123].jpg'));
        expect(inFinal('Title [abc123].mp4'), isTrue);
        expect(inFinal('Title [abc123].en.srt'), isTrue);
        // ...the stale .part does not.
        expect(inFinal('Title [abc123].mp4.part'), isFalse);
        expect(t.filePath, endsWith('Title [abc123].mp4'));
        // Staging is removed by the task's `finally` block, which runs *after*
        // the file is moved, so it has to be waited for rather than asserted
        // at the moment the artifacts appear.
        await waitUntil(
          () =>
              !Directory(p.join(tempRoot.path, '.ytdlp-staging')).existsSync(),
        );
      },
    );

    test(
      'a Destination line pointing at a subtitle never wins over the media',
      () async {
        final engine = _FakeEngine(sidecars: true, destinationIsSidecar: true);
        final m = manager(engine);
        addTearDown(m.dispose);

        final t = m.enqueue(
          video: _video('abc123'),
          format: _video('abc123').videoFormats.first,
        );
        await waitUntil(() => t.status == DownloadStatus.completed);

        expect(t.filePath, endsWith('Title [abc123].mp4'));
        expect(
          await File(p.join(tempRoot.path, 'Video', 'Title [abc123].mp4'))
              .exists(),
          isTrue,
        );
        // The sidecar was moved too (destinationIsSidecar wrote one).
        expect(
          await File(p.join(tempRoot.path, 'Video', 'Title [abc123].en.srt'))
              .exists(),
          isTrue,
        );
      },
    );

    test('two downloads resolving to one name both survive', () async {
      // The regression this guards: choosing a free name checked for a
      // collision, then renamed without holding anything across the gap. Two
      // downloads finishing together both saw the name as free, and `rename`
      // *deletes* an existing destination — so one file was silently destroyed
      // and both tasks reported the same path.
      final engine = _SameNameEngine();
      final m = manager(engine, maxConcurrency: 2);
      addTearDown(m.dispose);

      final a = m.enqueue(video: _video('a'), format: _video('a').videoFormats.first);
      final b = m.enqueue(video: _video('b'), format: _video('b').videoFormats.first);
      await waitUntil(
        () => a.status == DownloadStatus.completed &&
            b.status == DownloadStatus.completed,
      );

      expect(a.filePath, isNot(b.filePath), reason: 'distinct final paths');
      expect(a.filePath, isNotNull);
      expect(b.filePath, isNotNull);
      // Both files are actually on disk with their own contents.
      expect(File(a.filePath!).existsSync(), isTrue);
      expect(File(b.filePath!).existsSync(), isTrue);
      expect(File(a.filePath!).readAsStringSync(), 'video-a');
      expect(File(b.filePath!).readAsStringSync(), 'video-b');
    });
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

    test('a snapshot written before queueSeq existed still restores in order',
        () async {
      // Snapshots from an older build carry no queueSeq, so `fromMap` falls back
      // to the creation time to reconstruct the old "oldest first" order.
      final store = QueueStore(historyBox);
      final video = _video('abc123');
      Map<String, dynamic> snapshotOf(String id, DateTime at) {
        final map = DownloadTask(
          id: id,
          video: video,
          format: video.videoFormats.first,
          createdAt: at,
        ).toMap();
        map.remove('queueSeq');
        return map;
      }

      await historyBox.put('queue', [
        snapshotOf('newest', DateTime(2026, 3)),
        snapshotOf('oldest', DateTime(2026, 1)),
      ]);

      final m = DownloadManager(
        ytdlp: _FakeEngine(),
        history: history,
        downloadsDir: () async => tempRoot,
        queueStore: store,
      );
      addTearDown(m.dispose);

      await waitUntil(() => m.tasks.length == 2);
      expect(m.queueInStartOrder.map((t) => t.id), ['oldest', 'newest']);
    });

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
              options: const DownloadOptions(
                writeSubs: true,
                embedThumb: true,
                includeAutoSubs: true,
                subLanguages: ['en', 'de'],
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
      expect(back.queueSeq, task.queueSeq);
      expect(back.options.writeSubs, isTrue);
      expect(back.options.embedThumb, isTrue);
      expect(back.options.includeAutoSubs, isTrue);
      expect(back.options.subLanguages, ['en', 'de']);
    });

    test('prefs round-trip on a task', () {
      const prefs = YtPrefs(concurrentFragments: 4, audioFormat: 'flac');
      final task = DownloadTask(
        id: 't1',
        video: _video('a'),
        format: _video('a').videoFormats.first,
        createdAt: DateTime.now(),
        prefs: prefs,
      );
      expect(DownloadTask.fromMap(task.toMap()).prefs, prefs);
    });

    test('a task from an older snapshot gets neutral prefs', () {
      final back = DownloadTask.fromMap({
        'id': 'old',
        'createdAt': DateTime.now().toIso8601String(),
        'video': const <String, dynamic>{},
        'format': const <String, dynamic>{},
      });
      expect(back.prefs, const YtPrefs());
    });

    test('a corrupt prefs map still restores the task', () {
      final back = DownloadTask.fromMap({
        'id': 't',
        'createdAt': DateTime.now().toIso8601String(),
        'video': const <String, dynamic>{},
        'format': const <String, dynamic>{},
        'prefs': 'not a map',
      });
      expect(back.prefs, const YtPrefs());
    });

    test('extraArgs and outputTemplate round-trip on a task', () {
      final task = DownloadTask(
        id: 't1',
        video: _video('a'),
        format: _video('a').videoFormats.first,
        createdAt: DateTime.now(),
        extraArgs: const ['--concurrent-fragments', '4'],
        outputTemplate: '%(uploader)s/%(title)s.%(ext)s',
        playlistId: 'PL1',
        playlistTitle: 'Road Trip',
      );

      final back = DownloadTask.fromMap(task.toMap());
      expect(back.extraArgs, ['--concurrent-fragments', '4']);
      expect(back.outputTemplate, '%(uploader)s/%(title)s.%(ext)s');
      expect(back.playlistId, 'PL1');
      expect(back.playlistTitle, 'Road Trip');
    });

    test('a task from an older snapshot defaults the new fields', () {
      // An install upgrading mid-queue has snapshots without these keys.
      final back = DownloadTask.fromMap({
        'id': 'old',
        'createdAt': DateTime.now().toIso8601String(),
        'video': {'id': 'a', 'title': 'T', 'webUrl': 'u'},
        'format': {'kind': 'video', 'label': 'L', 'selector': 'b'},
      });
      expect(back.extraArgs, isEmpty);
      expect(back.outputTemplate, isEmpty);
      expect(back.playlistId, isNull);
    });

    test('a task from an older snapshot gets neutral youtube prefs', () {
      final back = DownloadTask.fromMap({
        'id': 'old',
        'createdAt': DateTime.now().toIso8601String(),
        'video': const <String, dynamic>{},
        'format': const <String, dynamic>{},
      });
      expect(back.youtube, const YoutubePrefs());
    });

    test('youtube prefs round-trip on a task', () {
      const yt = YoutubePrefs(useEjs: false, extraClients: [YoutubeClient.ios]);
      final task = DownloadTask(
        id: 't1',
        video: _video('a'),
        format: _video('a').videoFormats.first,
        createdAt: DateTime.now(),
        youtube: yt,
      );
      expect(DownloadTask.fromMap(task.toMap()).youtube, yt);
    });

    test('a corrupt youtube map still restores the task', () {
      final back = DownloadTask.fromMap({
        'id': 't',
        'createdAt': DateTime.now().toIso8601String(),
        'video': const <String, dynamic>{},
        'format': const <String, dynamic>{},
        'youtube': 'not a map',
      });
      expect(back.youtube, const YoutubePrefs());
    });

    test('extraArgs of the wrong type is tolerated', () {
      final back = DownloadTask.fromMap({
        'id': 't',
        'createdAt': DateTime.now().toIso8601String(),
        'video': const <String, dynamic>{},
        'format': const <String, dynamic>{},
        'extraArgs': 'not a list',
      });
      expect(back.extraArgs, isEmpty);
    });

    test('DownloadOptions round-trips and tolerates a missing map', () {
      const opts = DownloadOptions(
        embedSubs: true,
        writeSubs: true,
        includeAutoSubs: true,
        subLanguages: ['fr', 'en'],
        embedThumb: true,
        writeThumb: true,
      );
      final back = DownloadOptions.fromMap(opts.toMap());
      expect(back.embedSubs, isTrue);
      expect(back.writeSubs, isTrue);
      expect(back.includeAutoSubs, isTrue);
      expect(back.subLanguages, ['fr', 'en']);
      expect(back.embedThumb, isTrue);
      expect(back.writeThumb, isTrue);
      expect(back.subLangsTarget, 'fr,en');

      expect(DownloadOptions.fromMap(null).embedSubs, isFalse);
      expect(const DownloadOptions().subLangsTarget, 'all');

      const allOff = DownloadOptions();
      expect(
        DownloadOptions.fromMap(allOff.toMap()).embedSubs,
        isFalse,
        reason: 'a round-tripped task keeps its choices',
      );
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

    test(
      'a snapshot is written during a download, not only after it',
      () async {
        // The regression this guards: persistence was debounced, and the
        // debounce restarted on every yt-dlp output line. Progress arrives far
        // more often than the debounce interval, so the timer never fired for
        // the whole duration of a download — and the snapshot that exists
        // precisely to survive the app being killed was never written at all.
        final engine = _PacedProgressEngine();
        final store = QueueStore(historyBox);
        await historyBox.delete('queue');
        final m = DownloadManager(
          ytdlp: engine,
          history: history,
          downloadsDir: () async => tempRoot,
          queueStore: store,
        );
        addTearDown(m.dispose);

        m.enqueue(
          video: _video('abc123'),
          format: _video('abc123').videoFormats.first,
        );
        await waitUntil(() => engine.started == 1);
        // Part way through the paced output: long past a debounce window, with
        // progress lines still arriving and the download not yet finished.
        await Future<void>.delayed(const Duration(milliseconds: 500));

        final snapshot = store.load();
        expect(
          snapshot.map((t) => t.video.id),
          contains('abc123'),
          reason: 'the queue was persisted while still downloading',
        );
        expect(snapshot.single.status, DownloadStatus.downloading);
      },
    );

    test('a terminal state is written straight away', () async {
      final store = QueueStore(historyBox);
      await historyBox.delete('queue');
      final engine = _FakeEngine();
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        queueStore: store,
      );
      addTearDown(m.dispose);

      m.cancel(
        m.enqueue(
          video: _video('abc123'),
          format: _video('abc123').videoFormats.first,
        ).id,
      );
      await waitUntil(() => store.load().isNotEmpty);

      final persisted = store.load().single;
      expect(persisted.status, DownloadStatus.canceled);
    });
  });

  group('DownloadManager metered-data gate', () {
    Future<({DownloadManager manager, _FakeProbe probe})> gatedManager(
      DownloadEngine engine, {
      required bool allowed,
      bool wifiOnly = true,
    }) async {
      final probe = _FakeProbe(allowed: allowed);
      final settingsBox = await Hive.openBox<dynamic>('settings-gate');
      final settings = SettingsService(settingsBox)..init();
      await settings.update(AppSettings(wifiOnly: wifiOnly));
      final m = DownloadManager(
        ytdlp: engine,
        history: history,
        downloadsDir: () async => tempRoot,
        settings: settings,
        networkProbe: probe,
      );
      addTearDown(m.dispose);
      addTearDown(() => settingsBox.close());
      return (manager: m, probe: probe);
    }

    test(
      'holds new downloads when wifiOnly is on and the network is metered',
      () async {
        final engine = _FakeEngine();
        final (:manager, :probe) = await gatedManager(engine, allowed: false);
        expect(probe.refreshCalls, 0);

        final t = manager.enqueue(
          video: _video('a'),
          format: _video('a').videoFormats.first,
        );

        // The task is queued, not started: the cost of the download is
        // deferred until an unmetered network is available. Nothing was
        // burned on the user's mobile data.
        expect(t.status, DownloadStatus.queued);
        expect(engine.started, 0);
      },
    );

    test('starts held downloads once the network becomes unmetered', () async {
      final engine = _FakeEngine();
      final (:manager, :probe) = await gatedManager(engine, allowed: false);

      final t = manager.enqueue(
        video: _video('a'),
        format: _video('a').videoFormats.first,
      );
      expect(t.status, DownloadStatus.queued);
      expect(engine.started, 0);

      // The network becomes unmetered, the connectivity stream fires,
      // and the held queue is re-examined.
      probe.allowed = true;
      manager.onConnectivityChanged();
      await waitUntil(() => t.status == DownloadStatus.completed);

      expect(engine.started, 1);
    });

    test(
      'a running download is not interrupted when the gate closes',
      () async {
        // An exit code that never arrives keeps the task in
        // `downloading`, so the mid-flight state is observable.
        final hang = Completer<int>();
        final engine = _FakeEngine(exitCode: hang.future);
        final (:manager, :probe) = await gatedManager(engine, allowed: true);

        final t = manager.enqueue(
          video: _video('a'),
          format: _video('a').videoFormats.first,
        );
        // The gate was open, so it started.
        await waitUntil(() => engine.started == 1);
        expect(t.status, DownloadStatus.downloading);

        // The network turning metered mid-download must not matter: the
        // rule applies to *starting* work, so the bytes already being
        // paid for keep flowing. The task is never moved back to
        // `queued` and never cancelled.
        probe.allowed = false;
        expect(t.status, DownloadStatus.downloading);

        // Let the process "exit" so the run loop unwinds cleanly.
        hang.complete(0);
        await waitUntil(() => t.status == DownloadStatus.completed);
        expect(engine.started, 1);
      },
    );

    test('wifiOnly off ignores the gate entirely', () async {
      final engine = _FakeEngine();
      final (:manager, :probe) = await gatedManager(
        engine,
        allowed: false,
        wifiOnly: false,
      );

      final t = manager.enqueue(
        video: _video('a'),
        format: _video('a').videoFormats.first,
      );

      // The user did not ask for unmetered-only, so a metered network
      // is no reason to hold the download.
      expect(t.status, DownloadStatus.downloading);
      await waitUntil(() => engine.started == 1);
      await waitUntil(() => t.status == DownloadStatus.completed);
    });
  });
}
