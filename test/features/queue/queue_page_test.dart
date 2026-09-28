import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/queue/queue_page.dart';
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

VideoInfo _video(String id) => VideoInfo(
  id: 'abc',
  title: 'Video $id',
  webUrl: 'https://example.com/v?id=$id',
  duration: 60,
  videoFormats: const [
    Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
  ],
);

/// Never writes a file, so tasks can be left in any state the UI can show.
class _StubManager extends DownloadManager {
  _StubManager(HistoryService history, Directory dir)
    : super(
        ytdlp: YtdlpService(BinaryManager()),
        history: history,
        downloadsDir: () async => dir,
      ) {
    // Paused, so enqueue never reaches the scheduler: seeded tasks stay in
    // whatever state the test puts them in, and no process is ever started.
    pause();
  }

  final List<String> canceled = [];
  final List<String> dismissed = [];
  int reorderCalls = 0;
  int allCanceled = 0;
  int finishedCleared = 0;

  /// Real `resume` would pump the scheduler and spawn yt-dlp processes, so the
  /// UI tests count the call instead. The queue genuinely staying paused also
  /// keeps every task in `queued`, which is what the card states are set from.
  int resumeCalls = 0;

  /// Enqueues every task in `queued` state.
  void seed(List<DownloadTask> tasks) {
    for (final t in tasks) {
      enqueue(video: t.video, format: t.format, playlistTitle: t.playlistTitle);
    }
  }

  /// Forces a state on the task whose video id is [videoId].
  ///
  /// A downloading task is given a non-zero progress deliberately: the queue
  /// card shows an *indeterminate* progress bar at zero, which animates
  /// forever and would make every `pumpAndSettle` time out.
  void setStatus(String videoId, DownloadStatus status) {
    final t = tasks.firstWhere((x) => x.video.title == 'Video $videoId');
    t.status = status;
    if (status == DownloadStatus.downloading) t.progress = 0.5;
    notifyListeners();
  }

  @override
  void cancel(String id) {
    canceled.add(id);
    final t = tasks.where((x) => x.id == id).firstOrNull;
    if (t != null) t.status = DownloadStatus.canceled;
    notifyListeners();
  }

  @override
  int cancelAll() {
    allCanceled++;
    var n = 0;
    for (final t in tasks) {
      if (t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.downloading) {
        t.status = DownloadStatus.canceled;
        n++;
      }
    }
    notifyListeners();
    return n;
  }

  @override
  int clearFinished() {
    finishedCleared++;
    return super.clearFinished();
  }

  @override
  bool dismiss(String id) {
    dismissed.add(id);
    return true;
  }

  @override
  bool reorder(String id, int offset) {
    reorderCalls++;
    return true;
  }

  @override
  void resume() => resumeCalls++;
}

DownloadTask _task(String id, {String? playlist}) => DownloadTask(
  id: id,
  video: _video(id),
  format: const Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
  createdAt: DateTime.now(),
  playlistTitle: playlist,
);

