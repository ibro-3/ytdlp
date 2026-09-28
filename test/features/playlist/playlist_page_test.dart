import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/download_options.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
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

void main() {
  late _RecordingManager manager;
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
  }) async {
    tester.view.physicalSize = const Size(500, 1400);
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
      await tester.tap(find.widgetWithText(ChoiceChip, '128 kbps'));
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
      // guessing; the derived value is stated instead.
      await pump(tester, _playlist(count: 1, canPostprocess: true));
      expect(
        find.widgetWithText(SwitchListTile, 'Embed thumbnail'),
        findsNothing,
      );
      expect(
        find.widgetWithText(SwitchListTile, 'Save thumbnail .jpg'),
        findsNothing,
      );
      expect(
        find.textContaining('not embedded in video files'),
        findsOneWidget,
      );
    });

    testWidgets('an audio batch embeds cover art', (tester) async {
      await pump(
        tester,
        _playlist(count: 1, canPostprocess: true),
        settings: const AppSettings(defaultAudioOnly: true),
      );
      expect(find.textContaining('embedded as cover art'), findsOneWidget);
    });

    testWidgets('a batch says so when cover art cannot be embedded', (
      tester,
    ) async {
      await pump(
        tester,
        _playlist(count: 1, canPostprocess: false),
        settings: const AppSettings(defaultAudioOnly: true),
      );
      expect(find.textContaining('Needs ffmpeg and ffprobe'), findsOneWidget);
    });
  });
}
