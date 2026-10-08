import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/collection_kind.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/playlist_paging.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/core/router/app_router.dart';
import 'package:ytdlp/features/playlist/playlist_page.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

/// A channel too large to arrive at once, built as one slice of a listing.
///
/// [start] is the 1-based index of the first entry, so a resumed slice yields
/// the entries that index implies rather than an arbitrary set.
PlaylistInfo _channel({int listed = 3, int? totalCount, int start = 1}) =>
    PlaylistInfo(
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

/// Serves "load more" slices from a list without spawning a process, and counts
/// the requests so a test can prove a page was not fetched twice.
class _SlicedService extends YtdlpService {
  _SlicedService() : super(BinaryManager());

  final List<PlaylistInfo> slices = [];
  final List<int> sliceStarts = [];

  @override
  Future<PlaylistInfo> fetchPlaylistSlice({
    required String url,
    required int start,
    required bool hasFfmpeg,
    required bool canPostprocess,
  }) async {
    sliceStarts.add(start);
    if (slices.isEmpty) throw StateError('no slice queued for start $start');
    return slices.length == 1 ? slices.first : slices.removeAt(0);
  }
}

/// The playlist route carries the collection in `extra`, so it has to degrade
/// gracefully when that payload is missing — a restored deep link, or a hot
/// restart, can land on the route with no playlist to show.
void main() {
  late Directory tempRoot;
  late Box<dynamic> settingsBox;
  late Box<dynamic> historyBox;
  late Box<dynamic> queueBox;
  late _SlicedService service;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-router-');
    Hive.init(tempRoot.path);
    settingsBox = await Hive.openBox<dynamic>('router-settings');
    historyBox = await Hive.openBox<dynamic>('router-history');
    queueBox = await Hive.openBox<dynamic>('router-queue');
    service = _SlicedService();
  });

  tearDown(() async {
    // Bounded closes: `DownloadManager.dispose` fires an `unawaited` write to
    // the queue box, and inside `testWidgets` — which runs in a fake-async zone
    // — `close()` waits on that write forever. The boxes are per-test temp
    // files that `deleteSync` removes either way, so a write that never settles
    // must not be able to hang the suite.
    Future<void> closeBox(Box<dynamic> b) =>
        b.close().timeout(const Duration(seconds: 5), onTimeout: () {});

    await closeBox(settingsBox);
    await closeBox(historyBox);
    await closeBox(queueBox);
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpRouter(
    WidgetTester tester, {
    required String initialLocation,
    Object? extra,
    double height = 1200,
  }) async {
    tester.view.physicalSize = Size(500, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // appRouter is a process-wide singleton (lib/core/router/app_router.dart),
    // so it is deliberately not disposed here; each test just navigates it.
    final router = appRouter;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsBoxProvider.overrideWithValue(settingsBox),
          historyBoxProvider.overrideWithValue(historyBox),
          queueBoxProvider.overrideWithValue(queueBox),
          ytdlpServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    if (extra != null) {
      router.go(initialLocation, extra: extra);
    } else {
      router.go(initialLocation);
    }
    await tester.pumpAndSettle();
  }

  final playlist = PlaylistInfo(
    id: 'PL1',
    title: 'Road Trip',
    webUrl: 'https://example.com/playlist?list=PL1',
    entries: [
      VideoInfo(
        id: 'v0',
        title: 'Clip 0',
        webUrl: 'https://example.com/watch?v=v0',
        duration: 60,
      ),
    ],
  );

  testWidgets('the playlist route builds the picker from extra', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      initialLocation: '/download/playlist',
      extra: playlist,
    );

    expect(find.byType(PlaylistPage), findsOneWidget);
    expect(find.text('Road Trip'), findsOneWidget);
    // The header joins count · uploader · duration, so match on the fragment.
    expect(find.textContaining('1 video'), findsOneWidget);
    expect(find.text('Clip 0'), findsOneWidget);
  });

  testWidgets('a missing extra explains itself instead of crashing', (
    tester,
  ) async {
    await pumpRouter(tester, initialLocation: '/download/playlist');

    expect(find.byType(PlaylistPage), findsNothing);
    expect(find.text('That playlist is no longer loaded'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Back to Download'),
      findsOneWidget,
    );
  });

  testWidgets('an unknown path says so in the app, not in go_router', (
    tester,
  ) async {
    // Reachable in practice: an Android share intent or deep link carrying a
    // path the app does not have. Without an errorBuilder that renders as
    // go_router's own page, in whatever locale it happens to pick.
    await pumpRouter(tester, initialLocation: '/nope');

    expect(
      find.text('That link does not open anywhere in this app'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(FilledButton, 'Back to Download'),
      findsOneWidget,
    );
  });

  group('leaving the picker and coming back', () {
    // A large channel is listed a page at a time, so losing that listing on a
    // tab switch would mean re-fetching hundreds of entries to show what the
    // user was already looking at. The shell keeps each branch's navigator
    // alive, but that is only worth anything if the page's own state survives
    // with it — which is what these tests pin.

    testWidgets('the selection and the loaded pages are still there', (
      tester,
    ) async {
      service.slices.add(_channel(listed: 2, start: 4));
      await pumpRouter(
        tester,
        initialLocation: '/download/playlist',
        extra: _channel(listed: 3, totalCount: 5),
        height: 2200,
      );

      // Deselect one and load another page, so both kinds of state exist to be
      // lost: a selection the user made and entries they paid a fetch for.
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Clip 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
      await tester.pumpAndSettle();
      expect(find.text('4 selected'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.queue_music_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistPage), findsNothing);

      // The Download destination is unselected while the Queue tab is showing,
      // so it carries the outlined icon at this point.
      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pumpAndSettle();

      expect(find.byType(PlaylistPage), findsOneWidget);
      expect(find.text('4 selected'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Clip 1'),
            )
            .value,
        isFalse,
      );
      // The second page is still listed...
      expect(find.widgetWithText(CheckboxListTile, 'Clip 4'), findsOneWidget);
      // ...and was not fetched a second time to put it back.
      expect(service.sliceStarts, [4]);
    });
  });
}
