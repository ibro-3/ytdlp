/// Reads and writes the Netscape `cookies.txt` format yt-dlp
/// takes via `--cookies`.
///
/// The format is one cookie per line, seven tab-separated
/// fields:
///
///     domain  flag  path  secure  expiry  name  value
///
/// with `#`-prefixed lines as comments and `#HttpOnly_` as a
/// prefix marking an HttpOnly cookie. The header line
/// (`# Netscape HTTP Cookie File`) is a comment like any other.
///
/// Two things make a real-world jar harder than "split on
/// tab", and both bite in practice:
///
/// - **The value is the last field and may itself contain
///   tabs** (rare, but a base64 value can). Splitting into
///   exactly seven pieces would drop the tail, so the value is
///   everything after the sixth tab.
/// - **Malformed lines happen** — a half-written file, an
///   editor that mangled a line, a trailing blank. One bad
///   line must not void the whole jar, so lines that do not
///   parse are skipped rather than fatal. The caller learns
///   how many were skipped, so a silently-empty jar is never
///   mistaken for a good one.
///
/// Values are parsed but never echoed: [CookieJarEntry.value]
/// is a credential, and this class has no method that prints
/// one.
library;

import 'dart:convert';

import 'cookie_model.dart';

/// The result of parsing a jar: the cookies that parsed, and
/// how many lines could not be read.
class CookieJarParseResult {
  const CookieJarParseResult({required this.entries, required this.skipped});

  final List<CookieJarEntry> entries;

  /// Lines that were present but did not parse. A jar with
  /// cookies and a couple of skips is still usable; a jar
  /// with nothing but skips is not.
  final int skipped;
}

class CookieJar {
  CookieJar._();

  /// Parses [text] as a Netscape jar. Never throws: a jar is
  /// user-supplied and may be anything, so the answer is a
  /// (possibly empty) list plus a count of the lines that
  /// did not parse.
  static CookieJarParseResult parse(String text) {
    final entries = <CookieJarEntry>[];
    var skipped = 0;
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        // `#HttpOnly_` prefixes a real cookie line; every
        // other comment (including the header) is noise.
        if (!_isHttpOnlyLine(line)) continue;
      }
      final entry = _parseLine(line);
      if (entry == null) {
        skipped++;
      } else {
        entries.add(entry);
      }
    }
    return CookieJarParseResult(entries: entries, skipped: skipped);
  }

  /// Whether a picked file is a Netscape jar, by structure
  /// rather than by filename: it must yield at least one
  /// cookie. An HTML error page or a JSON export has no
  /// seven-field lines, so it parses to nothing and is
  /// rejected — which is the point, because yt-dlp would
  /// otherwise fail every download with a parse error.
  static bool looksLikeCookieJar(String text) => parse(text).entries.isNotEmpty;

  /// Serialises [entries] back to the on-disk format, so a
  /// filtered jar (Phase 6b's per-domain enable/disable) is
  /// written the same way the user's browser wrote the
  /// original.
  static String write(List<CookieJarEntry> entries) {
    final buffer = StringBuffer()..writeln('# Netscape HTTP Cookie File');
    for (final e in entries) {
      // The expiry is epoch seconds; a session cookie (no
      // expiry) is written as 0, which yt-dlp reads back as
      // "does not persist".
      final expiry = e.expiry == null
          ? 0
          : e.expiry!.millisecondsSinceEpoch ~/ 1000;
      final prefix = e.httpOnly ? '#HttpOnly_' : '';
      buffer.writeln(
        '$prefix${e.domain}\t'
        '${e.includeSubdomains ? 'TRUE' : 'FALSE'}\t'
        '${e.path}\t'
        '${e.secure ? 'TRUE' : 'FALSE'}\t'
        '$expiry\t'
        '${e.name}\t'
        '${e.value}',
      );
    }
    return buffer.toString();
  }

  static bool _isHttpOnlyLine(String comment) =>
      comment.startsWith('#HttpOnly_') || comment.startsWith('#HTTPONLY_');

  static CookieJarEntry? _parseLine(String line) {
    var working = line;
    var httpOnly = false;
    if (working.startsWith('#HttpOnly_') || working.startsWith('#HTTPONLY_')) {
      httpOnly = true;
      working = working.replaceFirst(RegExp(r'^#HttpOnly_'), '');
      working = working.replaceFirst(RegExp(r'^#HTTPONLY_'), '');
    }
    final fields = working.split('\t');
    if (fields.length < 7) return null;
    // The value is everything after the sixth tab: a value
    // may itself contain tabs, and dropping them would
    // corrupt the cookie.
    final value = fields.sublist(6).join('\t');
    final domain = fields[0];
    final path = fields[2];
    final name = fields[5];
    if (domain.isEmpty || name.isEmpty) return null;
    return CookieJarEntry(
      domain: domain,
      includeSubdomains: _bool(fields[1]),
      path: path.isEmpty ? '/' : path,
      secure: _bool(fields[3]),
      expiry: _expiry(fields[4]),
      name: name,
      value: value,
      httpOnly: httpOnly,
    );
  }

  static bool _bool(String raw) => raw.trim().toUpperCase() == 'TRUE';

  /// Epoch seconds, where `0` and the empty string both mean
  /// a session cookie. yt-dlp's own docs use 0 for
  /// "no expiry"; a browser writes either.
  static DateTime? _expiry(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final seconds = int.tryParse(trimmed);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }
}
