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
  double? abr,
}) => {
  'format_id': id,
  'ext': ext,
  'vcodec': vcodec,
  'acodec': acodec,
  'height': ?height,
  'filesize': ?filesize,
  'tbr': ?tbr,
  'abr': ?abr,
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
          _fmt(
            '136',
            vcodec: 'avc1',
            acodec: 'mp4a',
            height: 720,
            filesize: 25 * 1024 * 1024,
          ),
          _fmt('135', vcodec: 'avc1', acodec: 'mp4a', height: 480),
          _fmt('18', vcodec: 'avc1', acodec: 'mp4a', height: 360),
          _fmt(
            '140',
            vcodec: 'none',
            acodec: 'mp4a',
            ext: 'm4a',
            tbr: 128,
            filesize: 8 * 1024 * 1024,
          ),
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
        'Best quality · MP4',
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
      expect(
        best.selector,
        'b[height<=720][ext=mp4][acodec!=none]/b[height<=720][acodec!=none]',
      );

      final h360 = info.videoFormats.firstWhere(
        (f) => f.label.startsWith('360p'),
      );
      expect(
        h360.selector,
        'b[height<=360][ext=mp4][acodec!=none]/b[height<=360][acodec!=none]',
      );
    });

    test(
      'falls back to width-unconstrained selector when heights are missing',
      () {
        final info = VideoInfo.fromYtdlpJson(
          _ytJson([_fmt('18', vcodec: 'avc1', acodec: 'mp4a')]),
          hasFfmpeg: true,
        );
        final rows = info.videoFormats;
        expect(rows, hasLength(1));
        expect(rows.single.tier, isNull);
        expect(rows.single.selector, 'bv*+ba/b');
      },
    );

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
          _fmt(
            '137',
            vcodec: 'avc1',
            acodec: 'none',
            height: 1080,
            filesize: 50 * 1024 * 1024,
          ),
          _fmt(
            '136',
            vcodec: 'avc1',
            acodec: 'none',
            height: 720,
            filesize: 25 * 1024 * 1024,
          ),
          _fmt('140', vcodec: 'none', acodec: 'mp4a', ext: 'm4a', tbr: 128),
        ]),
        hasFfmpeg: true,
      );

      final rows = info.videoFormats;
      expect(rows.map((f) => f.label).toList(), [
        'Best quality · MP4 · 50.0 MB',
        '720p · MP4 · 25.0 MB',
      ]);
      expect(rows.first.tier, 1080);
      expect(rows.first.selector, 'bv*[height<=1080]+ba/b[height<=1080]/b');
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

    test('audio: one row per distinct tier the site actually offers', () {
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([
          for (final (i, b) in [320, 192, 160, 128, 96].indexed)
            _fmt(
              'a$i',
              vcodec: 'none',
              acodec: 'mp4a',
              ext: 'm4a',
              abr: b.toDouble(),
            ),
        ]),
        hasFfmpeg: false,
      );

      final rows = info.audioFormats;
      expect(rows.map((f) => f.label).toList(), [
        'Best audio · M4A · 320kbps',
        'High · M4A · 192kbps',
        'Medium · M4A · 128kbps',
        'Low · M4A · 96kbps',
      ]);
      expect(rows[0].selector, 'ba[ext=m4a]/ba');
      expect(rows[1].selector, 'ba[ext=m4a][abr<=192]/ba[ext=m4a]');
      expect(rows[2].tier, 128);
    });

    test('audio: tiers that deliver the same stream are hidden (YouTube)', () {
      // YouTube m4a only has two distinct bitrates — four named tiers must
      // collapse to two honest rows instead of duplicating the same files.
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([
          _fmt(
            'a1',
            vcodec: 'none',
            acodec: 'mp4a',
            ext: 'm4a',
            abr: 130,
            filesize: 309288,
          ),
          _fmt(
            'a0',
            vcodec: 'none',
            acodec: 'mp4a',
            ext: 'm4a',
            abr: 49,
            filesize: 117495,
          ),
        ]),
        hasFfmpeg: false,
      );

      final rows = info.audioFormats;
      expect(rows.map((f) => f.label).toList(), [
        'Best audio · M4A · 130kbps · 302.0 KB',
        'Medium · M4A · 49kbps · 114.7 KB',
      ]);
      expect(rows[1].selector, 'ba[ext=m4a][abr<=128]/ba[ext=m4a]');
    });

    test('audio: falls back to the site container when there is no m4a', () {
      final info = VideoInfo.fromYtdlpJson(
        _ytJson([
          _fmt('w1', vcodec: 'none', acodec: 'opus', ext: 'webm', abr: 200),
          _fmt('w0', vcodec: 'none', acodec: 'opus', ext: 'webm', abr: 100),
        ]),
        hasFfmpeg: false,
      );

      final rows = info.audioFormats;
      // Best→200, High→100 (≤192), Medium→100 (dup), Low→fallback 200 (dup).
      expect(rows.map((f) => f.label).toList(), [
        'Best audio · WebM · 200kbps',
        'High · WebM · 100kbps',
      ]);
      expect(rows[0].selector, 'ba/b');
      expect(rows[1].selector, 'ba[abr<=192]/ba');
    });

    test('carries hasFfmpeg and prefers yt-dlp thumbnail over raw list', () {
      final info = VideoInfo.fromYtdlpJson({
        ..._ytJson([]),
        'thumbnail': 'https://example.com/hqdefault.jpg',
        'thumbnails': [
          {'url': 'https://example.com/maxresdefault.webp'},
        ],
      }, hasFfmpeg: true);
      expect(info.hasFfmpeg, isTrue);
      expect(info.thumbnail, 'https://example.com/hqdefault.jpg');

      final noThumb = VideoInfo.fromYtdlpJson(_ytJson([]), hasFfmpeg: false);
      expect(noThumb.hasFfmpeg, isFalse);
      expect(noThumb.thumbnail, 'https://example.com/thumb.jpg');
    });
  });

  group('subtitle tracks', () {
    Map<String, dynamic> jsonWith({
      Map<String, dynamic>? subtitles,
      Map<String, dynamic>? automaticCaptions,
    }) => {
      ..._ytJson([]),
      'subtitles': ?subtitles,
      'automatic_captions': ?automaticCaptions,
    };

    test('merges manual and auto tracks, common languages first', () {
      final info = VideoInfo.fromYtdlpJson(
        jsonWith(
          subtitles: {
            'de': [
              {'ext': 'srt'},
              {'ext': 'vtt'},
            ],
            'en': [
              {'ext': 'srt'},
              {'ext': 'ttml'},
            ],
          },
          automaticCaptions: {
            'en': [
              {'ext': 'vtt'},
            ],
            'es': [
              {'ext': 'vtt'},
            ],
            'xx': [
              {'ext': 'vtt'},
            ],
          },
        ),
        hasFfmpeg: false,
      );

      expect(info.subtitleTracks.map((t) => t.lang).toList(), [
        'en', // common, first
        'es',
        'de',
        'xx', // non-common after the common ones
      ]);
      final en = info.subtitleTracks.first;
      expect(en.name, 'English');
      expect(en.isAutoOnly, isFalse, reason: 'manual srt exists');
      expect(en.exts, contains('srt'));
      final es = info.subtitleTracks[1];
      expect(es.isAutoOnly, isTrue, reason: 'only automatic_captions');
      expect(es.exts, ['vtt']);
    });

    test('caps the surfaced tracks and drops entries without formats', () {
      final many = <String, dynamic>{
        for (var i = 0; i < 20; i++)
          'l$i': [
            {'ext': 'srt'},
          ],
      };
      final info = VideoInfo.fromYtdlpJson(
        jsonWith(subtitles: many, automaticCaptions: {'l0': []}),
        hasFfmpeg: false,
      );
      expect(info.subtitleTracks.length, VideoInfo.subtitleTrackLimit);
    });

    test('empty when the site offers no subtitles', () {
      final info = VideoInfo.fromYtdlpJson(jsonWith(), hasFfmpeg: false);
      expect(info.subtitleTracks, isEmpty);
    });

    test('a format field of an unexpected type does not throw', () {
      // These values come from the site, so the app cannot assume their shape.
      // `as String?` on a number throws, which would have crashed the metadata
      // fetch rather than quietly dropping the malformed format.
      late VideoInfo info;
      expect(
        () => info = VideoInfo.fromYtdlpJson({
          'id': 'abc123',
          'title': 'Sample video',
          'formats': [
            {'format_id': 137, 'ext': 'mp4', 'vcodec': 9, 'acodec': 'none'},
            {'format_id': '140', 'ext': 4, 'vcodec': 'none', 'acodec': 'mp4a'},
          ],
        }, hasFfmpeg: true),
        returnsNormally,
      );
      expect(info.id, 'abc123');
    });

    test('an unexpected string field type falls back to a default', () {
      final info = VideoInfo.fromYtdlpJson({
        'id': 'abc123',
        'title': 42,
        'webpage_url': ['nope'],
        'uploader': 7,
      }, hasFfmpeg: false);

      expect(info.id, 'abc123');
      expect(info.title, 'Untitled video');
      expect(info.webUrl, '');
      expect(info.author, isNull);
    });
  });
}
