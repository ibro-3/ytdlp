import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/collection_kind.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/playlist_paging.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/home/home_page.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

VideoInfo _video(String url) => VideoInfo(
  id: 'abc123',
  title: 'Pasted video',
  webUrl: url,
  videoFormats: const [
    Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
  ],
);

PlaylistInfo _playlist() => PlaylistInfo(
  id: 'PL1',
  title: 'Road Trip',
  webUrl: 'https://example.com/playlist?list=PL1',
  uploader: 'Some Channel',
  entries: [
    for (var i = 0; i < 3; i++)
      VideoInfo(
        id: 'v$i',
        title: 'Clip $i',
        webUrl: 'https://example.com/watch?v=v$i',
        duration: 60 * (i + 1),
      ),
  ],
);

/// A channel big enough to have been listed only in part, which is what a
/// large one really looks like on arrival.
PlaylistInfo _channel({
  int listed = PlaylistPaging.sliceSize,
  int? totalCount,
}) => PlaylistInfo(
  id: 'UC1',
  title: 'Deep Archive',
  webUrl: 'https://www.youtube.com/@deeparchive/videos',
  kind: CollectionKind.channel,
  uploader: 'Deep Archive',
  entries: [
    for (var i = 0; i < listed; i++)
      VideoInfo(
        id: 'v$i',
        title: 'Clip $i',
        webUrl: 'https://www.youtube.com/watch?v=v$i',
        duration: 60,
      ),
  ],
  paging: PlaylistPaging(fetched: listed, totalCount: totalCount),
);

/// Stands in for the real engine so the test never spawns a process or
/// touches the network.
class _FakeYtdlpService extends YtdlpService {
  _FakeYtdlpService() : super(BinaryManager());

  final List<String> fetched = [];

  /// When set, [fetch] resolves to a playlist instead of a video.
  bool resolveAsPlaylist = false;

  /// What [fetch] resolves to when [resolveAsPlaylist] is set. Lets a test swap
  /// in a channel without touching the clipboard plumbing.
  PlaylistInfo playlistOverride = _playlist();

  @override
  Future<FetchResult> fetch(String url) async {
    fetched.add(url);
    return resolveAsPlaylist
        ? PlaylistResult(playlistOverride)
        : VideoResult(_video(url));
  }
}

void _mockClipboard(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return text == null ? null : <String, dynamic>{'text': text};
        }
        return null;
      });
}

void main() {
  late _FakeYtdlpService service;

  setUp(() {
    service = _FakeYtdlpService();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [ytdlpServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a clipboard paste button', (tester) async {
    _mockClipboard('https://youtu.be/jNQXAC9IVRw');
    await pumpHome(tester);

    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byTooltip('Paste a link from the clipboard'), findsOneWidget);
  });

  testWidgets('pasting fills the field and fetches the video', (tester) async {
    _mockClipboard('  https://www.youtube.com/watch?v=abc123  ');
    await pumpHome(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(service.fetched, ['https://www.youtube.com/watch?v=abc123']);
    // The URL is in the input and the fetched video is on screen.
    expect(find.text('Pasted video'), findsOneWidget);
  });

  testWidgets('pasting pulls a link out of shared text', (tester) async {
    _mockClipboard('watch this https://youtu.be/xyz later');
    await pumpHome(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(service.fetched, ['https://youtu.be/xyz']);
  });

  testWidgets('an empty clipboard reports instead of fetching', (tester) async {
    _mockClipboard(null);
    await pumpHome(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(service.fetched, isEmpty);
    expect(find.text('No link found in the clipboard'), findsOneWidget);
  });

  testWidgets('clipboard text without a link is rejected', (tester) async {
    _mockClipboard('just some text, no link here');
    await pumpHome(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(service.fetched, isEmpty);
    expect(find.text('No link found in the clipboard'), findsOneWidget);
  });

  group('playlist links', () {
    setUp(() => service.resolveAsPlaylist = true);

    testWidgets('a playlist link shows a summary, not the format button', (
      tester,
    ) async {
      _mockClipboard('https://example.com/playlist?list=PL1');
      await pumpHome(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // The playlist's own identity and size, not a single video card.
      expect(find.text('Road Trip'), findsOneWidget);
      expect(find.text('3 videos'), findsOneWidget);
      expect(find.text('Some Channel'), findsOneWidget);
      // 60 + 120 + 180 seconds.
      expect(find.text('6 min'), findsOneWidget);
      // The single-video download button must not be offered.
      expect(find.widgetWithText(FilledButton, 'Download'), findsNothing);
      expect(
        find.widgetWithText(FilledButton, 'Choose videos'),
        findsOneWidget,
      );
    });

    testWidgets('a playlist does not claim to be only partly loaded', (
      tester,
    ) async {
      // A curated playlist that fitted in one response is the whole thing, so
      // no truncation wording may appear.
      _mockClipboard('https://example.com/playlist?list=PL1');
      await pumpHome(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.textContaining('Showing the first'), findsNothing);
      expect(find.textContaining('so far'), findsNothing);
    });
  });

  group('channel links', () {
    setUp(() {
      service.resolveAsPlaylist = true;
      service.playlistOverride = _channel(totalCount: 5000);
    });

    testWidgets('a channel gets its own card state and shortcut', (
      tester,
    ) async {
      _mockClipboard('https://www.youtube.com/@deeparchive/videos');
      await pumpHome(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Deep Archive'), findsOneWidget);
      // The channel shortcut the plan asks for, distinct from the playlist's
      // "Choose videos".
      expect(
        find.widgetWithText(FilledButton, 'Download everything'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Choose videos'), findsNothing);
      // The uploader is the channel, so repeating it as a chip is noise.
      expect(find.widgetWithText(Chip, 'Deep Archive'), findsNothing);
    });

    testWidgets('a partly-listed channel says so instead of claiming a size', (
      tester,
    ) async {
      _mockClipboard('https://www.youtube.com/@deeparchive/videos');
      await pumpHome(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // The truncation has to be visible here, before the picker, because this
      // is the screen where the user decides whether to go in.
      expect(find.text('Showing the first 200 of 5000'), findsOneWidget);
    });

    testWidgets('an unknown channel size does not get a made-up total', (
      tester,
    ) async {
      service.playlistOverride = _channel();
      _mockClipboard('https://www.youtube.com/@deeparchive/videos');
      await pumpHome(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.textContaining('of 5000'), findsNothing);
      // Says how much is loaded rather than claiming that is all of it.
      expect(find.text('200 videos so far'), findsOneWidget);
    });
  });
}
