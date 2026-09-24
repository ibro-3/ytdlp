import 'dart:convert';

/// Decodes yt-dlp's `-J` payload from [raw].
///
/// Tolerates a short non-JSON preamble: the bundled Python runtime on Android
/// has been known to print a stray warning to stdout before the JSON, and one
/// such line must not turn a good fetch into "invalid JSON". Returns null when
/// the payload is genuinely unreadable.
Object? decodeYtdlpPayload(String raw) {
  var ok = false;
  dynamic result;

  void attempt(String s) {
    if (ok) return;
    try {
      result = jsonDecode(s);
      ok = true;
    } on FormatException {
      // Keep looking.
    }
  }

  attempt(raw);
  if (!ok) {
    // Try again from the first JSON-opening brace or bracket, capped so a
    // long garbage preamble cannot cause a wasteful re-decode.
    for (final marker in const ['{', '[']) {
      final i = raw.indexOf(marker);
      if (i > 0 && i <= 8 * 1024) {
        attempt(raw.substring(i));
        if (ok) break;
      }
    }
  }
  return ok ? result : null;
}

/// Explains an unreadable payload so the message names what actually came
/// back instead of the generic "invalid JSON".
String jsonFailureMessage(String raw) {
  final trimmed = raw.trimLeft();
  if (trimmed.isEmpty) {
    return 'yt-dlp sent no data back.\n'
        'Try again, or update yt-dlp in Settings.';
  }
  final preview = trimmed.length > 160 ? trimmed.substring(0, 160) : trimmed;
  final shown = preview.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
  return 'yt-dlp sent a response the app could not read.\n'
      'It began with: $shown';
}
