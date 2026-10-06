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

/// The action button on the card for the video titled [title].
Finder _cardAction(String title, String tooltip) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(Card)),
  matching: find.byTooltip(tooltip),
);

/// The status line the card for the video titled [title] is showing.
///
/// Read by widget text rather than by re-deriving the state, so the assertion
/// is about what the user sees.
String _cardState(WidgetTester tester, String title) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(Card)),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data ?? '')
    .firstWhere(
      (s) =>
          s == 'Paused' ||
          s.startsWith('Paused at') ||
          s == 'Waiting to start' ||
          s == 'Canceled',
      orElse: () => 'other',
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

  /// Whether the UI is told the queue is paused.
  ///
  /// Separate from the real flag because the scheduler must stay blocked in
  /// every test, while a few of them need to see an *unpaused* queue. `resume`
  /// is overridden to a counter, so the real flag can never be cleared here.
  bool reportsPaused = true;

  @override
  bool get isPaused => reportsPaused && super.isPaused;

  final List<String> canceled = [];
  final List<String> dismissed = [];
  final List<String> paused = [];
  final List<String> resumed = [];
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
    // Really removes it, so a test can reach the genuinely-empty queue the
    // overflow menu has to cope with. The real manager does the same.
    tasks.removeWhere((t) => t.id == id);
    notifyListeners();
    return true;
  }

  @override
  bool reorder(String id, int offset) {
    reorderCalls++;
    return true;
  }

  /// Counted rather than delegated: the real one cancels the process, which
  /// does not exist here, and would leave the task in `downloading` forever.
  @override
  bool pauseTask(String id) {
    paused.add(id);
    tasks.where((t) => t.id == id).firstOrNull?.status = DownloadStatus.paused;
    notifyListeners();
    return true;
  }

  @override
  bool resumeTask(String id) {
    resumed.add(id);
    tasks.where((t) => t.id == id).firstOrNull?.status = DownloadStatus.queued;
    notifyListeners();
    return true;
  }

  @override
  int resumeAllPaused() {
    var n = 0;
    for (final t in tasks) {
      if (t.status != DownloadStatus.paused) continue;
      t.status = DownloadStatus.queued;
      n++;
    }
    return n;
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
    // "All held" rather than "Paused": a card can be held on its own, so the
    // chip has to say which kind of pause is in force.
    expect(find.text('All held'), findsOneWidget);
    expect(find.byTooltip('Resume every held download'), findsOneWidget);
    // Counts stay visible while paused, so the queue does not look empty.
    expect(find.text('1 queued'), findsOneWidget);
  });

  testWidgets('tapping resume asks the manager to resume', (tester) async {
    manager.seed([_task('a')]);
    await pump(tester);

    await tester.tap(find.byTooltip('Resume every held download'));
    await tester.pumpAndSettle();
    expect(manager.resumeCalls, 1);
  });

  testWidgets('a per-task hold is reported separately from the queue pause', (
    tester,
  ) async {
    // Reported as running, so the per-task chip is the one on screen.
    manager.reportsPaused = false;
    manager.seed([_task('a'), _task('b')]);
    await pump(tester);
    expect(find.text('1 held'), findsNothing, reason: 'nothing is held yet');

    await tester.tap(find.byTooltip('Pause this download').first);
    await tester.pumpAndSettle();

    expect(find.text('1 held'), findsOneWidget);
    expect(find.text('All held'), findsNothing);
  });

  testWidgets('the queue-wide pause also releases a held task', (tester) async {
    // Otherwise a "hold this one" would survive a global "go" and look stuck.
    manager.seed([_task('a')]);
    await pump(tester);
    await tester.tap(find.byTooltip('Pause this download'));
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);

    await tester.tap(find.byTooltip('Resume every held download'));
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

  testWidgets('the overflow menu is hidden when it would be empty', (
    tester,
  ) async {
    // With queued work there is something to cancel, so the menu is offered.
    manager.seed([_task('a')]);
    await pump(tester);
    expect(find.byTooltip('More queue actions'), findsOneWidget);

    // Once it finishes there is still something to clear, so it stays.
    manager.setStatus('a', DownloadStatus.completed);
    await pump(tester);
    expect(find.byTooltip('More queue actions'), findsOneWidget);

    // And once that is dismissed there is nothing to clear and nothing to
    // cancel. The button used to stay visible and open a blank sheet.
    manager.dismiss(manager.tasks.single.id);
    await pump(tester);
    expect(manager.tasks, isEmpty);
    expect(
      find.byTooltip('More queue actions'),
      findsNothing,
      reason: 'no clear, no cancel: nothing for the menu to do',
    );
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
    await tester.tap(find.byTooltip('Remove from the queue'));
    await tester.pumpAndSettle();
    expect(manager.dismissed, contains(id));
  });

  group('per-task actions', () {
    testWidgets('a running task offers pause and cancel as icons only', (
      tester,
    ) async {
      manager.seed([_task('a')]);
      manager.setStatus('a', DownloadStatus.downloading);
      await pump(tester);

      expect(find.byTooltip('Pause this download'), findsOneWidget);
      expect(find.byTooltip('Cancel this download'), findsOneWidget);
      // Icon-only: a labelled button per card turns a long queue into a wall of
      // buttons, so the names live in the tooltips instead.
      expect(find.widgetWithText(Text, 'Cancel'), findsNothing);
    });

    testWidgets('tapping pause holds that task only', (tester) async {
      manager.seed([_task('a'), _task('b')]);
      manager.setStatus('a', DownloadStatus.downloading);
      await pump(tester);

      // Scoped to the card, because both offer a pause and the queue is
      // newest-first, so `.first` would be the other task.
      await tester.tap(_cardAction('Video a', 'Pause this download'));
      await tester.pumpAndSettle();

      expect(manager.paused, hasLength(1));
      expect(
        manager.paused.single,
        manager.tasks.firstWhere((t) => t.video.title == 'Video a').id,
      );
      // Progress is kept, so the card names the percentage it stopped at.
      expect(_cardState(tester, 'Video a'), 'Paused at 50.0%');
      // The other card is untouched, which is the point of a per-task hold.
      expect(_cardState(tester, 'Video b'), 'Waiting to start');
    });

    testWidgets('a held task offers resume and cancel', (tester) async {
      manager.seed([_task('a')]);
      await pump(tester);
      await tester.tap(find.byTooltip('Pause this download'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Resume this download'), findsOneWidget);
      expect(find.byTooltip('Cancel this download'), findsOneWidget);
      expect(find.byTooltip('Pause this download'), findsNothing);
    });

    testWidgets('tapping resume releases that task', (tester) async {
      manager.seed([_task('a')]);
      await pump(tester);
      await tester.tap(find.byTooltip('Pause this download'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Resume this download'));
      await tester.pumpAndSettle();

      expect(manager.resumed, hasLength(1));
      expect(find.text('Waiting to start'), findsOneWidget);
    });

    testWidgets('a held task keeps its progress in the label', (tester) async {
      manager.seed([_task('a')]);
      manager.setStatus('a', DownloadStatus.downloading);
      await pump(tester);
      await tester.tap(find.byTooltip('Pause this download'));
      await tester.pumpAndSettle();

      // The .part is still on disk, so the percentage is worth showing.
      expect(find.text('Paused at 50.0%'), findsOneWidget);
    });

    testWidgets('a held task offers no reorder controls', (tester) async {
      manager.seed([_task('a')]);
      await pump(tester);
      await tester.tap(find.byTooltip('Pause this download'));
      await tester.pumpAndSettle();

      // Releasing puts it at the back of the queue, so arrows would promise an
      // ordering the scheduler would not honour.
      expect(find.byTooltip('Move earlier in the queue'), findsNothing);
      expect(find.byTooltip('Move later in the queue'), findsNothing);
    });

    testWidgets('a canceled task offers retry as well as dismiss', (
      tester,
    ) async {
      // Cancel keeps the partial, so retry continues rather than restarting.
      manager.seed([_task('a')]);
      manager.setStatus('a', DownloadStatus.canceled);
      await pump(tester);

      expect(find.byTooltip('Try again'), findsOneWidget);
      expect(find.byTooltip('Remove from the queue'), findsOneWidget);
    });

    testWidgets('a completed task offers no retry', (tester) async {
      // Re-running a finished download is a new download; offering it behind a
      // retry icon would be a trap.
      manager.seed([_task('a')]);
      manager.setStatus('a', DownloadStatus.completed);
      await pump(tester);

      expect(find.byTooltip('Try again'), findsNothing);
      expect(find.byTooltip('Open the file'), findsOneWidget);
    });
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
    // Icon-only here too, matching the other per-task actions.
    expect(find.byTooltip('Open the file'), findsOneWidget);
    expect(find.byTooltip('Share the file'), findsOneWidget);
    expect(find.byTooltip('Delete file'), findsOneWidget);
    expect(find.widgetWithText(Text, 'Open'), findsNothing);
  });
}
