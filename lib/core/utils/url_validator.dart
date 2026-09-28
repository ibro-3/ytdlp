final _urlRe = RegExp(r'^https?://\S+$', caseSensitive: false);

/// Matches an http(s) URL inside a blob of text. It stops at whitespace and at
/// characters that wrap a link in quotes/brackets, and allows one balanced
/// `(...)` group so paths like `/wiki/Foo_(bar)` survive.
final _embeddedUrlRe = RegExp(
  r'''https?://[^\s<>"'\[\]{}()]+(?:\([^\s)]*\)[^\s<>"'\]\}]*)?''',
  caseSensitive: false,
);

bool isValidUrl(String input) {
  final s = input.trim();
  if (s.isEmpty) return false;
  return _urlRe.hasMatch(s);
}

/// Every usable URL in [input], in the order they appear, de-duplicated.
///
/// A clipboard or share payload can legitimately hold several links — a chat
/// message with two videos, a saved list, a channel's page plus a video from
/// it. [extractUrl] returns only the first, which is right for the single-video
/// flow but silently discards the rest when someone means to queue all of them.
List<String> extractUrls(String input) {
  final found = <String>[];
  final seen = <String>{};
  for (final match in _embeddedUrlRe.allMatches(input)) {
    var url = match.group(0) ?? '';
    // Trailing sentence punctuation is almost never part of the URL.
    while (url.isNotEmpty && '.,;:!?'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (!isValidUrl(url)) continue;
    // The same link twice is one download, not two.
    if (seen.add(url)) found.add(url);
  }
  return found;
}

/// Pulls a usable video URL out of [input], or null when there isn't one.
///
/// Accepts either a bare URL or one embedded in shared text (a message, a page
/// title, "check this out https://youtu.be/…"), which is what a clipboard
/// usually holds after sharing from another app.
String? extractUrl(String input) {
  final trimmed = input.trim();
  // A whole-line URL is returned verbatim, so a bare link is never mangled by
  // the embedded matcher.
  if (isValidUrl(trimmed)) return trimmed;
  final urls = extractUrls(trimmed);
  return urls.isEmpty ? null : urls.first;
}
