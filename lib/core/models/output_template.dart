import 'video_info.dart';

/// A user-editable yt-dlp output template (`-o`).
///
/// Two jobs: hand the string to yt-dlp, and render a *preview* of the file
/// name it would produce so the user is not guessing. The preview is an
/// approximation — yt-dlp resolves hundreds of fields and applies its own
/// sanitization per platform — so anything this class cannot resolve is
/// rendered as a visible placeholder rather than a plausible-looking guess.
class OutputTemplate {
  const OutputTemplate(this.raw);

  /// The template as the user typed it.
  final String raw;

  /// yt-dlp's own default. Chosen over `%(title)s.%(ext)s` because the id
  /// makes a filename unique, which is what lets a second download of the same
  /// video coexist instead of silently overwriting.
  static const String defaultTemplate = '%(title)s [%(id)s].%(ext)s';

  /// The template used when the user's value is blank, so an empty field can
  /// never produce a nameless file.
  String get effective => raw.trim().isEmpty ? defaultTemplate : raw.trim();

  /// Whether the template can name a file at all.
  ///
  /// yt-dlp appends the extension when the template omits it, so a template
  /// with neither `%(ext)s` nor a literal extension would produce a file the
  /// app's "is this the media file?" check cannot classify — it keys on the
  /// extension to tell a `.mkv` from a `.srt` sidecar or a `.part` leftover.
  /// Refusing that up front is clearer than a download that reports
  /// "output file not found" at the end.
  bool get isUsable =>
      raw.contains(extField) || _hasLiteralExtension(effective);

  /// Whether [template] ends in something that reads as a file extension.
  ///
  /// Conservative on purpose: a dot followed by 1-4 alphanumerics at the very
  /// end. `%(playlist_index)s` is not an extension even though it ends in `s`.
  static bool _hasLiteralExtension(String template) =>
      RegExp(r'\.[A-Za-z0-9]{1,4}$').hasMatch(template);

  /// Fields the preview can render from a [VideoInfo].
  static const extField = '%(ext)s';
  static const titleField = '%(title)s';
  static const idField = '%(id)s';
  static const uploaderField = '%(uploader)s';
  static const uploadDateField = '%(upload_date)s';
  static const playlistTitleField = '%(playlist_title)s';
  static const playlistIndexField = '%(playlist_index)s';

  /// The field names offered as insertable chips in the editor.
  static const List<(String, String)> knownFields = [
    (titleField, 'Video title'),
    (extField, 'File extension'),
    (idField, 'Video id (keeps names unique)'),
    (uploaderField, 'Channel / artist'),
    (uploadDateField, 'Upload date (YYYYMMDD)'),
    (playlistTitleField, 'Playlist title'),
    (playlistIndexField, 'Position in the playlist'),
  ];

  /// Matches any playlist-related field, used to recognise a template that
  /// opens with a playlist folder.
  static final RegExp playlistFieldPattern = RegExp(
    r'%\((playlist_title|playlist_index|playlist_id|playlist_uploader)\)s',
  );

  /// Whether this template references `%(ext)s`.
  bool get hasExtension => effective.contains(extField);

  /// Filename [OutputTemplate] would produce for [video], with [ext] filled in.
  ///
  /// [ext] is passed in rather than guessed: the app does not know the
  /// container before the download runs, so the preview substitutes a
  /// representative one and the real name comes from yt-dlp at run time.
  String preview({required VideoInfo video, String ext = 'mp4'}) {
    final date = video.uploadDate;
    final stamp = date == null
        ? ''
        : '${date.year}${_two(date.month)}${_two(date.day)}';
    // Keys are bare field names, which is what _render extracts.
    final values = <String, String>{
      'ext': ext,
      'title': video.title,
      'id': video.id,
      'uploader': video.author ?? '',
      'upload_date': stamp,
      // A single video has no playlist context; shown blank rather than faked.
      'playlist_title': '',
      'playlist_index': '',
    };
    return _render(effective, values);
  }

