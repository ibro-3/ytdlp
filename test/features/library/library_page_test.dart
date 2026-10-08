import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ytdlp/core/models/download_record.dart';
import 'package:ytdlp/core/models/library_filter.dart';
import 'package:ytdlp/core/providers.dart';
import 'package:ytdlp/features/library/library_page.dart';
import 'package:ytdlp/services/downloads/history_service.dart';

import '../../support/pump.dart';

/// An in-memory [HistoryService] for the widget tests.
///
/// The real service writes to Hive, and a write *started* inside the fake-async
/// zone `testWidgets` installs never completes — its timer is scheduled in fake
/// time, so pumping frames and waiting in real time cannot rescue it, and the
/// test simply hangs. Substituting the service keeps these tests about the
/// page's behaviour; [HistoryService.clear]'s own Hive behaviour is covered by
/// the plain unit test at the bottom of this file, which has no fake zone.
class _StubHistory extends HistoryService {
  _StubHistory(super.box);

  final List<DownloadRecord> _local = [];

  int clearCalls = 0;

  @override
  List<DownloadRecord> get records => List.unmodifiable(_local);

  /// Adds without touching Hive, so a test body can seed freely.
  void seed(DownloadRecord record) {
    _local.insert(0, record);
    notifyListeners();
  }

  @override
  Future<void> add(DownloadRecord record) async {
    _local.insert(0, record);
    notifyListeners();
  }

  @override
  Future<void> remove(String id) async {
    _local.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    _local.clear();
    notifyListeners();
  }
}

/// A record backed by a real file, so the page's existence probe resolves to
/// "present" instead of flipping to "file missing" part-way through a test.
DownloadRecord _rec({
  required String id,
  required Directory dir,
  String? title,
  String? playlist,
  String? author,
  String ext = 'mp4',
  int size = 1000,
  DateTime? at,
  bool create = true,
}) => DownloadRecord(
  id: id,
  videoId: 'v$id',
  title: title ?? 'Title $id',
  author: author,
  thumbnail: null,
  filePath: create ? writeFile(dir, '$id.$ext') : '${dir.path}/$id.$ext',
  size: size,
  createdAt: at ?? DateTime(2026, 1, 1),
  playlistTitle: playlist,
);

/// The record titles currently rendered, in display order.
List<String> _titles(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.startsWith('Title '))
    .toList();

