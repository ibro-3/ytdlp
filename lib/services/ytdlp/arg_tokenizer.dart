/// Parsing and vetting of the user-supplied "extra arguments" field.
///
/// The app spawns yt-dlp with an argument *list*, never through a shell, so
/// these tokens cannot chain commands. What they can do is change where files
/// land and which stream is picked, so the flags the app manages itself are
/// detected and neutralised rather than left to fight over precedence.
library;

/// Flags the app sets on every download. A user-supplied duplicate is
/// reported so the UI can say it will be ignored, instead of leaving the field
/// to silently change behaviour.
enum ManagedFlag {
  output('output', 'where files are written'),
  format('format', 'which stream is downloaded'),
  playlist('playlist', 'whether a whole playlist is expanded'),
  ffmpegLocation('ffmpeg-location', 'where ffmpeg is found');

  const ManagedFlag(this.flag, this.consequence);

  /// The long name as yt-dlp spells it, without dashes.
  final String flag;

  /// Plain-language effect, shown next to a warning.
  final String consequence;
}

/// A problem found in a user's argument field.
class ArgIssue {
  const ArgIssue({required this.message, this.isBlocking = false});

  final String message;

  /// True when the field cannot be used as written, so saving is refused.
  final bool isBlocking;
}

class ArgSyntaxException implements Exception {
  const ArgSyntaxException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Splits an argument string into argv-style tokens.
///
/// This mirrors shell *word splitting* only — no expansion, no substitution, no
/// command execution. Single quotes are literal, double quotes honour a
/// backslash escape, and an unterminated quote is an error rather than a
/// silently-closed string: a half-open quote is almost always a typo and would
/// otherwise hand yt-dlp an argument the user did not intend.
///
/// Throws [ArgSyntaxException] on an unterminated quote or a trailing
/// backslash.
List<String> tokenizeArgs(String input) => ArgTokenizer(input).parse();

/// Hand-rolled scanner. Short and dependency-free on purpose: this input is
/// user-typed and every failure mode is about exact quoting behaviour.
class ArgTokenizer {
  ArgTokenizer(this._input);
  final String _input;

  int _i = 0;

  static const _quote = 0x22; // "
  static const _apostrophe = 0x27; // '
  static const _backslash = 0x5C; // \
  static const _space = 0x20;
  static const _tab = 0x09;
  static const _newline = 0x0A;
  static const _cr = 0x0D;

  List<String> parse() {
    final out = <String>[];
    while (true) {
      _skipWhitespace();
      if (_i >= _input.length) return out;
      out.add(_readToken());
    }
  }

  void _skipWhitespace() {
    while (_i < _input.length && _isSpace(_input.codeUnitAt(_i))) {
      _i++;
    }
  }

  static bool _isSpace(int c) =>
      c == _space || c == _tab || c == _newline || c == _cr;

  /// Reads one token. Whitespace always ends the token: the quote readers
  /// consume their own delimiters, so control never returns here while still
  /// inside a quoted run.
  String _readToken() {
    final buf = StringBuffer();
    while (_i < _input.length) {
      final c = _input.codeUnitAt(_i);
      if (_isSpace(c)) break;
      if (c == _apostrophe) {
        // Step past the opening delimiter before hunting for the closing one,
        // otherwise indexOf matches the quote we are standing on.
        _i++;
        _readSingleQuoted(buf);
      } else if (c == _quote) {
        _i++;
        _readDoubleQuoted(buf);
      } else if (c == _backslash) {
        _readEscape(buf);
      } else {
        buf.writeCharCode(c);
        _i++;
      }
    }
    return buf.toString();
  }

  /// Copies the next character verbatim, whatever it is. A backslash at the
  /// very end escapes nothing, which is a typo rather than an intent.
  void _readEscape(StringBuffer buf) {
    if (_i + 1 >= _input.length) {
      throw const ArgSyntaxException(
        'A backslash at the end of the text escapes nothing.',
      );
    }
    buf.writeCharCode(_input.codeUnitAt(_i + 1));
    _i += 2;
  }