  /// The part of the filename that is stable for a given video, ignoring the
  /// extension and any trailing sidecar suffix yt-dlp appends.
  ///
  /// `DownloadManager` uses this to recognise which file in a staging
  /// directory belongs to which task. The old hard-coded template embedded the
  /// id, so the check was "the name contains `[id]`"; a user template may
  /// contain no id at all, and matching on the title alone would confuse a
  /// video with a same-titled one. So the id is only required when the
  /// template actually uses it.
  String? identityFragment({required VideoInfo video}) {
    if (effective.contains(idField)) {
      return '[${video.id}]';
    }
    if (effective.contains(titleField)) {
      return sanitizeFragment(video.title);
    }
    // Neither: the only remaining candidate is the extension, which cannot
    // distinguish two files, so no fragment can be trusted.
    return null;
  }

  /// Replaces every `%(name)s` occurrence with its value, leaving unknown
  /// fields visible as `{name}` so a typo is obvious in the preview instead of
  /// silently producing an empty slot.
  static String _render(String template, Map<String, String> values) {
    final out = StringBuffer();
    var i = 0;
    while (i < template.length) {
      final start = template.indexOf('%(', i);
      if (start < 0) {
        out.write(template.substring(i));
        break;
      }
      // The closing sequence is ')s', not 's)': the conversion type follows
      // the parenthesis. A second '%(' before that means the first is not a
      // well-formed field, and pairing them would swallow the inner one.
      final end = template.indexOf(')s', start + 2);
      final nested = template.indexOf('%(', start + 2);
      if (end < 0 || (nested >= 0 && nested < end)) {
        // Not a field. Emit this character as typed and keep scanning so the
        // rest of the template still previews.
        out.write(template.substring(i, start + 1));
        i = start + 1;
        continue;
      }
      out.write(template.substring(i, start));
      final name = template.substring(start + 2, end);
      out.write(values[name] ?? '{$name}');
      i = end + 2;
    }
    return out.toString();
  }

  /// The `%(name)s` fields this template references, in order of appearance.
  List<String> get referencedFields {
    final fields = <String>[];
    final re = RegExp(r'%\(([A-Za-z0-9_]+)\)s');
    for (final m in re.allMatches(effective)) {
      final name = m.group(1)!;
      if (!fields.contains(name)) fields.add(name);
    }
    return fields;
  }

  /// Field names this template uses that the preview cannot resolve.
  ///
  /// Surfaced in the editor so a user who typed `%(fps)s` learns that the
  /// preview will not show it rather than assuming the field is broken.
  List<String> get unresolvedFields {
    const resolvable = {
      'ext', 'title', 'id', 'uploader', 'upload_date', //
      'playlist_title', 'playlist_index',
    };
    return [
      for (final f in referencedFields)
        if (!resolvable.contains(f)) f,
    ];
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// Reduces a string to something safe to look for inside a file name.
///
/// The preview and the manager's identity check both need a fragment that
/// survives the filesystem's own rules, so path separators, control characters
/// and the wildcard characters a substring match would treat as special are all
/// reduced to `_`. Kept deliberately small and separate from
/// `sanitizeFolderName`, which is about naming a *folder*.
String sanitizeFragment(String input) {
  var s = input.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // A path component cannot end in a dot or a space on Windows.
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  return s.isEmpty ? 'untitled' : s;
}

/// Human-readable summary of what a template produces, for the editor.
String describeTemplate(String raw) {
  final t = OutputTemplate(raw);
  if (!t.isUsable) {
    return 'Must include ${OutputTemplate.extField} — the app needs it to '
        'recognise the file.';
  }
  final parts = <String>[];
  if (t.effective.contains(OutputTemplate.titleField)) parts.add('title');
  if (t.effective.contains(OutputTemplate.idField)) parts.add('id');
  if (t.effective.contains(OutputTemplate.uploaderField)) {
    parts.add('uploader');
  }
  if (t.effective.contains(OutputTemplate.uploadDateField)) {
    parts.add('date');
  }
  if (t.effective.contains(OutputTemplate.playlistTitleField)) {
    parts.add('playlist folder');
  }
  final unresolved = t.unresolvedFields;
  final base = parts.isEmpty
      ? 'extension only, so every file is named the same and a second '
            'download will be renamed "(1)"'
      : parts.join(' · ');
  if (unresolved.isEmpty) return base;
  return '$base · not previewed: ${unresolved.join(', ')}';
}
