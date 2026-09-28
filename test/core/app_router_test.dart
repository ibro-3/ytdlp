import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/playlist_info.dart';
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/core/router/app_router.dart';
import 'package:ytdlp/features/playlist/playlist_page.dart';

/// The playlist route carries the collection in `extra`, so it has to degrade
/// gracefully when that payload is missing — a restored deep link, or a hot
/// restart, can land on the route with no playlist to show.
void main() {
  late Directory tempRoot;
  late Box<dynamic> settingsBox;
  late Box<dynamic> historyBox;
  late Box<dynamic> queueBox;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-router-');
    Hive.init(tempRoot.path);
    settingsBox = await Hive.openBox<dynamic>('router-settings');
    historyBox = await Hive.openBox<dynamic>('router-history');
    queueBox = await Hive.openBox<dynamic>('router-queue');
  });

  tearDown(() async {
    await settingsBox.close();
    await historyBox.close();
    await queueBox.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpRouter(
    WidgetTester tester, {
    required String initialLocation,
    Object? extra,
  }) async {
    tester.view.physicalSize = const Size(500, 1200);
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
}
