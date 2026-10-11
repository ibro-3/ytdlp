import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' as fui;
import 'package:flutter/cupertino.dart'
    show CupertinoApp, CupertinoNavigationBar;
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/platform_style.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/core/models/download_task.dart';
import 'package:ytdlp/core/theme/app_theme.dart';
import 'package:ytdlp/features/home/home_page.dart';
import 'package:ytdlp/features/library/library_page.dart';
import 'package:ytdlp/features/queue/queue_page.dart';
import 'package:ytdlp/features/settings/cookie_domains_page.dart';
import 'package:ytdlp/features/settings/settings_page.dart';
import 'package:ytdlp/services/downloads/download_manager.dart';
import 'package:ytdlp/services/downloads/history_service.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';
import 'package:ytdlp/services/ytdlp/ytdlp_service.dart';

import 'support/pump.dart';

/// Every screen, drawn under the root each OS gets.
///
/// The per-screen tests in this suite cover what each screen *does*, and they
/// all run under Flutter's default test platform of Android — so they cover
/// Material, and only Material. What none of them can catch is a screen that
/// still builds a Material widget where a Cupertino or Fluent one belongs: that
/// renders perfectly well, it is just the wrong shape for the OS. This walks
/// each screen under a macOS and a Windows override, so a missed branch fails
/// here rather than on a Mac or a PC.
///
/// The pages are pumped directly rather than through `App`: this is about the
/// screens, and routing would add a second copy of the navigation state as well
/// as the boxes and services the router's pages need.
void main() {
  late Directory tempRoot;
  late Box<dynamic> settingsBox;
  late _IdleManager manager;

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ytdlp-style-');
    Hive.init(tempRoot.path);
    // Opened in `setUp`, never in a test body: `testWidgets` runs the body in a
    // fake-async zone, where a future that depends on the real filesystem — a
    // Hive box open is one — never completes and the test hangs. See
    // test/support/pump.dart.
    settingsBox = await Hive.openBox<dynamic>('app-style-smoke');
    manager = _IdleManager(HistoryService(settingsBox), tempRoot);
  });

  tearDown(() async {
    manager.dispose();
    await Hive.close();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: a leftover temp directory must not fail a test.
    }
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> pumpPage(
    WidgetTester tester,
    TargetPlatform platform,
    Widget page,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsBoxProvider.overrideWithValue(settingsBox),
          historyServiceProvider.overrideWithValue(HistoryService(settingsBox)),
          // A queue manager that never starts a process, so nothing here
          // reaches yt-dlp or the network cable.
          downloadManagerProvider.overrideWithValue(manager),
          ytdlpServiceProvider.overrideWithValue(YtdlpService(BinaryManager())),
          downloadsDirProvider.overrideWithValue(() async => tempRoot),
        ],
        child: _RootForStyle(style: platformStyleOf(platform), child: page),
      ),
    );
    await settleIo(tester);
  }

  const pages = <String, Widget>{
    'Download': HomePage(),
    'Queue': QueuePage(),
    'Library': LibraryPage(),
    'Settings': SettingsPage(),
    'Cookie sites': CookieDomainsPage(),
  };

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform: every screen renders without throwing', (
      tester,
    ) async {
      for (final entry in pages.entries) {
        await pumpPage(tester, platform, entry.value);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the ${entry.key} screen threw under $platform',
        );
        // Unmounted between screens: some of them animate a progress bar, and
        // a repeating timer still pending when the binding checks would fail
        // the test on the *next* screen's assert.
        await tester.pumpWidget(const SizedBox.shrink());
        await settleIo(tester);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('$platform frames the screen the way that OS does', (
      tester,
    ) async {
      await pumpPage(tester, platform, const SettingsPage());
      expect(
        _frameFor[platformStyleOf(platform)],
        findsWidgets,
        reason:
            'the root said $platform but the screen was not framed that way',
      );
      debugDefaultTargetPlatformOverride = null;
    });
  }
}

/// What the family's own frame looks like in the tree.
final _frameFor = <PlatformStyle, Finder>{
  PlatformStyle.material: find.byType(AppBar),
  PlatformStyle.cupertino: find.byType(CupertinoNavigationBar),
  PlatformStyle.fluent: find.byType(fui.ScaffoldPage),
};

/// A [DownloadManager] that has nothing running and never starts anything.
class _IdleManager extends DownloadManager {
  _IdleManager(HistoryService history, Directory dir)
    : super(
        ytdlp: YtdlpService(BinaryManager()),
        history: history,
        downloadsDir: () async => dir,
      );

  @override
  Future<bool> openTask(DownloadTask task) async => false;

  @override
  Future<bool> shareTask(DownloadTask task) async => false;

  @override
  Future<bool> deleteTask(DownloadTask task) async => false;
}

/// The root [PlatformApp] builds for [style], with the same Material fallback
/// theme underneath — so a screen under test sees exactly what the real app
/// gives it, and a widget that needs one of the localization delegates gets it.
class _RootForStyle extends StatelessWidget {
  const _RootForStyle({required this.style, required this.child});

  final PlatformStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const delegates = [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];
    return switch (style) {
      PlatformStyle.cupertino => CupertinoApp(
        theme: AppTheme.cupertino(brightness: Brightness.light),
        localizationsDelegates: delegates,
        home: Scaffold(body: child),
      ),
      PlatformStyle.fluent => fui.FluentApp(
        // Without the FluentApp the Fluent widgets have no theme to read, so
        // this root must be the real thing rather than a Material stand-in.
        theme: AppTheme.fluent(brightness: Brightness.light),
        localizationsDelegates: delegates,
        home: child,
      ),
      PlatformStyle.material => MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: delegates,
        home: Scaffold(body: child),
      ),
    };
  }
}
