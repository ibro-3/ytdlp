import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/home/home_page.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

/// Stands in for the real engine so the test never spawns a process or
/// touches the network.
class _FakeYtdlpService extends YtdlpService {
  _FakeYtdlpService() : super(BinaryManager());

  final List<String> fetched = [];

  @override
  Future<VideoInfo> fetchVideoInfo(String url) async {
    fetched.add(url);
    return VideoInfo(
      id: 'abc123',
      title: 'Pasted video',
      webUrl: url,
      videoFormats: const [
        Format(kind: FormatKind.video, label: 'Best', selector: 'b'),
      ],
    );
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
}
