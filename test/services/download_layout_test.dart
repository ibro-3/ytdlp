import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ytdlp/core/models/video_info.dart';
import 'package:ytdlp/services/downloads/download_layout.dart';

void main() {
  group('resolveDownloadLayout', () {
    const root = '/media/ytdlp';

    test('video goes to root/Video with the plain template', () {
      final l = resolveDownloadLayout(root: root, kind: FormatKind.video);
      expect(l.kind, FormatKind.video);
      expect(l.directory, p.join(root, 'Video'));
      expect(l.template, '%(title)s [%(id)s].%(ext)s');
      expect(l.subdirectory, isNull);
      expect(l.targetDirectory, p.join(root, 'Video'));
    });

    test('audio goes to root/Audio with the plain template', () {
      final l = resolveDownloadLayout(root: root, kind: FormatKind.audio);
      expect(l.kind, FormatKind.audio);
      expect(l.directory, p.join(root, 'Audio'));
      expect(l.template, '%(title)s [%(id)s].%(ext)s');
      expect(l.targetDirectory, p.join(root, 'Audio'));
    });

    test('playlist video groups by playlist inside the Video area', () {
      final l = resolveDownloadLayout(
        root: root,
        kind: FormatKind.video,
        playlistTitle: 'Road Trip',
      );
      expect(l.directory, p.join(root, 'Video'));
      expect(l.template, '%(playlist_title)s/%(title)s [%(id)s].%(ext)s');
      expect(l.subdirectory, 'Road Trip');
      expect(l.targetDirectory, p.join(root, 'Video', 'Road Trip'));
    });

    test('playlist audio groups by playlist inside the Audio area', () {
      final l = resolveDownloadLayout(
        root: root,
        kind: FormatKind.audio,
        playlistTitle: 'Road Trip',
      );
      expect(l.directory, p.join(root, 'Audio'));
      expect(l.subdirectory, 'Road Trip');
      expect(l.targetDirectory, p.join(root, 'Audio', 'Road Trip'));
    });

    test('a blank playlist title is treated as no playlist', () {
      for (final title in const ['', '   ']) {
        final l = resolveDownloadLayout(
          root: root,
          kind: FormatKind.video,
          playlistTitle: title,
        );
        expect(l.subdirectory, isNull, reason: 'title: "$title"');
        expect(l.template, '%(title)s [%(id)s].%(ext)s');
        expect(l.targetDirectory, p.join(root, 'Video'));
      }
    });
  });

  group('sanitizeFolderName', () {
    test('leaves an ordinary title alone', () {
      expect(sanitizeFolderName('Road Trip 2026'), 'Road Trip 2026');
    });

    test('replaces path separators so a title cannot escape the root', () {
      expect(sanitizeFolderName('../../etc'), '.._.._etc');
      expect(sanitizeFolderName('a/b\\c'), 'a_b_c');
      // Never an absolute path, and never empty.
      expect(sanitizeFolderName('/etc/passwd'), '_etc_passwd');
    });

    test('replaces characters Windows rejects', () {
      expect(sanitizeFolderName('a:b*c?d"e<f>g|h'), 'a_b_c_d_e_f_g_h');
    });

    test('strips control characters', () {
      expect(sanitizeFolderName('bad\u0000name\u001fhere'), 'bad_name_here');
    });

    test('trims trailing dots and spaces Windows would drop anyway', () {
      expect(sanitizeFolderName('name...  '), 'name');
    });

    test('escapes reserved Windows device names', () {
      expect(sanitizeFolderName('CON'), '_CON');
      expect(sanitizeFolderName('com1'), '_com1');
      expect(sanitizeFolderName('LPT9'), '_LPT9');
      // A non-reserved lookalike is left alone.
      expect(sanitizeFolderName('CONCERT'), 'CONCERT');
    });

    test('falls back to a default when the title is empty', () {
      expect(sanitizeFolderName(''), 'Playlist');
      expect(sanitizeFolderName('   '), 'Playlist');
    });

    test('a title made only of separators still yields a safe name', () {
      // '///' sanitizes to '___' rather than the default. That is fine — the
      // invariant that matters is that the result is a single safe path
      // component, never empty and never able to escape the root.
      final out = sanitizeFolderName('///');
      expect(out, isNotEmpty);
      expect(out, isNot(contains('/')));
      expect(out, isNot(contains(r'\')));
      expect(out, isNot(contains('..')));
    });

    test('caps the length and leaves room for a collision suffix', () {
      final long = 'x' * 500;
      expect(sanitizeFolderName(long).length, lessThanOrEqualTo(120));
      // Multi-byte titles are trimmed harder so the byte length still fits a
      // 255-byte path component after ' (1)' is appended.
      final wide = '한' * 200;
      final out = sanitizeFolderName(wide);
      expect(out.length, lessThanOrEqualTo(40));
    });

    test('collapses whitespace runs left by replacements', () {
      // Separators become '_' and the surrounding spaces collapse to one, so
      // the result is still a readable single path component.
      expect(sanitizeFolderName('a  /  b'), 'a _ b');
      expect(sanitizeFolderName('  spaced  out  '), 'spaced out');
    });

    test('never produces a path that escapes the download root', () {
      const hostile = [
        '..',
        '../..',
        '../../../../etc',
        '/absolute',
        r'C:\Windows\System32',
        'a/../../b',
        '...',
      ];
      for (final title in hostile) {
        final out = sanitizeFolderName(title);
        expect(out, isNotEmpty, reason: title);
        expect(p.isAbsolute(out), isFalse, reason: title);
        expect(
          p.normalize(p.join('/root/Video', out)),
          p.join('/root/Video', out),
          reason: 'title "$title" produced "$out"',
        );
      }
    });
  });
}
