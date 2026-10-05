import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/features/home/widgets/video_info_card.dart';

VideoInfo _video({
  String? author,
  String? thumbnail,
  String? uploadDate,
  int duration = 60,
  List<Format> videoFormats = const [],
  List<Format> audioFormats = const [],
}) => VideoInfo(
  id: 'x',
  title: 'A song',
  webUrl: 'https://example.com/watch?v=x',
  author: author,
  thumbnail: thumbnail,
  duration: duration,
  uploadDate: uploadDate == null ? null : DateTime.parse(uploadDate),
  videoFormats: videoFormats,
  audioFormats: audioFormats,
);

void main() {
  group('VideoInfoCard', () {
    testWidgets('shows title and channel', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoInfoCard(video: _video(author: 'Someone')),
        ),
      );

      expect(find.text('A song'), findsOneWidget);
      expect(find.text('Someone'), findsOneWidget);
    });

    testWidgets('falls back to "Unknown channel" when no author', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: VideoInfoCard(video: _video())),
      );

      expect(find.text('Unknown channel'), findsOneWidget);
    });

    testWidgets(
      'shows a placeholder instead of an image when thumbnail missing',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: VideoInfoCard(video: _video())),
        );

        expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
        expect(find.byType(AspectRatio), findsOneWidget);
      },
    );

    testWidgets('shows duration when it is known', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: VideoInfoCard(video: _video(duration: 83))),
      );

      expect(find.text('1:23'), findsOneWidget);
    });

    testWidgets('hides the duration chip for live/unknown durations', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: VideoInfoCard(video: _video(duration: 0))),
      );

      expect(find.byIcon(Icons.schedule), findsNothing);
    });

    testWidgets('lists how many video formats and choices the card offers', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoInfoCard(
            video: _video(
              videoFormats: const [
                Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
                Format(kind: FormatKind.video, label: '480p', selector: 'w'),
              ],
              audioFormats: const [
                Format(kind: FormatKind.audio, label: 'M4A', selector: 'a'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('2 video options'), findsOneWidget);
    });
  });
}
