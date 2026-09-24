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

/// Pulls a usable video URL out of [input], or null when there isn't one.
///
/// Accepts either a bare URL or one embedded in shared text (a message, a page
/// title, "check this out https://youtu.be/…"), which is what a clipboard
/// usually holds after sharing from another app.
String? extractUrl(String input) {
  final trimmed = input.trim();
  if (isValidUrl(trimmed)) return trimmed;
  final match = _embeddedUrlRe.firstMatch(trimmed);
  if (match == null) return null;
  var url = match.group(0) ?? '';
  // Trailing sentence punctuation is almost never part of the URL.
  while (url.isNotEmpty && '.,;:!?'.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return isValidUrl(url) ? url : null;
}
