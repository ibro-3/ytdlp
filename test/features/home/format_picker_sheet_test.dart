import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/command_template.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/features/home/widgets/format_picker_sheet.dart';
import 'package:ytdlp/widgets/tab_carousel.dart';

const _best = Format(
  kind: FormatKind.video,
  label: 'Best quality',
  selector: 'bv*+ba/b',
  tier: 1080,
);
const _p720 = Format(
  kind: FormatKind.video,
  label: '720p',
  selector: 'bv*[height<=720]+ba/b[height<=720]/b',
  tier: 720,
);
const _p360 = Format(
  kind: FormatKind.video,
  label: '360p',
  selector: 'bv*[height<=360]+ba/b[height<=360]/b',
  tier: 360,
);
const _audio = Format(
  kind: FormatKind.audio,
  label: 'M4A · Best audio',
  selector: 'ba[ext=m4a]/ba',
);
const _audioMedium = Format(
  kind: FormatKind.audio,
  label: 'Medium · M4A · 128kbps',
  selector: 'ba[ext=m4a][abr<=128]/ba[ext=m4a]',
  tier: 128,
);
const _enSubs = SubtitleTrack(
  lang: 'en',
  name: 'English',
  isAutoOnly: false,
  exts: ['srt', 'vtt'],
);
const _autoDeSubs = SubtitleTrack(
  lang: 'de',
  name: 'German',
  isAutoOnly: true,
  exts: ['vtt'],
);

VideoInfo _video({
  List<Format> videoFormats = const [_best, _p720, _p360],
  List<Format> audioFormats = const [_audio],
  List<SubtitleTrack> subtitleTracks = const [],
  bool hasFfmpeg = false,
  bool? canPostprocess,
}) => VideoInfo(
  id: 'abc123',
  title: 'Sample video',
  webUrl: 'https://example.com/watch?v=abc123',
  videoFormats: videoFormats,
  audioFormats: audioFormats,
  subtitleTracks: subtitleTracks,
  hasFfmpeg: hasFfmpeg,
  canPostprocess: canPostprocess,
);

/// Holds the sheet's result so tests can assert on it after the sheet closes.
class _Result {
  FormatPickerResult? picked;
}

/// Pumps a button that opens the picker, then opens it.
Future<_Result> _openSheet(
  WidgetTester tester, {
  required VideoInfo video,
  AppSettings settings = const AppSettings(),
  List<CommandTemplate> templates = const [],
}) async {
  final result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result.picked = await showFormatPickerSheet(
                  context,
                  video: video,
                  settings: settings,
                  templates: templates,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

/// Brings the advanced carousel into view, since it sits below the quality
/// chips and subtitle switches in a scrolling sheet.
///
/// Scrolls the sheet's own scroll view rather than the whole page: the bottom
/// sheet is a draggable, and a page-level scroll does not move its content.
Future<void> _scrollToAdvanced(WidgetTester tester) async {
  await tester.dragUntilVisible(
    find.widgetWithText(Tab, 'Advanced'),
    find.byType(SingleChildScrollView).first,
    const Offset(0, -220),
  );
  await tester.pumpAndSettle();
}

/// Moves the carousel to the file name page.
///
/// A [PageView] only builds the page it is on, so the output template's field
/// does not exist until the tab is tapped. Every lookup is therefore scoped to
/// the visible page rather than indexing a list of both fields.
Future<void> _openFileNamePage(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(Tab, 'File name'));
  await tester.pumpAndSettle();
}

/// The one text field on whichever carousel page is up.
Finder get _visibleField => find.byType(TextField);

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(_visibleField).controller!.text;

Future<void> _enterField(WidgetTester tester, String text) async {
  await tester.enterText(_visibleField, text);
  await tester.pumpAndSettle();
}

Future<void> _tapDownload(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Download'));
  await tester.pumpAndSettle();
}

bool _chipSelected(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label)).selected;

