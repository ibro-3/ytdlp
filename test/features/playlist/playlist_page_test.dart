import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/collection_kind.dart';
import 'package:ytdlp/core/models/download_options.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/playlist_paging.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/playlist/playlist_page.dart';
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

PlaylistInfo _playlist({
  int count = 5,
  String title = 'Road Trip',
  bool canPostprocess = true,
  String prefix = 'Clip',
}) => PlaylistInfo(
  id: 'PL1',
  title: title,
  webUrl: 'https://example.com/playlist?list=PL1',
  uploader: 'Some Channel',
  hasFfmpeg: true,
  canPostprocess: canPostprocess,
  entries: [
    for (var i = 0; i < count; i++)
      VideoInfo(
        id: 'v$i',
        title: '$prefix $i',
        webUrl: 'https://example.com/watch?v=v$i',
        duration: 60,
      ),
  ],
);

/// A channel big enough to have arrived only in part.
///
/// [listed] is how many entries the payload carries, and [start] is the
/// 1-based index of the first of them — so a slice fetched from index 4 yields
/// `v3` and `v4`, exactly as a real resumed request would. That coupling is
/// what makes the merge assertions meaningful rather than arithmetic on
/// arbitrary numbers.
PlaylistInfo _channel({
  int listed = PlaylistPaging.sliceSize,
  int? totalCount,
  int start = 1,
}) => PlaylistInfo(
  id: 'UC1',
  title: 'Deep Archive',
  webUrl: 'https://www.youtube.com/@deeparchive/videos',
  kind: CollectionKind.channel,
  uploader: 'Deep Archive',
  entries: [
    for (var i = 0; i < listed; i++)
      VideoInfo(
        id: 'v${start - 1 + i}',
        title: 'Clip ${start - 1 + i}',
        webUrl: 'https://www.youtube.com/watch?v=v${start - 1 + i}',
        duration: 60,
      ),
  ],
  paging: PlaylistPaging(
    startedAt: start,
    fetched: listed,
    totalCount: totalCount,
  ),
);

/// Records enqueues without spawning a process.
class _RecordingManager extends DownloadManager {
  _RecordingManager(HistoryService history, Directory dir)
    : super(
        ytdlp: YtdlpService(BinaryManager()),
        history: history,
        downloadsDir: () async => dir,
      );

  final List<PlaylistInfo> playlists = [];
  final List<List<VideoInfo>> selections = [];
  final List<Format> formats = [];
  final List<DownloadOptions> options = [];

  @override
  List<DownloadTask> enqueuePlaylist({
    required PlaylistInfo playlist,
    required List<VideoInfo> selected,
    required Format format,
    DownloadOptions options = const DownloadOptions(),
  }) {
    playlists.add(playlist);
    selections.add(selected);
    formats.add(format);
    this.options.add(options);
    return const [];
  }
}

/// Serves "load more" slices from [slices] without spawning a process.
///
/// [slices] is consumed in order, so a test controls exactly what each resumed
/// request returns — including a duplicate or a short slice, which is what
/// makes the end-detection and de-duplication paths reachable.
class _SlicedService extends YtdlpService {
  _SlicedService() : super(BinaryManager());

  /// One entry per slice request; the last is reused once they run out so a
  /// stray second tap cannot fail the test for an unrelated reason.
  final List<PlaylistInfo> slices = [];

  /// Every `--playlist-start` the picker asked for, in order.
  final List<int> sliceStarts = [];

  /// When set, the next slice request throws this instead of returning.
  String? failure;

  @override
  Future<PlaylistInfo> fetchPlaylistSlice({
    required String url,
    required int start,
    required bool hasFfmpeg,
    required bool canPostprocess,
  }) async {
    sliceStarts.add(start);
    final error = failure;
    if (error != null) {
      failure = null;
      throw YtdlpException(error);
    }
    if (slices.isEmpty) {
      throw StateError('no slice queued for start $start');
    }
    return slices.length == 1 ? slices.first : slices.removeAt(0);
  }
}

