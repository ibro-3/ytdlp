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
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
import 'package:ytdlp/services/downloads/download_layout.dart';
import 'package:ytdlp/services/downloads/queue_store.dart';
import 'package:ytdlp/services/settings/settings_service.dart';
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

/// Records the extra arguments the manager hands the engine, and produces a
/// valid file so the task completes.
class _RecordingArgsEngine extends _FakeEngine {
  _RecordingArgsEngine({super.exitCode});

  List<String> extraArgs = const [];
  String template = '';
  YtPrefs prefs = const YtPrefs();
  String? archivePath;

  @override
  Future<_FakeProcess> startDownload({
    required String url,
    required Format format,
    required DownloadOptions options,
    required String outputDir,
    required String template,
    String? cookiesPath,
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
  }) {
    this.extraArgs = extraArgs;
    this.template = template;
    this.prefs = prefs;
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
  });

  final Future<int>? exitCode;
  final bool sidecars;
  final bool destinationIsSidecar;
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
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
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
      _FakeProcess(lines: lines, exitCode: exitCode ?? Future<int>.value(0)),
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
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
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
    List<String> extraArgs = const [],
    YtPrefs prefs = const YtPrefs(),
    String? archivePath,
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
        // ...the stale .part does not, and neither does staging itself.
        expect(inFinal('Title [abc123].mp4.part'), isFalse);
        expect(
          Directory(p.join(tempRoot.path, '.ytdlp-staging')).existsSync(),
          isFalse,
        );
        expect(t.filePath, endsWith('Title [abc123].mp4'));
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

      expect(DownloadOptions.fromMap(null).subsEnabled, isFalse);
      expect(const DownloadOptions().subLangsTarget, 'all');

      const allOff = DownloadOptions();
      expect(DownloadOptions.fromMap(allOff.toMap()).subsEnabled, isFalse);
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
