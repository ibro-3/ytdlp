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

VideoInfo _video({
  List<Format> videoFormats = const [_best, _p720, _p360],
  List<Format> audioFormats = const [_audio],
}) => VideoInfo(
  id: 'abc123',
  title: 'Sample video',
  webUrl: 'https://example.com/watch?v=abc123',
  videoFormats: videoFormats,
  audioFormats: audioFormats,
);

/// Holds the sheet's result so tests can assert on it after the sheet closes.
class _Result {
  Format? picked;
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
    expect(result.picked?.selector, _p720.selector);
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
    expect(result.picked?.selector, _best.selector);
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
    expect(result.picked?.selector, _p360.selector);
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
    expect(result.picked?.kind, FormatKind.audio);
    expect(result.picked?.selector, _audio.selector);
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
}
