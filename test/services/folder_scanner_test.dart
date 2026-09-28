import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ytdlp/services/downloads/folder_scanner.dart';

void main() {
  const scanner = FolderScanner();
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('ytdlp-scan-'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A default body comfortably over the scanner's size floor.
  final body4096 = 'x' * 4096;

  File write(String relPath, {String? content}) {
    final file = File(p.join(root.path, relPath))
      ..parent.createSync(recursive: true);
    file.writeAsStringSync(content ?? body4096);
    return file;
  }

  group('finding media', () {
    test('finds media at the top level and in subfolders', () async {
      write('Video/one.mp4');
      write('Audio/song.m4a');
      write('Video/Road Trip/two.mkv');

      final found = await scanner.scan(root: root);
      expect(found.map((f) => f.name).toSet(), {
        'one.mp4',
        'song.m4a',
        'two.mkv',
      });
    });

    test('ignores sidecars and other non-media', () async {
      write('Video/one.mp4');
      write('Video/one.en.srt');
      write('Video/one.jpg');
      write('Video/one.info.json');

      final found = await scanner.scan(root: root);
      expect(found.map((f) => f.name), ['one.mp4']);
    });

    test('ignores the staging directory and its partials', () async {
      // Mid-download content is not playable, so it must never be offered.
      write('Video/one.mp4');
      write('.ytdlp-staging/abc/one.mp4');
      write('.ytdlp-staging/abc/one.mp4.part');

      final found = await scanner.scan(root: root);
      expect(found.map((f) => f.name), ['one.mp4']);
    });

    test('skips tiny and empty files', () async {
      write('Video/big.mp4');
      write('Video/tiny.mp4', content: 'x');
      write('Video/empty.mp4', content: '');

      final found = await scanner.scan(root: root);
      expect(found.map((f) => f.name), ['big.mp4']);
    });

    test('matches extensions case-insensitively', () async {
      write('Video/one.MP4');
      write('Video/two.MKV');
      expect((await scanner.scan(root: root)).length, 2);
    });

    test('reports size and modification time', () async {
      final file = write('Video/one.mp4', content: 'x' * 1234);
      final found = await scanner.scan(root: root);
      expect(found.single.size, 1234);
      expect(
        found.single.modified
            .difference(file.lastModifiedSync())
            .inSeconds
            .abs(),
        lessThan(2),
      );
    });

    test('orders newest first', () async {
      final older = write('Video/old.mp4');
      final newer = write('Video/new.mp4');
      // Filesystem timestamps have coarse resolution, so age them explicitly.
      older.setLastModifiedSync(DateTime(2020));
      newer.setLastModifiedSync(DateTime(2024));

      final found = await scanner.scan(root: root);
      expect(found.map((f) => f.name), ['new.mp4', 'old.mp4']);
    });
  });

  group('excluding known files', () {
    test('skips paths already in the library', () async {
      final known = write('Video/one.mp4');
      write('Video/two.mp4');

      final found = await scanner.scan(root: root, knownPaths: {known.path});
      expect(found.map((f) => f.name), ['two.mp4']);
    });

    test('compares normalized paths', () async {
      // A relative-looking path in the library must still match, or every file
      // would look "new" after a restart.
      final known = write('Video/one.mp4');
      final normalized = p.normalize(known.path);
      final variant = normalized.replaceAll(p.separator, '/');

      final found = await scanner.scan(root: root, knownPaths: {variant});
      expect(found, isEmpty);
    });
  });

  group('robustness', () {
    test('a missing folder yields nothing', () async {
      final found = await scanner.scan(
        root: Directory('${root.path}/does-not-exist'),
      );
      expect(found, isEmpty);
    });

    test('an empty folder yields nothing', () async {
      expect(await scanner.scan(root: root), isEmpty);
    });

    test('respects the result cap', () async {
      // A huge folder must not lock the UI; the cap is a ceiling, not a
      // promise of completeness, so only the bound is asserted.
      for (var i = 0; i < 5; i++) {
        write('Video/f$i.mp4');
      }
      final found = await scanner.scan(root: root);
      expect(found.length, lessThanOrEqualTo(FolderScanner.maxResults));
      expect(found.length, 5);
    });
  });

  group('presentation', () {
    test('guessedTitle drops the extension', () async {
      write('Video/Some Video.mp4');
      final found = await scanner.scan(root: root);
      expect(found.single.guessedTitle, 'Some Video');
    });

    test('guessedTitle strips the app id suffix', () async {
      // The default template ends in "Title [id]"; showing that in a list is
      // noise the user did not put there.
      write('Video/Some Video [dQw4w9WgXcQ].mp4');
      final found = await scanner.scan(root: root);
      expect(found.single.guessedTitle, 'Some Video');
    });

    test('guessedTitle leaves a plain name alone', () async {
      write('Video/plain name.mkv');
      final found = await scanner.scan(root: root);
      expect(found.single.guessedTitle, 'plain name');
    });

    test('group reports the containing folder', () async {
      write('Video/Road Trip/one.mp4');
      final found = await scanner.scan(root: root);
      expect(found.single.group, 'Road Trip');
    });
  });
}
