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
    });

    test('audio goes to root/Audio with the plain template', () {
      final l = resolveDownloadLayout(root: root, kind: FormatKind.audio);
      expect(l.kind, FormatKind.audio);
      expect(l.directory, p.join(root, 'Audio'));
      expect(l.template, '%(title)s [%(id)s].%(ext)s');
    });

    test('playlist video groups by playlist inside the Video area', () {
      final l = resolveDownloadLayout(
          root: root, kind: FormatKind.video, isPlaylist: true);
      expect(l.directory, p.join(root, 'Video'));
      expect(l.template,
          '%(playlist_title)s/%(title)s [%(id)s].%(ext)s');
    });

    test('playlist audio groups by playlist inside the Audio area', () {
      final l = resolveDownloadLayout(
          root: root, kind: FormatKind.audio, isPlaylist: true);
      expect(l.directory, p.join(root, 'Audio'));
      expect(l.template,
          '%(playlist_title)s/%(title)s [%(id)s].%(ext)s');
    });
  });
}