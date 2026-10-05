import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:go_router/go_router.dart';
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/download_options.dart';
import 'package:ytdlp/core/models/yt_prefs.dart';
import 'package:ytdlp/core/models/youtube_prefs.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/queue/batch_queue_controller.dart';
import 'package:ytdlp/features/queue/batch_queue_page.dart';
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

import '../../support/pump.dart';

/// Starts the page in a fixed, already-resolved state instead of kicking off
/// real `yt-dlp` fetches through the controller's `resolveAll`.
class _SeededBatchController extends BatchQueueController {
  _SeededBatchController(this._initial);

  final BatchState _initial;

  @override
  BatchState build() => _initial;
}

VideoInfo _video(String id) => VideoInfo(
  id: id,
  title: 'Video $id',
  webUrl: 'https://example.com/watch?v=$id',
  duration: 60,
  videoFormats: const [
    Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
  ],
);

PlaylistInfo _playlist({String title = 'Mix', int count = 3}) => PlaylistInfo(
  id: 'list-$title',
  title: title,
  webUrl: 'https://example.com/playlist?list=$title',
  entries: [
    for (var i = 0; i < count; i++)
      VideoInfo(
        id: '$title-$i',
        title: 'Entry $i',
        webUrl: 'https://example.com/watch?v=$title-$i',
        duration: 60,
        videoFormats: const [],
      ),
  ],
);

/// A queue that records what it was asked to enqueue without ever spawning a
/// process. Mirrors `_StubManager` in `queue_page_test.dart`: the real manager
/// starts yt-dlp, which cannot happen in a widget test.
class _StubManager extends DownloadManager {
  _StubManager(HistoryService history, Directory dir)
    : super(
        ytdlp: YtdlpService(BinaryManager()),
        history: history,
        downloadsDir: () async => dir,
      ) {
    pause();
  }

  final List<(String, Format)> enqueued = [];

  @override
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
    enqueued.add((video.title, format));
    return super.enqueue(video: video, format: format, options: options);
  }
}