void main() {
  testWidgets('shows the title, both segments, and the Download button', (
    tester,
  ) async {
    await _openSheet(tester, video: _video());

    expect(find.text('Sample video'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Quality'), findsOneWidget);
    expect(find.text('Best quality'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
  });

  testWidgets('Download returns the video format matching the saved tier', (
    tester,
  ) async {
    final result = await _openSheet(
      tester,
      video: _video(),
      settings: const AppSettings(defaultVideoTier: 720),
    );

    expect(_chipSelected(tester, '720p'), isTrue);

    await _tapDownload(tester);
    expect(result.picked?.format.selector, _p720.selector);
  });

  testWidgets('defaultVideoTier null falls back to Best quality', (
    tester,
  ) async {
    final result = await _openSheet(
      tester,
      video: _video(),
      settings: const AppSettings(defaultVideoTier: null),
    );

    expect(_chipSelected(tester, 'Best quality'), isTrue);

    await _tapDownload(tester);
    expect(result.picked?.format.selector, _best.selector);
  });

  testWidgets('tapping a quality chip changes the picked format', (
    tester,
  ) async {
    final result = await _openSheet(
      tester,
      video: _video(),
      settings: const AppSettings(defaultVideoTier: 720),
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '360p'));
    await tester.pumpAndSettle();
    expect(_chipSelected(tester, '360p'), isTrue);

    await _tapDownload(tester);
    expect(result.picked?.format.selector, _p360.selector);
  });

  testWidgets('switching to Audio downloads the audio format', (tester) async {
    final result = await _openSheet(
      tester,
      video: _video(),
      settings: const AppSettings(defaultVideoTier: 720),
    );

    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    expect(find.text('Audio quality'), findsOneWidget);

    await _tapDownload(tester);
    expect(result.picked?.format.kind, FormatKind.audio);
    expect(result.picked?.format.selector, _audio.selector);
  });

  testWidgets('defaultAudioOnly pre-selects Audio', (tester) async {
    await _openSheet(
      tester,
      video: _video(),
      settings: const AppSettings(defaultAudioOnly: true),
    );
    expect(find.text('Audio quality'), findsOneWidget);
  });

  testWidgets('no video streams: Video is disabled, Audio forced, hint shown', (
    tester,
  ) async {
    await _openSheet(
      tester,
      video: _video(videoFormats: const []),
      settings: const AppSettings(defaultVideoTier: 720),
    );

    // Audio mode is forced: there is nothing downloadable as video.
    expect(find.text('Audio quality'), findsOneWidget);
    expect(
      find.textContaining('No downloadable video streams'),
      findsOneWidget,
    );

    // Tapping the disabled Video segment must not switch modes.
    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();
    expect(find.text('Audio quality'), findsOneWidget);
  });

  testWidgets('no audio streams: the Audio segment does nothing', (
    tester,
  ) async {
    await _openSheet(
      tester,
      video: _video(audioFormats: const []),
      settings: const AppSettings(defaultVideoTier: 720),
    );

    expect(find.text('Quality'), findsOneWidget);
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    // Still in video mode because audio is unavailable.
    expect(find.text('Quality'), findsOneWidget);
  });

  testWidgets('dismissing the sheet returns null', (tester) async {
    final result = await _openSheet(tester, video: _video());

    // Tap the barrier above the sheet to dismiss it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(result.picked, isNull);
  });

  testWidgets('defaultAudioTier seeds the matching audio row', (tester) async {
    final result = await _openSheet(
      tester,
      video: _video(audioFormats: const [_audio, _audioMedium]),
      settings: const AppSettings(
        defaultAudioOnly: true,
        defaultAudioTier: 128,
      ),
    );
    await _tapDownload(tester);
    expect(result.picked?.format.selector, _audioMedium.selector);
  });

  testWidgets('settings seed the subtitle switches', (tester) async {
    await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs], hasFfmpeg: true),
      settings: const AppSettings(
        defaultWriteSubs: true,
        defaultEmbedSubs: true,
        defaultIncludeAutoSubs: true,
      ),
    );

    final write = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Save next to the file'),
    );
    final embed = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Embed in the file'),
    );
    final auto = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Include auto-generated'),
    );
    expect(write.value, isTrue);
    expect(embed.value, isTrue);
    expect(embed.onChanged, isNotNull);
    expect(auto.value, isTrue);
  });

  testWidgets('no thumbnail switch is offered in either mode', (tester) async {
    // Cover art is derived from the mode, so a toggle would be a lie: it could
    // only ever be turned off for video, which is already the derived value.
    await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs], hasFfmpeg: true),
    );

    expect(find.text('Thumbnail'), findsNothing);
    expect(find.text('Embed as cover art'), findsNothing);
    expect(find.text('Save .jpg next to the file'), findsNothing);

    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    expect(find.text('Embed as cover art'), findsNothing);
  });

  testWidgets('video mode does not embed cover art', (tester) async {
    final result = await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs], hasFfmpeg: true),
    );
    await _tapDownload(tester);

    expect(
      result.picked?.options.embedThumb,
      isFalse,
      reason: 'a video file has no use for an embedded cover',
    );
  });

  testWidgets('audio mode embeds cover art', (tester) async {
    final result = await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs], hasFfmpeg: true),
    );
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    await _tapDownload(tester);

    expect(
      result.picked?.options.embedThumb,
      isTrue,
      reason: 'a music player shows the album art',
    );
  });

  testWidgets('embed switches are forced off and disabled without ffmpeg', (
    tester,
  ) async {
    await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs]),
      settings: const AppSettings(defaultEmbedSubs: true),
    );

    final embed = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Embed in the file'),
    );
    expect(embed.value, isFalse, reason: 'seeding must not lie');
    expect(embed.onChanged, isNull, reason: 'no ffmpeg → cannot embed');
  });

  testWidgets(
    'embed switches are off when ffmpeg is present but ffprobe is not',
    (tester) async {
      // Merging works with ffmpeg alone, but postprocessing probes with
      // ffprobe. Offering the toggles here is what produced
      // "Postprocessing: ffprobe not found".
      await _openSheet(
        tester,
        video: _video(
          subtitleTracks: const [_enSubs],
          hasFfmpeg: true,
          canPostprocess: false,
        ),
        settings: const AppSettings(defaultEmbedSubs: true),
      );

      final embed = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Embed in the file'),
      );
      expect(embed.value, isFalse, reason: 'seeding must not lie');
      expect(embed.onChanged, isNull, reason: 'no ffprobe → cannot embed');
    },
  );

  testWidgets('audio mode reports embed subs off even if it was toggled', (
    tester,
  ) async {
    final result = await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs], hasFfmpeg: true),
    );

    await tester.tap(find.text('Embed in the file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    await _tapDownload(tester);

    expect(result.picked?.format.kind, FormatKind.audio);
    expect(result.picked?.options.embedSubs, isFalse);
  });

  testWidgets('picking a language narrows sub-langs; all is the default', (
    tester,
  ) async {
    final result = await _openSheet(
      tester,
      video: _video(
        subtitleTracks: const [_enSubs, _autoDeSubs],
        hasFfmpeg: true,
      ),
    );

    // Subtitles off by default → no language row yet.
    expect(find.text('All available'), findsNothing);

    await tester.tap(find.text('Save next to the file'));
    await tester.pumpAndSettle();
    // Default is "all available": the chip is selected, options say all.
    await tester.ensureVisible(find.text('All available'));
    await tester.pumpAndSettle();
    expect(find.text('All available'), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'All available'))
          .selected,
      isTrue,
    );

    await tester.ensureVisible(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'English'))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'All available'))
          .selected,
      isFalse,
    );

    await _tapDownload(tester);
    expect(result.picked?.options.writeSubs, isTrue);
    expect(result.picked?.options.subLanguages, ['en']);
  });

  testWidgets('auto-only languages are visibly marked', (tester) async {
    await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_autoDeSubs], hasFfmpeg: true),
    );
    await tester.tap(find.text('Save next to the file'));
    await tester.pumpAndSettle();
    expect(find.text('German (auto)'), findsOneWidget);
  });

  group('advanced: extra arguments', () {
    testWidgets('the field is seeded from the Settings default', (
      tester,
    ) async {
      await _openSheet(
        tester,
        video: _video(),
        settings: const AppSettings(extraArgs: '--concurrent-fragments 4'),
      );
      await _scrollToAdvanced(tester);

      expect(_fieldText(tester), '--concurrent-fragments 4');

      await _openFileNamePage(tester);
      expect(_fieldText(tester), isEmpty, reason: 'template starts unset');
    });

    testWidgets('the override comes back on the result', (tester) async {
      final result = await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);

      await _enterField(tester, '--embed-metadata');
      await _tapDownload(tester);

      expect(result.picked?.extraArgs, '--embed-metadata');
    });

    testWidgets('a managed flag warns but does not block', (tester) async {
      final result = await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);

      await _enterField(tester, '-o /elsewhere');

      expect(find.textContaining('is ignored'), findsOneWidget);
      await _tapDownload(tester);
      expect(
        result.picked,
        isNotNull,
        reason: 'a duplicate managed flag is a warning, not an error',
      );
    });

    testWidgets('a syntax error blocks the download', (tester) async {
      final result = await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);

      await _enterField(tester, "--a 'oops");

      expect(find.textContaining('never closed'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Download'),
      );
      expect(button.onPressed, isNull);
      expect(result.picked, isNull);
    });

    testWidgets('a template chip fills the field', (tester) async {
      await _openSheet(
        tester,
        video: _video(),
        templates: const [
          CommandTemplate(name: 'Sponsorblock', args: '--sponsorblock-remove'),
        ],
      );
      await _scrollToAdvanced(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Sponsorblock'));
      await tester.pumpAndSettle();

      expect(_fieldText(tester), '--sponsorblock-remove');
    });

    testWidgets('an empty template list is fine', (tester) async {
      final result = await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);
      await _tapDownload(tester);
      expect(result.picked, isNotNull);
    });
  });

  group('advanced: output template', () {
    testWidgets('an empty field falls back to the default for the download', (
      tester,
    ) async {
      final result = await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);
      await _openFileNamePage(tester);
      await _tapDownload(tester);

      // Empty means "use the Settings default", resolved at spawn time.
      expect(result.picked?.outputTemplate, isEmpty);
    });

    testWidgets('the preview renders the current field', (tester) async {
      await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);
      await _openFileNamePage(tester);

      await _enterField(tester, '%(title)s.%(ext)s');

      expect(find.textContaining('Saves as: Sample video.mp4'), findsOneWidget);
    });

    testWidgets('a template without an extension blocks the download', (
      tester,
    ) async {
      final result = await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);
      await _openFileNamePage(tester);

      await _enterField(tester, '%(title)s');

      // The error text, not the hint, is what mentions %(ext)s.
      expect(find.textContaining('sidecars'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Download'),
      );
      expect(button.onPressed, isNull);
      expect(result.picked, isNull);
    });

    testWidgets('a literal extension is accepted', (tester) async {
      final result = await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);
      await _openFileNamePage(tester);

      await _enterField(tester, '%(title)s.mp4');
      await _tapDownload(tester);

      expect(result.picked?.outputTemplate, '%(title)s.mp4');
    });
  });

  group('advanced carousel', () {
    testWidgets('both pages are reachable from the tab strip', (tester) async {
      await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);

      // The flags field is on the first page, the template on the second, and a
      // PageView only builds the page it is showing.
      expect(_fieldText(tester), isEmpty);
      expect(find.text('File name template'), findsNothing);

      await _openFileNamePage(tester);
      expect(find.text('File name template'), findsOneWidget);
    });

    testWidgets('a swipe moves to the file name page and the tab follows', (
      tester,
    ) async {
      await _openSheet(tester, video: _video());
      await _scrollToAdvanced(tester);

      // Dragged from a point that is actually on screen: the carousel sits at
      // the bottom of a scrolling sheet, so a centre-based drag can land off
      // the viewport and hit nothing at all. The distance is a fraction of the
      // measured width rather than a constant, because a page only turns past
      // half its width and the sheet is a different width per screen size.
      // Dragged from a point that is actually on screen: the carousel sits at
      // the bottom of a scrolling sheet, so a centre-based drag can land off
      // the viewport and hit nothing at all. Started near the top edge, above
      // the text field — a pan that begins inside a field is claimed by the
      // field's own gesture recogniser rather than the page. The distance is a
      // fraction of the measured width rather than a constant, because a page
      // only turns past half its width and the sheet is a different width on
      // every screen size.
      final rect = tester.getRect(find.byType(TabCarousel));
      await tester.dragFrom(
        rect.topLeft + Offset(rect.width * 0.8, 8),
        Offset(-rect.width * 0.7, 0),
      );
      await tester.pumpAndSettle();

      expect(find.text('File name template'), findsOneWidget);
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.controller!.index, 1, reason: 'strip tracks the swipe');
    });
  });
}
