import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/video_info.dart';

Map<String, dynamic> _fmt(
  String id, {
  String? vcodec,
  String? acodec,
  String ext = 'mp4',
  int? height,
  int? filesize,
  double? tbr,
}) =>
    {
      'format_id': id,
      'ext': ext,
      'vcodec': vcodec,
      'acodec': acodec,
      'height': ?height,
      'filesize': ?filesize,
      'tbr': ?tbr,
    };

Map<String, dynamic> _ytJson(List<Map<String, dynamic>> formats) => {
      'id': 'abc123',
      'title': 'Sample video',
      'uploader': 'Test Channel',
      'duration': 132,
      'upload_date': '20240115',
      'thumbnail': 'https://example.com/thumb.jpg',
      'webpage_url': 'https://www.youtube.com/watch?v=abc123',
      'formats': formats,
    };

void main() {
  group('VideoInfo.fromYtdlpJson', () {
    test('parses metadata and formats (with ffmpeg)', () {
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([
          _fmt('137', vcodec: 'avc1', acodec: 'none', height: 1080),
          _fmt('136', vcodec: 'avc1', acodec: 'mp4a', height: 720,
              filesize: 25 * 1024 * 1024),
          _fmt('135', vcodec: 'avc1', acodec: 'mp4a', height: 480),
          _fmt('18', vcodec: 'avc1', acodec: 'mp4a', height: 360),
          _fmt('140', vcodec: 'none', acodec: 'mp4a', ext: 'm4a',
              tbr: 128, filesize: 8 * 1024 * 1024),
        ]),
        hasFfmpeg: true,
      );

      expect(info.id, 'abc123');
      expect(info.title, 'Sample video');
      expect(info.author, 'Test Channel');
      expect(info.duration, 132);
      expect(info.uploadDate, DateTime(2024, 1, 15));
      expect(info.webUrl, 'https://www.youtube.com/watch?v=abc123');

      // One row per distinct video-bearing resolution strictly below the
      // best one (Best quality already covers the top resolution,
      // including video-only streams merged with audio).
      final rows = info.videoFormats;
      expect(rows.map((f) => f.label).toList(), [
        'Best quality',
        '720p · MP4 · 25.0 MB',
        '480p · MP4',
        '360p · MP4',
      ]);
      // No fake rows above the source's max resolution.
      expect(rows.any((f) => f.label.startsWith('2160p')), isFalse);
      expect(rows.any((f) => f.label.startsWith('1440p')), isFalse);

      // Best row picks the source's best video stream and merges audio.
      expect(rows.first.tier, 1080);
      expect(rows.first.selector, 'bv*[height<=1080]+ba/b[height<=1080]/b');

      final audio = info.audioFormats.single;
      expect(audio.kind, FormatKind.audio);
      expect(audio.selector, 'ba[ext=m4a]/ba');
      expect(audio.label, contains('M4A'));
    });

    test('builds merge-free selectors when ffmpeg is missing', () {
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([
          _fmt('136', vcodec: 'avc1', acodec: 'mp4a', height: 720),
          _fmt('18', vcodec: 'avc1', acodec: 'mp4a', height: 360),
        ]),
        hasFfmpeg: false,
      );

      final best = info.videoFormats.first;
      expect(best.selector, 'b[height<=720][ext=mp4]/b[height<=720]/b');

      final h360 = info.videoFormats.firstWhere((f) => f.label.startsWith('360p'));
      expect(h360.selector, 'b[height<=360][ext=mp4]/b[height<=360]/b');
    });

    test('falls back to width-unconstrained selector when heights are missing',
        () {
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([_fmt('18', vcodec: 'avc1', acodec: 'mp4a')]),
        hasFfmpeg: true,
      );
      final rows = info.videoFormats;
      expect(rows, hasLength(1));
      expect(rows.single.tier, isNull);
      expect(rows.single.selector, 'bv*+ba/b');
    });

    test('handles empty formats', () {
      final info = VideoInfo.fromYtdlpJson(_ytJson([]), hasFfmpeg: false);
      expect(info.videoFormats, isEmpty);
      expect(info.audioFormats, isEmpty);
    });

    test('ignores video-only streams (no audio track present)', () {
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([_fmt('137', vcodec: 'avc1', acodec: 'none', height: 1080)]),
        hasFfmpeg: false,
      );
      expect(info.videoFormats, isEmpty);
      expect(info.audioFormats, isEmpty);
    });

    test('builds merge rows from split streams (no combined formats)', () {
      // Modern YouTube: video-only + audio-only, zero combined.
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([
          _fmt('137', vcodec: 'avc1', acodec: 'none', height: 1080,
              filesize: 50 * 1024 * 1024),
          _fmt('136', vcodec: 'avc1', acodec: 'none', height: 720,
              filesize: 25 * 1024 * 1024),
          _fmt('140', vcodec: 'none', acodec: 'mp4a', ext: 'm4a', tbr: 128),
        ]),
        hasFfmpeg: true,
      );

      final rows = info.videoFormats;
      expect(rows.map((f) => f.label).toList(), [
        'Best quality · 50.0 MB',
        '720p · MP4 · 25.0 MB',
      ]);
      expect(rows.first.tier, 1080);
      expect(rows.first.selector,
          'bv*[height<=1080]+ba/b[height<=1080]/b');
      expect(info.audioFormats.single.selector, 'ba[ext=m4a]/ba');
    });

    test('no video rows without ffmpeg when only split streams exist', () {
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([
          _fmt('137', vcodec: 'avc1', acodec: 'none', height: 1080),
          _fmt('140', vcodec: 'none', acodec: 'mp4a', ext: 'm4a', tbr: 128),
        ]),
        hasFfmpeg: false,
      );
      // Merging is impossible — no single-file stream, no video options.
      expect(info.videoFormats, isEmpty);
      expect(info.audioFormats, hasLength(1));
    });
  });
}