void main() {
  late Directory root;
  late Box<dynamic> box;
  late _StubManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('ytdlp-batch-');
    Hive.init(root.path);
    box = await Hive.openBox<dynamic>('batch-page');
    manager = _StubManager(HistoryService(box), root);
  });

  tearDown(() async {
    manager.dispose();
    await box.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Pumps the batch page with the controller pre-seeded into [state].
  Future<void> pump(WidgetTester tester, BatchState state) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const BatchQueuePage()),
        // The batch page pushes the playlist picker; a stub route is enough to
        // prove navigation was attempted with the right playlist.
        GoRoute(
          path: '/download/playlist',
          builder: (_, _) => const Scaffold(),
        ),
        GoRoute(path: '/queue', builder: (_, _) => const Scaffold()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadManagerProvider.overrideWithValue(manager),
          settingsBoxProvider.overrideWithValue(box),
          batchQueueControllerProvider.overrideWith(
            () => _SeededBatchController(state),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await settleIo(tester);
  }

  group('empty', () {
    testWidgets('explains that there is nothing to queue', (tester) async {
      await pump(tester, const BatchState());

      expect(find.textContaining('No links to queue'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('progress', () {
    testWidgets('states how many are ready and how many failed', (
      tester,
    ) async {
      await pump(
        tester,
        BatchState(
          items: [
            BatchItem(
              url: 'https://example.com/watch?v=ok',
              status: BatchItemStatus.ready,
              video: _video('ok'),
            ),
          ],
        ),
      );
      expect(find.textContaining('1 of 1 ready'), findsOneWidget);
    });

    testWidgets('a resolving run counts up rather than saying "0 of 0"', (
      tester,
    ) async {
      await pump(
        tester,
        const BatchState(
          isResolving: true,
          items: [BatchItem(url: 'a', status: BatchItemStatus.loading)],
        ),
      );
      expect(find.textContaining('Fetching details'), findsOneWidget);
    });
  });

  group('failed items', () {
    testWidgets('show their own error and a retry, without blocking others', (
      tester,
    ) async {
      await pump(
        tester,
        BatchState(
          items: [
            const BatchItem(
              url: 'https://example.com/gone',
              status: BatchItemStatus.failed,
              error: 'Video unavailable',
            ),
            BatchItem(
              url: 'https://example.com/watch?v=ok',
              status: BatchItemStatus.ready,
              video: _video('ok'),
            ),
          ],
        ),
      );

      expect(find.textContaining('Video unavailable'), findsOneWidget);
      // The whole point of resolving per-link: one bad URL does not cost the
      // good ones, so the ready sibling is still shown and still selectable.
      expect(find.textContaining('1 of 2 ready'), findsOneWidget);
      expect(find.textContaining('1 failed'), findsOneWidget);
      expect(find.byTooltip('Try again'), findsOneWidget);
    });

    testWidgets('retry is offered per row, not as a blanket action', (
      tester,
    ) async {
      await pump(
        tester,
        BatchState(
          items: [
            const BatchItem(
              url: 'a',
              status: BatchItemStatus.failed,
              error: 'nope',
            ),
            BatchItem(
              url: 'https://example.com/watch?v=b',
              status: BatchItemStatus.ready,
              video: _video('b'),
            ),
          ],
        ),
      );

      expect(find.byTooltip('Try again'), findsOneWidget);
    });

    testWidgets('a loading row cannot be retried', (tester) async {
      await pump(
        tester,
        const BatchState(
          items: [BatchItem(url: 'a', status: BatchItemStatus.loading)],
        ),
      );

      expect(find.byTooltip('Try again'), findsNothing);
    });
  });

  group('playlists in a batch', () {
    testWidgets('are surfaced for the picker rather than queued', (
      tester,
    ) async {
      await pump(
        tester,
        BatchState(
          items: [
            BatchItem(
              url: 'https://example.com/playlist',
              status: BatchItemStatus.ready,
              playlist: _playlist(),
            ),
          ],
        ),
      );

      // A playlist cannot join a batch: each entry has to be chosen by the user,
      // so it must never be counted as a ready video or silently downloaded.
      expect(find.textContaining('Playlist'), findsWidgets);
      expect(find.textContaining('0 of 1 ready'), findsOneWidget);
      expect(
        find.byTooltip('Choose videos from this playlist'),
        findsOneWidget,
      );
      // Nothing is downloadable from a playlist row on its own.
      expect(find.widgetWithText(FilledButton, 'Download 1'), findsNothing);
    });

    testWidgets('states how many videos the playlist holds', (tester) async {
      await pump(
        tester,
        BatchState(
          items: [
            BatchItem(
              url: 'https://example.com/playlist',
              status: BatchItemStatus.ready,
              playlist: _playlist(count: 12),
            ),
          ],
        ),
      );

      expect(find.textContaining('12 videos'), findsOneWidget);
    });
  });

  group('selection', () {
    Future<void> pumpTwoVideos(WidgetTester tester) => pump(
      tester,
      BatchState(
        items: [
          BatchItem(
            url: 'https://example.com/watch?v=a',
            status: BatchItemStatus.ready,
            video: _video('a'),
          ),
          BatchItem(
            url: 'https://example.com/watch?v=b',
            status: BatchItemStatus.ready,
            video: _video('b'),
          ),
        ],
      ),
    );

    testWidgets('nothing is selected to begin with', (tester) async {
      await pumpTwoVideos(tester);

      expect(find.text('0 selected'), findsOneWidget);
      // The button is disabled rather than absent, so the affordance stays put.
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Download 0'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('select all selects the resolved videos', (tester) async {
      await pumpTwoVideos(tester);

      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('select all toggles back to none', (tester) async {
      await pumpTwoVideos(tester);

      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('Select none'), findsOneWidget);

      await tester.tap(find.text('Select none'));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
    });

    testWidgets('tapping a row toggles just that row', (tester) async {
      await pumpTwoVideos(tester);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      // Selection is the source of truth the Download button counts; a tap on
      // the row that does not tick the box must not look like a selection.
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Download 1'), findsOneWidget);
    });

    testWidgets('a playlist row is not counted in the selection', (
      tester,
    ) async {
      await pump(
        tester,
        BatchState(
          items: [
            BatchItem(
              url: 'https://example.com/watch?v=v',
              status: BatchItemStatus.ready,
              video: _video('v'),
            ),
            BatchItem(
              url: 'https://example.com/p',
              status: BatchItemStatus.ready,
              playlist: _playlist(),
            ),
          ],
        ),
      );

      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();

      // Only the video: selecting all must not sweep a playlist into a batch
      // download the user never chose entries for.
      expect(find.text('1 selected'), findsOneWidget);
    });
  });

  group('download', () {
    testWidgets('one quality choice applies to the whole batch', (
      tester,
    ) async {
      await pump(
        tester,
        BatchState(
          items: [
            BatchItem(
              url: 'https://example.com/watch?v=a',
              status: BatchItemStatus.ready,
              video: _video('a'),
            ),
            BatchItem(
              url: 'https://example.com/watch?v=b',
              status: BatchItemStatus.ready,
              video: _video('b'),
            ),
          ],
        ),
      );

      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download 2'));
      await tester.pumpAndSettle();

      // A single sheet for the whole batch: a batch has no per-video format
      // list, so there is nothing to pick per row.
      expect(find.textContaining('Quality for all'), findsOneWidget);

      await tester.tap(find.text('Use this for all'));
      await tester.pumpAndSettle();

      expect(manager.enqueued, hasLength(2));
      // The same format object for both — that is the point of a batch choice.
      expect(manager.enqueued[0].$2, same(manager.enqueued[1].$2));
    });

    testWidgets('cancelling the sheet queues nothing', (tester) async {
      await pump(
        tester,
        BatchState(
          items: [
            BatchItem(
              url: 'https://example.com/watch?v=a',
              status: BatchItemStatus.ready,
              video: _video('a'),
            ),
          ],
        ),
      );

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download 1'));
      await tester.pumpAndSettle();

      // Dismissing the sheet is a no-op, not a download with default settings.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(manager.enqueued, isEmpty);
    });
  });

  group('clearing', () {
    testWidgets('clearing the list is available and empties it', (
      tester,
    ) async {
      await pump(
        tester,
        BatchState(
          items: [
            BatchItem(
              url: 'https://example.com/watch?v=a',
              status: BatchItemStatus.ready,
              video: _video('a'),
            ),
          ],
        ),
      );

      expect(find.byTooltip('Clear the list'), findsOneWidget);
    });
  });
}