void main() {
  late Directory root;
  late Box<dynamic> box;
  late _StubHistory history;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('ytdlp-library-');
    Hive.init(root.path);
    box = await Hive.openBox<dynamic>('library-page');
    history = _StubHistory(box);
  });

  tearDown(() async {
    // Close before deleting: Hive keeps a .lock file in the box directory, so
    // removing it out from under an open box fails on the lock rather than on
    // anything meaningful.
    await box.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: a leftover temp directory must not fail a test.
    }
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          historyServiceProvider.overrideWithValue(history),
          // Without this the folder-scan action resolves the real download
          // directory through `path_provider`, which has no platform
          // implementation under `flutter test` and throws — surfacing as a
          // spurious "could not scan" banner.
          downloadsDirProvider.overrideWithValue(() async => root),
        ],
        child: const MaterialApp(home: LibraryPage()),
      ),
    );
    // The page stats every visible path on first build, so what it renders
    // depends on real I/O resolving before anything can be asserted about it.
    await settleIo(tester);
  }

  /// Opens the sort/filter/group popup menu and picks [label].
  ///
  /// Takes a label rather than an enum because the menu encodes each option as
  /// `kind:name` and resolves it back via `byName` — what the test needs to tap
  /// is the same string the user reads.
  Future<void> chooseViewOption(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Sort and group'));
    await tester.pumpAndSettle();
    // Taps the menu item rather than the Text inside it: a Text is not a
    // hit-test target, so tapping it warns that the hit landed on an
    // ancestor. The menu item is both the tappable thing and the thing
    // whose selection we are asserting.
    final item = find.ancestor(
      of: find.text(label).last,
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem<String>),
    );
    expect(item, findsOneWidget, reason: 'no menu item labelled "$label"');
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  group('empty library', () {
    testWidgets('explains itself instead of showing a bare list', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Library'), findsOneWidget);
      expect(find.textContaining('No downloads yet'), findsOneWidget);
    });

    testWidgets('offers no scan or clear action with nothing recorded', (
      tester,
    ) async {
      await pump(tester);
      // Both are gated on records.isNotEmpty. A scan against an empty library
      // would offer to adopt every file in the download folder at once, and
      // "Clear history" on an empty list is a misleading control.
      expect(find.byTooltip('Find files in the download folder'), findsNothing);
      expect(find.byTooltip('Clear history'), findsNothing);
    });
  });

  group('records', () {
    testWidgets('lists records with a running total', (tester) async {
      history.seed(_rec(id: 'a', dir: root));
      history.seed(_rec(id: 'b', dir: root, ext: 'm4a'));
      await pump(tester);

      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Title b'), findsOneWidget);
      // The total stays visible under every filter, so a filter that hides most
      // of the library reads as a filter rather than as data loss.
      expect(find.textContaining('2 downloads'), findsOneWidget);
    });

    testWidgets('newest first by default', (tester) async {
      history.seed(_rec(id: 'old', dir: root, at: DateTime(2020)));
      history.seed(_rec(id: 'new', dir: root, at: DateTime(2026, 6)));
      await pump(tester);

      expect(_titles(tester).first, 'Title new');
    });

    testWidgets('a file gone from disk is reported, not hidden', (
      tester,
    ) async {
      // create: false — a history entry whose file was deleted outside the app.
      history.seed(_rec(id: 'ghost', dir: root, create: false));
      await pump(tester);

      expect(find.text('Title ghost'), findsOneWidget);
      // Still listed, and labelled: the record is the user's history, and the
      // file being absent is the thing worth surfacing.
      expect(find.textContaining('file missing'), findsOneWidget);
    });

    testWidgets('a present file is not labelled missing', (tester) async {
      history.seed(_rec(id: 'here', dir: root));
      await pump(tester);
      expect(find.textContaining('file missing'), findsNothing);
    });

    testWidgets('each row offers its actions behind a menu', (tester) async {
      history.seed(_rec(id: 'a', dir: root));
      await pump(tester);

      // One per row, plus the app bar's sort/group menu.
      expect(find.byType(PopupMenuButton<String>), findsNWidgets(2));
    });
  });

  group('search', () {
    void seedCorpus() {
      history.seed(_rec(id: '1', dir: root, title: 'Zebra crossing'));
      history.seed(_rec(id: '2', dir: root, title: 'Apple pie'));
      history.seed(_rec(id: '3', dir: root, title: 'Mango jam'));
    }

    testWidgets('narrows the list and the total follows', (tester) async {
      seedCorpus();
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'apple');
      await tester.pumpAndSettle();

      expect(find.text('Apple pie'), findsOneWidget);
      expect(find.text('Zebra crossing'), findsNothing);
      expect(find.textContaining('1 download'), findsOneWidget);
    });

    testWidgets('matches the author as well as the title', (tester) async {
      history.seed(
        _rec(id: '1', dir: root, title: 'Untitled one', author: 'Alice'),
      );
      history.seed(
        _rec(id: '2', dir: root, title: 'Untitled two', author: 'Bob'),
      );
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'bob');
      await tester.pumpAndSettle();

      expect(find.text('Untitled two'), findsOneWidget);
      expect(find.text('Untitled one'), findsNothing);
    });

    testWidgets('matches the playlist name too', (tester) async {
      history.seed(_rec(id: '1', dir: root, playlist: 'Road Trip'));
      history.seed(_rec(id: '2', dir: root, playlist: 'Kitchen'));
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'road');
      await tester.pumpAndSettle();

      expect(find.text('Title 1'), findsOneWidget);
      expect(find.text('Title 2'), findsNothing);
    });

    testWidgets('is case-insensitive', (tester) async {
      seedCorpus();
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'ZEBRA');
      await tester.pumpAndSettle();

      expect(find.text('Zebra crossing'), findsOneWidget);
      expect(find.text('Apple pie'), findsNothing);
    });

    testWidgets('a query matching nothing says so and offers a way out', (
      tester,
    ) async {
      seedCorpus();
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();
      // The message names the query, so it cannot be mistaken for an empty
      // library — which shows "No downloads yet" instead.
      expect(find.text('Nothing matches "zzzz"'), findsOneWidget);
      expect(find.textContaining('No downloads yet'), findsNothing);

      await tester.tap(find.text('Clear search and filters'));
      await tester.pumpAndSettle();
      expect(find.text('Zebra crossing'), findsOneWidget);
    });

    testWidgets('clearing the query restores the list', (tester) async {
      seedCorpus();
      await pump(tester);

      await tester.enterText(find.byType(TextField), 'apple');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Clear search'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Zebra crossing'), findsOneWidget);
      expect(find.text('Mango jam'), findsOneWidget);
    });

    testWidgets('a filter with no query explains itself differently', (
      tester,
    ) async {
      history.seed(_rec(id: 'vid', dir: root, ext: 'mp4'));
      await pump(tester);

      await tester.tap(
        find.widgetWithText(ChoiceChip, LibraryFilter.audio.label),
      );
      await tester.pumpAndSettle();

      // No query, so quoting one would be misleading.
      expect(find.text('Nothing matches this filter'), findsOneWidget);
    });

    testWidgets('clear filters resets the chip as well as the text', (
      tester,
    ) async {
      history.seed(_rec(id: 'vid', dir: root, ext: 'mp4'));
      history.seed(_rec(id: 'aud', dir: root, ext: 'm4a'));
      await pump(tester);

      await tester.tap(
        find.widgetWithText(ChoiceChip, LibraryFilter.audio.label),
      );
      await tester.pumpAndSettle();
      expect(find.text('Title vid'), findsNothing);

      // Search for something that matches nothing *while* filtered to audio.
      // Resetting only the query would leave the user in an empty view with no
      // obvious way back, so the reset has to cover the chip too.
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear search and filters'));
      await tester.pumpAndSettle();

      expect(find.text('Title vid'), findsOneWidget);
      expect(find.text('Title aud'), findsOneWidget);
    });
  });

  group('filter chips', () {
    void seedMixed() {
      history.seed(_rec(id: 'vid', dir: root, ext: 'mp4'));
      history.seed(_rec(id: 'aud', dir: root, ext: 'm4a'));
    }

    testWidgets('audio hides video records', (tester) async {
      seedMixed();
      await pump(tester);

      await tester.tap(
        find.widgetWithText(ChoiceChip, LibraryFilter.audio.label),
      );
      await tester.pumpAndSettle();

      expect(find.text('Title aud'), findsOneWidget);
      expect(find.text('Title vid'), findsNothing);
    });

    testWidgets('video hides audio records', (tester) async {
      seedMixed();
      await pump(tester);

      await tester.tap(
        find.widgetWithText(ChoiceChip, LibraryFilter.video.label),
      );
      await tester.pumpAndSettle();

      expect(find.text('Title vid'), findsOneWidget);
      expect(find.text('Title aud'), findsNothing);
    });

    testWidgets('all shows both again', (tester) async {
      seedMixed();
      await pump(tester);

      await tester.tap(
        find.widgetWithText(ChoiceChip, LibraryFilter.audio.label),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(ChoiceChip, LibraryFilter.all.label),
      );
      await tester.pumpAndSettle();

      expect(find.text('Title vid'), findsOneWidget);
      expect(find.text('Title aud'), findsOneWidget);
    });

    testWidgets('every filter is offered as a chip', (tester) async {
      seedMixed();
      await pump(tester);

      for (final f in LibraryFilter.values) {
        expect(find.widgetWithText(ChoiceChip, f.label), findsOneWidget);
      }
    });
  });

  group('sort and grouping menu', () {
    testWidgets('largest puts the biggest file first', (tester) async {
      history.seed(_rec(id: 'small', dir: root, size: 10));
      history.seed(_rec(id: 'big', dir: root, size: 9000));
      await pump(tester);

      await chooseViewOption(tester, LibrarySort.largest.label);

      expect(_titles(tester).first, 'Title big');
    });

    testWidgets('title sorts alphabetically', (tester) async {
      history.seed(_rec(id: '1', dir: root, title: 'Title Zebra'));
      history.seed(_rec(id: '2', dir: root, title: 'Title Apple'));
      await pump(tester);

      await chooseViewOption(tester, LibrarySort.title.label);

      expect(_titles(tester).first, 'Title Apple');
    });

    testWidgets('oldest reverses the default order', (tester) async {
      history.seed(_rec(id: 'old', dir: root, at: DateTime(2020)));
      history.seed(_rec(id: 'new', dir: root, at: DateTime(2026, 6)));
      await pump(tester);

      await chooseViewOption(tester, LibrarySort.oldest.label);

      expect(_titles(tester).first, 'Title old');
    });

    testWidgets('grouping by playlist names each group and keeps loose items', (
      tester,
    ) async {
      history.seed(_rec(id: '1', dir: root, playlist: 'Road Trip'));
      history.seed(_rec(id: '2', dir: root, playlist: 'Road Trip'));
      history.seed(_rec(id: '3', dir: root, playlist: 'Kitchen'));
      history.seed(_rec(id: '4', dir: root));
      await pump(tester);

      await chooseViewOption(tester, LibraryGrouping.playlist.label);

      expect(find.textContaining('Road Trip'), findsWidgets);
      expect(find.textContaining('Kitchen'), findsWidgets);
      // A record with no playlist is still shown, not dropped by the grouping.
      expect(find.text('Title 4'), findsOneWidget);
      expect(_titles(tester), hasLength(4));
    });

    testWidgets('a group states its own count', (tester) async {
      history.seed(_rec(id: '1', dir: root, playlist: 'Road Trip'));
      history.seed(_rec(id: '2', dir: root, playlist: 'Road Trip'));
      await pump(tester);

      await chooseViewOption(tester, LibraryGrouping.playlist.label);

      // A group's header carries how many entries it holds, so an empty or
      // collapsed section cannot be mistaken for the whole library.
      expect(find.textContaining('2'), findsWidgets);
    });

    testWidgets('the menu offers every sort, filter and grouping option', (
      tester,
    ) async {
      history.seed(_rec(id: 'a', dir: root));
      await pump(tester);

      await tester.tap(find.byTooltip('Sort and group'));
      await tester.pumpAndSettle();

      for (final s in LibrarySort.values) {
        expect(find.text(s.label), findsWidgets);
      }
      for (final f in LibraryFilter.values) {
        expect(find.text(f.label), findsWidgets);
      }
      for (final g in LibraryGrouping.values) {
        expect(find.text(g.label), findsWidgets);
      }
    });
  });

  group('clear history', () {
    testWidgets('asks first, and cancelling keeps the records', (tester) async {
      history.seed(_rec(id: 'a', dir: root));
      await pump(tester);

      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      expect(find.text('Clear history?'), findsOneWidget);
      // The dialog says the files survive; assert it says so rather than
      // leaving the reassurance to be assumed.
      expect(find.textContaining('not deleted'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(history.clearCalls, 0);
      expect(history.records, hasLength(1));
      expect(find.text('Title a'), findsOneWidget);
    });

    testWidgets('confirming empties the list', (tester) async {
      history.seed(_rec(id: 'a', dir: root));
      history.seed(_rec(id: 'b', dir: root));
      await pump(tester);

      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();

      expect(history.clearCalls, 1);
      expect(history.records, isEmpty);
      expect(find.textContaining('No downloads yet'), findsOneWidget);
    });

    testWidgets('clearing history leaves the files on disk', (tester) async {
      final record = _rec(id: 'a', dir: root);
      history.seed(record);
      await pump(tester);

      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();

      // Clearing history resets the *list*. The dialog says the files are not
      // deleted, so it had better be true — otherwise this is the one control in
      // the app that destroys user data.
      expect(File(record.filePath).existsSync(), isTrue);
    });
  });

  group('folder scan', () {
    testWidgets('is offered once there is something to scan against', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byTooltip('Find files in the download folder'), findsNothing);

      history.seed(_rec(id: 'a', dir: root));
      await pump(tester);
      expect(
        find.byTooltip('Find files in the download folder'),
        findsOneWidget,
      );
    });

    testWidgets('a scan finding nothing leaves the library alone', (
      tester,
    ) async {
      history.seed(_rec(id: 'known', dir: root));
      await pump(tester);

      await tester.tap(find.byTooltip('Find files in the download folder'));
      await settleIo(tester);
      await tester.pumpAndSettle();

      // Adoption is explicit, so a scan must not mutate history on its own.
      expect(history.records, hasLength(1));
      // No banner: "not scanned" and "scanned, found nothing" are different
      // states and must not look the same.
      expect(find.textContaining('folder'), findsNothing);
    });
  });

  // The real service, with no fake-async zone to fight.
  group('HistoryService', () {
    test('clear empties the records and leaves the files alone', () async {
      final dir = Directory.systemTemp.createTempSync('ytdlp-history-');
      Hive.init(dir.path);
      final hive = await Hive.openBox<dynamic>('clear-test');
      final service = HistoryService(hive);

      final file = writeFile(dir, 'kept.mp4');
      await service.add(
        DownloadRecord(
          id: 'r1',
          videoId: 'v1',
          title: 'Kept',
          thumbnail: null,
          filePath: file,
          size: 1,
          createdAt: DateTime(2026),
        ),
      );
      expect(service.records, hasLength(1));

      await service.clear();

      expect(service.records, isEmpty);
      expect(File(file).existsSync(), isTrue);

      await hive.close();
      dir.deleteSync(recursive: true);
    });

    test('init reads back what was persisted, newest first', () async {
      final dir = Directory.systemTemp.createTempSync('ytdlp-history-');
      Hive.init(dir.path);
      final hive = await Hive.openBox<dynamic>('init-test');

      for (final entry in {
        'old': DateTime(2020),
        'new': DateTime(2026),
      }.entries) {
        await hive.put(entry.key, {
          'id': entry.key,
          'videoId': 'v-${entry.key}',
          'title': 'Title ${entry.key}',
          'thumbnail': null,
          'filePath': '/dl/${entry.key}.mp4',
          'size': 1,
          // Matches `toMap`, which stores milliseconds since epoch — a value
          // `fromMap` has to read back.
          'createdAt': entry.value.millisecondsSinceEpoch,
          'playlistTitle': null,
        });
      }

      final service = HistoryService(hive);
      service.init();

      expect(service.records.map((r) => r.id), [
        'new',
        'old',
      ], reason: 'a library restored from disk must open newest-first');

      await hive.close();
      dir.deleteSync(recursive: true);
    });

    test('one corrupt record does not take the library down', () async {
      // `init` runs inside a provider body at startup, so an unguarded cast here
      // meant a single bad entry in the box prevented the app from starting.
      final dir = Directory.systemTemp.createTempSync('ytdlp-history-');
      Hive.init(dir.path);
      final hive = await Hive.openBox<dynamic>('corrupt-test');

      await hive.put('good', {
        'id': 'good',
        'videoId': 'v1',
        'title': 'Readable',
        'thumbnail': null,
        'filePath': '/dl/good.mp4',
        'size': 1,
        'createdAt': DateTime(2026).millisecondsSinceEpoch,
        'playlistTitle': null,
      });
      // A value of the wrong shape entirely, which is what a hand-edited or
      // half-migrated box looks like.
      await hive.put('bad', 'not a record at all');

      final service = HistoryService(hive);
      service.init();

      expect(service.records.map((r) => r.id), [
        'good',
      ], reason: 'the readable record still loads');

      await hive.close();
      dir.deleteSync(recursive: true);
    });
  });
}