  /// Everything up to the next apostrophe is literal, backslashes included, so
  /// `--match-title 'a\b'` passes through as typed. [_i] must already sit just
  /// past the opening quote.
  void _readSingleQuoted(StringBuffer buf) {
    final end = _input.indexOf("'", _i);
    if (end < 0) {
      throw const ArgSyntaxException(
        "A quote (') was opened but never closed.",
      );
    }
    buf.write(_input.substring(_i, end));
    _i = end + 1;
  }

  void _readDoubleQuoted(StringBuffer buf) {
    while (true) {
      if (_i >= _input.length) {
        throw const ArgSyntaxException(
          'A quote (") was opened but never closed.',
        );
      }
      final c = _input.codeUnitAt(_i);
      if (c == _backslash) {
        // Inside double quotes a backslash still escapes the next character;
        // the trailing-backslash case is a syntax error in both quote styles.
        if (_i + 1 >= _input.length) {
          throw const ArgSyntaxException(
            'A backslash at the end of the text escapes nothing.',
          );
        }
        buf.writeCharCode(_input.codeUnitAt(_i + 1));
        _i += 2;
        continue;
      }
      if (c == _quote) {
        _i++;
        return;
      }
      buf.writeCharCode(c);
      _i++;
    }
  }
}

/// Whether [tokens] contain [flag] in either its short or long spelling.
///
/// `--format=best` counts, because yt-dlp accepts it and a user pasting from a
/// terminal will use either form.
bool hasFlag(List<String> tokens, String flag, {String? shortFlag}) {
  for (final t in tokens) {
    if (t == '--$flag' || t.startsWith('--$flag=')) return true;
    if (shortFlag == null) continue;
    // Exactly the short flag, attached to a value (`-fbest`), or as its own
    // token. `--format` must not match here, hence the length check.
    if (t == '-$shortFlag') return true;
    if (t.length > 2 && t.startsWith('-$shortFlag') && !t.startsWith('--')) {
      return true;
    }
  }
  return false;
}

/// Every managed flag present in [tokens], in declaration order.
List<ManagedFlag> findManagedFlags(List<String> tokens) => [
  for (final f in ManagedFlag.values)
    if (_matches(f, tokens)) f,
];

bool _matches(ManagedFlag flag, List<String> tokens) => switch (flag) {
  ManagedFlag.output => hasFlag(tokens, 'output', shortFlag: 'o'),
  ManagedFlag.format => hasFlag(tokens, 'format', shortFlag: 'f'),
  ManagedFlag.playlist =>
    hasFlag(tokens, 'no-playlist') || hasFlag(tokens, 'yes-playlist'),
  ManagedFlag.ffmpegLocation => hasFlag(tokens, 'ffmpeg-location'),
};

/// Problems with a tokenised argument field, ready to render in the UI.
///
/// A managed duplicate is a *warning*, not an error: the download still works
/// and the app's own value wins, so refusing to save would be hostile to
/// someone who pasted a full command line. A syntax error is blocking, because
/// there is no safe reading of the text.
List<ArgIssue> validateExtraArgs(String raw) {
  final List<String> tokens;
  try {
    tokens = tokenizeArgs(raw);
  } on ArgSyntaxException catch (e) {
    return [ArgIssue(message: e.message, isBlocking: true)];
  }
  if (tokens.isEmpty) return const [];

  final issues = <ArgIssue>[];
  for (final flag in findManagedFlags(tokens)) {
    issues.add(
      ArgIssue(
        message:
            '--${flag.flag} is set by the app for every download, so this one '
            'is ignored (it controls ${flag.consequence}).',
      ),
    );
  }
  if (hasFlag(tokens, 'exec', shortFlag: 'e') ||
      hasFlag(tokens, 'config-location')) {
    issues.add(
      const ArgIssue(
        message:
            'This runs another command or loads a config file. Only add flags '
            'you trust.',
      ),
    );
  }
  return issues;
}