void main() {
  late _StubManager manager;
  late Directory tempRoot;
  late Box<dynamic> historyBox;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-queue-');
    Hive.init(tempRoot.path);
    historyBox = await Hive.openBox<dynamic>('queue-page-history');
    manager = _StubManager(HistoryService(historyBox), tempRoot);
  });

  tearDown(() async {
    manager.dispose();
    await historyBox.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [downloadManagerProvider.overrideWithValue(manager)],
        child: const MaterialApp(home: QueuePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty queue explains itself', (tester) async {
    await pump(tester);
    expect(find.text('Nothing downloading'), findsOneWidget);
  });

  testWidgets('lists tasks and shows the active/queued counts', (tester) async {
    manager.seed([_task('a'), _task('b'), _task('c')]);
    manager.setStatus('a', DownloadStatus.downloading);
    await pump(tester);

    expect(find.text('Video a'), findsOneWidget);
    expect(find.text('Video b'), findsOneWidget);
    // The counts share one label, so both parts read together.
    expect(find.text('1 active · 2 queued'), findsOneWidget);
  });

  testWidgets('the paused queue offers a resume affordance', (tester) async {
    manager.seed([_task('a')]);
    // The stub starts paused, which is the state the button reports.
    await pump(tester);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.byTooltip('Resume the queue'), findsOneWidget);
    // Counts stay visible while paused, so the queue does not look empty.
    expect(find.text('1 queued'), findsOneWidget);
  });

  testWidgets('tapping resume asks the manager to resume', (tester) async {
    manager.seed([_task('a')]);
    await pump(tester);

    await tester.tap(find.byTooltip('Resume the queue'));
    await tester.pumpAndSettle();
    expect(manager.resumeCalls, 1);
  });

  // The reverse direction (pausing an unpaused queue) is covered by the
  // manager unit tests: calling resume() here would start a real yt-dlp
  // process, which a widget test must never do.

  testWidgets('cancel all asks before killing in-flight work', (tester) async {
    manager.seed([_task('a'), _task('b')]);
    await pump(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel all'));
    await tester.pumpAndSettle();

    // The dialog must appear before anything is canceled.
    expect(find.text('Cancel all downloads?'), findsOneWidget);
    expect(manager.canceled, isEmpty);

    await tester.tap(find.text('Keep going'));
    await tester.pumpAndSettle();
    expect(manager.canceled, isEmpty, reason: 'backing out cancels nothing');
  });

  testWidgets('clear finished is offered only when something is finished', (
    tester,
  ) async {
    // A running task alone has nothing to clear.
    manager.seed([_task('a')]);
    await pump(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.textContaining('Clear finished'), findsNothing);
  });

  testWidgets('a playlist task names its playlist', (tester) async {
    manager.seed([_task('a', playlist: 'Road Trip')]);
    await pump(tester);

    expect(find.text('Road Trip'), findsOneWidget);
  });

  group('reordering', () {
    testWidgets('a waiting task offers move controls', (tester) async {
      manager.seed([_task('a'), _task('b')]);
      await pump(tester);

      expect(
        find.byTooltip('Move earlier in the queue'),
        findsNWidgets(2),
        reason: 'both are queued, so both are reprioritisable',
      );
    });

    testWidgets('tapping move calls reorder on the manager', (tester) async {
      manager.seed([_task('a'), _task('b')]);
      await pump(tester);

      await tester.tap(find.byTooltip('Move later in the queue').first);
      await tester.pumpAndSettle();
      expect(manager.reorderCalls, 1);
    });

    testWidgets('a running task offers no move controls', (tester) async {
      manager.seed([_task('a')]);
      manager.setStatus('a', DownloadStatus.downloading);
      await pump(tester);

      expect(find.byTooltip('Move earlier in the queue'), findsNothing);
      expect(find.byTooltip('Move later in the queue'), findsNothing);
    });
  });

  testWidgets('a canceled task shows its state and can be dismissed', (
    tester,
  ) async {
    manager.seed([_task('a')]);
    manager.setStatus('a', DownloadStatus.canceled);
    await pump(tester);

    expect(find.text('Canceled'), findsOneWidget);
    final id = manager.tasks.single.id;
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(manager.dismissed, contains(id));
  });

  testWidgets('the layout is constrained to a readable width', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    manager.seed([_task('a')]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [downloadManagerProvider.overrideWithValue(manager)],
        child: const MaterialApp(home: QueuePage()),
      ),
    );
    await tester.pumpAndSettle();

    // A wide window still renders the list at a readable width rather than
    // stretching cards across the whole screen.
    final box = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .firstWhere((b) => b.constraints.maxWidth == 760);
    expect(box.constraints.maxWidth, 760);
  });

  testWidgets('a completed task offers open, share and delete', (tester) async {
    manager.seed([_task('a')]);
    manager.setStatus('a', DownloadStatus.completed);
    await pump(tester);

    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.byTooltip('Delete file'), findsOneWidget);
  });
}
