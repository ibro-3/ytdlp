import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/features/home/widgets/format_picker_sheet.dart';

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

  testWidgets('settings seed the subtitle and thumbnail switches', (
    tester,
  ) async {
    await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs], hasFfmpeg: true),
      settings: const AppSettings(
        defaultWriteSubs: true,
        defaultEmbedSubs: true,
        defaultIncludeAutoSubs: true,
        defaultEmbedThumb: true,
        defaultWriteThumb: true,
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
    final cover = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Embed as cover art'),
    );
    final jpg = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Save .jpg next to the file'),
    );
    expect(write.value, isTrue);
    expect(embed.value, isTrue);
    expect(embed.onChanged, isNotNull);
    expect(auto.value, isTrue);
    expect(cover.value, isTrue);
    expect(cover.onChanged, isNotNull);
    expect(jpg.value, isTrue);
  });

  testWidgets('embed switches are forced off and disabled without ffmpeg', (
    tester,
  ) async {
    await _openSheet(
      tester,
      video: _video(subtitleTracks: const [_enSubs]),
      settings: const AppSettings(
        defaultEmbedSubs: true,
        defaultEmbedThumb: true,
      ),
    );

    final embed = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Embed in the file'),
    );
    final cover = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Embed as cover art'),
    );
    expect(embed.value, isFalse, reason: 'seeding must not lie');
    expect(embed.onChanged, isNull, reason: 'no ffmpeg → cannot embed');
    expect(cover.value, isFalse);
    expect(cover.onChanged, isNull);
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
        settings: const AppSettings(
          defaultEmbedSubs: true,
          defaultEmbedThumb: true,
        ),
      );

      final embed = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Embed in the file'),
      );
      final cover = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Embed as cover art'),
      );
      expect(embed.value, isFalse, reason: 'seeding must not lie');
      expect(embed.onChanged, isNull, reason: 'no ffprobe → cannot embed');
      expect(cover.value, isFalse);
      expect(cover.onChanged, isNull);
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
}