void main() {
  late _RecordingManager manager;
  late _SlicedService service;
  late Directory tempRoot;
  late Box<dynamic> historyBox;
  late Box<dynamic> settingsBox;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-playlist-');
    Hive.init(tempRoot.path);
    historyBox = await Hive.openBox<dynamic>('playlist-test-history');
    // The page seeds its tier/option defaults from persisted settings, so the
    // real settings service needs a box.
    settingsBox = await Hive.openBox<dynamic>('playlist-test-settings');
    final history = HistoryService(historyBox);
    manager = _RecordingManager(history, tempRoot);
    service = _SlicedService();
  });

  tearDown(() async {
    await historyBox.close();
    await settingsBox.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pump(
    WidgetTester tester,
    PlaylistInfo playlist, {
    AppSettings settings = const AppSettings(),
    double height = 1400,
  }) async {
    tester.view.physicalSize = Size(500, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Written to the box rather than overridden in the provider, so the page
    // seeds itself through the same path it uses in the app. `runAsync` because
    // a Hive write is real I/O, which the test's fake-async zone will not drive.
    await tester.runAsync(() async {
      await settingsBox.clear();
      await settingsBox.put('app_settings', settings.toMap());
    });
    // A real router, because submitting navigates to the queue tab. The picker
    // is built directly here; the `/download/playlist` route and its `extra`
    // handoff are covered by the router tests.
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => PlaylistPage(playlist: playlist),
        ),
        GoRoute(path: '/queue', builder: (context, state) => const SizedBox()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadManagerProvider.overrideWithValue(manager),
          settingsBoxProvider.overrideWithValue(settingsBox),
          ytdlpServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Row titles only, excluding the filter field, whose own text matches too.
  Finder rowTitle(String text) => find.widgetWithText(CheckboxListTile, text);

  group('selection', () {
    testWidgets('lists every entry and starts with all selected', (
      tester,
    ) async {
      await pump(tester, _playlist(count: 3));

      for (var i = 0; i < 3; i++) {
        expect(rowTitle('Clip $i'), findsOneWidget);
      }
      expect(find.text('3 selected'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Download 3'), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(3));
    });

    testWidgets('deselecting one updates the count and the button', (
      tester,
    ) async {
      await pump(tester, _playlist(count: 3));

      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Download 2'), findsOneWidget);
    });

    testWidgets('clearing every entry disables the download button', (
      tester,
    ) async {
      await pump(tester, _playlist(count: 2));

      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing selected'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Download 0'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('select-all in the app bar toggles every entry', (
      tester,
    ) async {
      await pump(tester, _playlist(count: 4));

      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('4 selected'), findsOneWidget);
    });

    testWidgets('filtering narrows the list and the select-all acts on it', (
      tester,
    ) async {
      await pump(tester, _playlist(count: 5, prefix: 'Clip'));

      await tester.enterText(find.byType(TextField), 'Clip 1');
      await tester.pumpAndSettle();

      expect(rowTitle('Clip 1'), findsOneWidget);
      expect(rowTitle('Clip 2'), findsNothing);
      expect(find.text('Showing 1 of 5'), findsOneWidget);

      // The hidden entries stay selected; only the visible one is cleared.
      await tester.tap(find.byTooltip('Clear selection'));
      await tester.pumpAndSettle();
      expect(find.text('4 selected'), findsOneWidget);
    });

    testWidgets('a filter with no matches says so', (tester) async {
      await pump(tester, _playlist(count: 3));

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();

      expect(find.text('No videos match that filter'), findsOneWidget);
    });
  });

  group('download', () {
    testWidgets('enqueues the selected entries as one playlist group', (
      tester,
    ) async {
      final playlist = _playlist(count: 4);
      await pump(tester, playlist);

      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download 3'));
      await tester.pumpAndSettle();

      expect(manager.playlists.single, playlist);
      // Playlist order, not tap order.
      expect(manager.selections.single.map((e) => e.id), ['v1', 'v2', 'v3']);
    });

    testWidgets('passes the chosen video quality through', (tester) async {
      await pump(tester, _playlist(count: 2));

      await tester.tap(find.widgetWithText(ChoiceChip, '720 p'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download 2'));
      await tester.pumpAndSettle();

      final format = manager.formats.single;
      expect(format.kind, FormatKind.video);
      expect(format.tier, 720);
      expect(format.selector, 'bv*[height<=720]+ba/b[height<=720]/b');
    });

    testWidgets('switching to audio uses the audio tier selectors', (
      tester,
    ) async {
      await pump(tester, _playlist(count: 2));

      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Medium'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Download 2'));
      await tester.pumpAndSettle();

      final format = manager.formats.single;
      expect(format.kind, FormatKind.audio);
      expect(format.selector, 'ba[ext=m4a][abr<=128]/ba[ext=m4a]');
    });

    testWidgets('embed subs is disabled without ffprobe', (tester) async {
      await pump(tester, _playlist(count: 1, canPostprocess: false));

      final embedSubs = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Embed subtitles'),
      );
      expect(embedSubs.onChanged, isNull);
    });

    testWidgets('embed subs is available with ffprobe', (tester) async {
      await pump(tester, _playlist(count: 1, canPostprocess: true));

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Embed subtitles'),
      );
      expect(tile.onChanged, isNotNull);
    });

    testWidgets('no thumbnail switch is offered, and cover art is derived', (
      tester,
    ) async {
      // A batch has no per-entry format data, so a toggle would only be
      // guessing. There is no caption either: the derived value (audio embeds,
      // video does not) is applied silently rather than explained on screen.
      await pump(tester, _playlist(count: 1, canPostprocess: true));
      expect(
        find.widgetWithText(SwitchListTile, 'Embed thumbnail'),
        findsNothing,
      );
      expect(
        find.widgetWithText(SwitchListTile, 'Save thumbnail .jpg'),
        findsNothing,
      );
      expect(find.textContaining('cover art'), findsNothing);
    });

    testWidgets('an audio batch embeds cover art', (tester) async {
      await pump(
        tester,
        _playlist(count: 1, canPostprocess: true),
        settings: const AppSettings(defaultAudioOnly: true),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Download 1'));
      await tester.pumpAndSettle();

      expect(manager.options.single.embedThumb, isTrue);
    });

    testWidgets('a video batch does not embed cover art', (tester) async {
      await pump(tester, _playlist(count: 1, canPostprocess: true));
      await tester.tap(find.widgetWithText(FilledButton, 'Download 1'));
      await tester.pumpAndSettle();

      expect(manager.options.single.embedThumb, isFalse);
    });
  });

  group('a channel too large to list at once', () {
    // Tall enough that every row of a five-entry channel is built. A ListView
    // only builds what is on screen, so asserting on a row that has not been
    // scrolled to would pass for the wrong reason — or fail for a reason that
    // has nothing to do with the code under test.
    const tall = 2200.0;

    testWidgets('says how much of it is actually shown', (tester) async {
      await pump(tester, _channel(listed: 3, totalCount: 5000), height: tall);

      // A 3-row list presented as "5000 videos" would be a lie the user cannot
      // detect, and a 3-row list presented as "3 videos" hides 4,997 videos
      // they cannot reach.
      expect(find.textContaining('3 videos'), findsOneWidget);
      expect(find.text('Showing the first 3 of 5000'), findsOneWidget);
    });

    testWidgets('names the collection as a channel, not a playlist', (
      tester,
    ) async {
      await pump(tester, _channel(listed: 3, totalCount: 5000), height: tall);

      expect(find.widgetWithText(AppBar, 'Channel'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Playlist'), findsNothing);
    });

    testWidgets('offers to load the rest', (tester) async {
      await pump(tester, _channel(listed: 3, totalCount: 5000), height: tall);

      expect(find.widgetWithText(OutlinedButton, 'Load more'), findsOneWidget);
    });

    testWidgets('a complete collection has no load-more row', (tester) async {
      // A curated playlist fits in one response, so a stray button would imply
      // there is more when there is not.
      await pump(tester, _playlist(count: 3), height: tall);

      expect(find.widgetWithText(OutlinedButton, 'Load more'), findsNothing);
      expect(find.textContaining('Showing the first'), findsNothing);
    });

    testWidgets('load more appends and keeps earlier entries selected', (
      tester,
    ) async {
      service.slices.add(_channel(listed: 2, start: 4));
      await pump(tester, _channel(listed: 3, totalCount: 5), height: tall);

      // Deselect one so the append can be seen not to re-select it.
      await tester.tap(rowTitle('Clip 1'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();

      expect(rowTitle('Clip 3'), findsOneWidget);
      expect(rowTitle('Clip 4'), findsOneWidget);
      // 3 loaded, one turned off, plus the 2 just appended.
      expect(find.text('4 selected'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(rowTitle('Clip 1')).value,
        isFalse,
        reason: 'appending must not re-select what the user turned off',
      );
      // The listing is now the whole collection, so the caveat goes away.
      expect(find.textContaining('Showing the first'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Load more'), findsNothing);
    });

    testWidgets('the next request resumes after the entries already fetched', (
      tester,
    ) async {
      service.slices.add(_channel(listed: 2, start: 4));
      await pump(tester, _channel(listed: 3, totalCount: 5), height: tall);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();

      // Resuming from the *listed* count (3) instead of the fetched one would
      // re-request an entry the user can already see.
      expect(service.sliceStarts, [4]);
    });

    testWidgets('an entry repeated by a slice is not listed twice', (
      tester,
    ) async {
      // yt-dlp can re-read a tab across slice boundaries and hand back an entry
      // that was already listed; showing it twice would queue it twice.
      service.slices.add(_channel(listed: 2, start: 3));
      await pump(tester, _channel(listed: 3, totalCount: 5), height: tall);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();

      expect(rowTitle('Clip 2'), findsOneWidget);
      expect(rowTitle('Clip 3'), findsOneWidget);
      // Three listed plus the one genuinely new entry.
      expect(find.text('4 selected'), findsOneWidget);
    });

    testWidgets('a failed load keeps the list and offers a retry', (
      tester,
    ) async {
      service.failure = 'The site is not responding.';
      await pump(tester, _channel(listed: 3, totalCount: 5000), height: tall);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();

      // The failure belongs to the button that caused it: a snackbar that has
      // already gone is no help after a long timeout, and the list is still
      // short, so the button has to stay.
      expect(find.text('The site is not responding.'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Load more'), findsOneWidget);
      expect(find.textContaining('3 videos'), findsOneWidget);
    });

    testWidgets('a retried load succeeds after a failure', (tester) async {
      service.failure = 'The site is not responding.';
      service.slices.add(_channel(listed: 2, start: 4));
      await pump(tester, _channel(listed: 3, totalCount: 5), height: tall);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();

      // A failed load must not leave a permanent error banner once a later
      // attempt works, or the collection looks permanently broken.
      expect(find.text('The site is not responding.'), findsNothing);
      expect(find.text('5 selected'), findsOneWidget);
    });

    testWidgets('downloads use the merged listing', (tester) async {
      service.slices.add(_channel(listed: 2, start: 4));
      await pump(tester, _channel(listed: 3, totalCount: 5), height: tall);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Download 5'));
      await tester.pumpAndSettle();

      expect(manager.selections.single, hasLength(5));
      // The folder name comes from the collection, so it must not depend on
      // which page the user happened to download from.
      expect(manager.playlists.single.title, 'Deep Archive');
      expect(manager.playlists.single.paging.fetched, 5);
    });

    testWidgets('the last page ends the offer rather than looping forever', (
      tester,
    ) async {
      // Built through the production parser, because the end-of-collection
      // signal is read there and nowhere else.
      PlaylistInfo parseChannel({required int listed, int start = 1}) =>
          PlaylistInfo.fromYtdlpJson(
            {
              'id': 'UC1',
              'title': 'Deep Archive',
              'playlist_count': 200,
              'entries': [
                for (var i = 0; i < listed; i++)
                  {
                    'id': 'v${start - 1 + i}',
                    'title': 'Clip ${start - 1 + i}',
                    'url': 'https://www.youtube.com/watch?v=v${start - 1 + i}',
                  },
              ],
            },
            hasFfmpeg: false,
            canPostprocess: false,
            requestedUrl: 'https://www.youtube.com/@deeparchive/videos',
            paging: PlaylistPaging(startedAt: start),
          );

      service.slices.add(parseChannel(listed: 0, start: 3));
      await pump(tester, parseChannel(listed: 2));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();

      // The site said 200 entries, so the cursor arithmetic on its own would
      // keep asking: the cursor sits at 3, nowhere near 200, and a page that
      // returns nothing cannot move it. A button left in place would fetch the
      // same missing page for as long as the user cared to press it.
      expect(find.widgetWithText(OutlinedButton, 'Load more'), findsNothing);
      expect(find.textContaining('Showing the first'), findsNothing);
      expect(service.sliceStarts, [3]);
    });
  });
}
