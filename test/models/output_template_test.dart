import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/output_template.dart';
import 'package:ytdlp/core/models/video_info.dart';

VideoInfo video({
  String id = 'abc123',
  String title = 'Some Video',
  String? author = 'A Channel',
  DateTime? date,
}) => VideoInfo(
  id: id,
  title: title,
  webUrl: 'https://example.com/v',
  author: author,
  uploadDate: date,
);

void main() {
  group('effective', () {
    test('falls back to the default when blank', () {
      expect(OutputTemplate('').effective, OutputTemplate.defaultTemplate);
      expect(OutputTemplate('   ').effective, OutputTemplate.defaultTemplate);
    });

    test('trims a real template', () {
      expect(
        OutputTemplate('  %(title)s.%(ext)s  ').effective,
        '%(title)s.%(ext)s',
      );
    });
  });

  group('isUsable', () {
    test('requires an extension field', () {
      expect(OutputTemplate('%(title)s [%(id)s].%(ext)s').isUsable, isTrue);
      expect(OutputTemplate('%(title)s.%(ext)s').isUsable, isTrue);
      // Without %(ext)s yt-dlp cannot pick an output format, and the manager
      // classifies finished files by extension.
      expect(OutputTemplate('%(title)s [%(id)s]').isUsable, isFalse);
      expect(OutputTemplate('').isUsable, isFalse);
    });

    test('a literal extension still counts', () {
      expect(OutputTemplate('%(title)s.mp4').isUsable, isTrue);
    });
  });

  group('staysInDirectory', () {
    test('an ordinary template is fine', () {
      expect(OutputTemplate('%(title)s [%(id)s].%(ext)s').staysInDirectory, isTrue);
      // The documented way to group by playlist, which the app strips back off
      // for staging and applies itself on the way out.
      expect(
        OutputTemplate('%(playlist_title)s/%(title)s.%(ext)s').staysInDirectory,
        isTrue,
      );
      // A folder that merely starts with dots is not a parent reference.
      expect(OutputTemplate('.../%(title)s.%(ext)s').staysInDirectory, isTrue);
    });

    test('rejects a template that climbs out', () {
      // yt-dlp resolves `..` against the staging directory, so this would write
      // the finished file anywhere on the filesystem — where the app neither
      // finds it as the result nor cleans it up.
      expect(OutputTemplate('../../%(title)s.%(ext)s').staysInDirectory, isFalse);
      expect(
        OutputTemplate('%(playlist_title)s/../../%(title)s.%(ext)s')
            .staysInDirectory,
        isFalse,
      );
      expect(
        OutputTemplate(r'..\%(title)s.%(ext)s').staysInDirectory,
        isFalse,
        reason: r'a Windows-style separator escapes just as well',
      );
    });
  });

  group('preview', () {
    test('renders the fields it knows', () {
      final t = OutputTemplate('%(title)s [%(id)s].%(ext)s');
      expect(t.preview(video: video(), ext: 'mkv'), 'Some Video [abc123].mkv');
    });

    test('formats the upload date as YYYYMMDD', () {
      final t = OutputTemplate('%(upload_date)s - %(title)s.%(ext)s');
      expect(
        t.preview(video: video(date: DateTime(2026, 3, 7))),
        '20260307 - Some Video.mp4',
      );
    });

    test('a missing date renders empty rather than "null"', () {
      final t = OutputTemplate('%(upload_date)s%(title)s.%(ext)s');
      expect(t.preview(video: video(date: null)), 'Some Video.mp4');
    });

    test('a missing uploader renders empty', () {
      final t = OutputTemplate('%(uploader)s - %(title)s.%(ext)s');
      expect(t.preview(video: video(author: null)), ' - Some Video.mp4');
    });

    test('an unknown field stays visible instead of vanishing', () {
      // A field the preview cannot resolve is shown as {fps} so a typo is
      // obvious rather than looking like an empty slot.
      final t = OutputTemplate('%(title)s %(fps)s.%(ext)s');
      expect(t.preview(video: video()), 'Some Video {fps}.mp4');
    });

    test('playlist fields are blank for a single video', () {
      final t = OutputTemplate('%(playlist_title)s%(title)s.%(ext)s');
      expect(t.preview(video: video()), 'Some Video.mp4');
    });

    test('a literal % without a field is passed through', () {
      final t = OutputTemplate('100%% %(title)s.%(ext)s');
      // '%%' is not a field, so it is emitted as typed; the file name the app
      // can still recognise comes from the id/title fields.
      expect(t.preview(video: video()), contains('Some Video.mp4'));
    });

    test('a malformed field does not swallow the rest of the template', () {
      // '%(title.' never closes, so it is emitted as typed and the scanner
      // resumes at the next '%(' rather than pairing the two.
      final t = OutputTemplate('%(title.%(ext)s');
      expect(t.preview(video: video()), '%(title.mp4');
    });
  });

  group('identityFragment', () {
    test('uses the id when the template contains one', () {
      final t = OutputTemplate('%(title)s [%(id)s].%(ext)s');
      expect(t.identityFragment(video: video(id: 'xyz')), '[xyz]');
    });

    test('falls back to the title when there is no id', () {
      final t = OutputTemplate('%(title)s.%(ext)s');
      expect(t.identityFragment(video: video(title: 'My Clip')), 'My Clip');
    });

    test('is null when neither id nor title identifies the file', () {
      // The manager cannot match on the extension alone, so it must not try.
      final t = OutputTemplate('%(ext)s');
      expect(t.identityFragment(video: video()), isNull);
    });

    test('a blank template still resolves through the default', () {
      final t = OutputTemplate('');
      expect(t.identityFragment(video: video(id: 'abc123')), '[abc123]');
    });
  });

  group('sanitizeFragment', () {
    test('reduces separators and control characters', () {
      expect(sanitizeFragment('a/b\\c:d'), 'a_b_c_d');
      expect(sanitizeFragment('bad\u0000name'), 'bad_name');
    });

    test('never returns empty', () {
      expect(sanitizeFragment(''), 'untitled');
      expect(sanitizeFragment('   '), 'untitled');
    });

    test('a fragment of only separators is still a single safe component', () {
      // '///' reduces to '___' rather than the fallback. That is fine — the
      // invariant is a non-empty, separator-free fragment.
      final out = sanitizeFragment('///');
      expect(out, isNotEmpty);
      expect(out, isNot(contains('/')));
    });

    test('trims trailing dots and spaces', () {
      expect(sanitizeFragment('name... '), 'name');
    });
  });

  group('referencedFields', () {
    test('lists fields once, in order', () {
      final t = OutputTemplate('%(title)s [%(id)s] %(title)s.%(ext)s');
      expect(t.referencedFields, ['title', 'id', 'ext']);
    });

    test('unresolvedFields excludes the renderable ones', () {
      final t = OutputTemplate('%(title)s %(fps)s %(uploader)s.%(ext)s');
      expect(t.unresolvedFields, ['fps']);
    });
  });

  group('describeTemplate', () {
    test('names what the template contains', () {
      expect(
        describeTemplate('%(uploader)s - %(title)s [%(id)s].%(ext)s'),
        'title · id · uploader',
      );
    });

    test('explains a missing extension', () {
      expect(describeTemplate('%(title)s'), contains('%(ext)s'));
    });

    test('calls out fields the preview cannot show', () {
      expect(
        describeTemplate('%(title)s %(fps)s.%(ext)s'),
        contains('not previewed: fps'),
      );
    });

    test('warns when nothing identifies the file', () {
      expect(
        describeTemplate('%(ext)s'),
        contains('every file is named the same'),
      );
    });

    test('mentions the playlist folder when present', () {
      expect(
        describeTemplate('%(playlist_title)s/%(title)s.%(ext)s'),
        contains('playlist folder'),
      );
    });
  });
}
