import 'dart:convert';

/// Which end of a stream to retain once it exceeds its budget.
enum CaptureKeep { head, tail }

/// Accumulates process output up to a byte budget without letting a runaway
/// process exhaust memory.
///
/// What is retained is deliberately small and bounded: the *head* (to tell
/// what kind of payload arrived) or the *tail* (where a traceback ends). The
/// byte count keeps rising past the budget so callers can detect a flood, but
/// the retained text never does.
class BoundedCapture {
  BoundedCapture({
    required this.maxBytes,
    this.keep = CaptureKeep.head,
    this.windowChars = 64 * 1024,
  });

  /// The stream is considered flooded past this many bytes.
  final int maxBytes;

  /// Which end to retain.
  final CaptureKeep keep;

  /// Maximum characters retained: the head prefix, or the tail window.
  final int windowChars;

  int _seen = 0;
  bool _overflowed = false;
  String _buf = '';

  /// Bytes seen on the stream, including those dropped after the budget.
  int get bytes => _seen;

  bool get overflowed => _overflowed;

  /// The retained head or tail. Bounded by [windowChars].
  String get text => _buf;

  /// Feeds a chunk. Returns false once the budget is exhausted, so a caller
  /// can stop a process that is flooding it.
  bool add(String chunk) {
    if (chunk.isEmpty) return !_overflowed;
    _seen += chunk.length;
    if (_seen > maxBytes) _overflowed = true;

    if (keep == CaptureKeep.head) {
      if (_buf.length < windowChars) {
        final room = windowChars - _buf.length;
        _buf += room >= chunk.length ? chunk : chunk.substring(0, room);
      }
    } else {
      _buf += chunk;
      if (_buf.length > windowChars) {
        _buf = _buf.substring(_buf.length - windowChars);
      }
    }
    return !_overflowed;
  }

  /// Whether [text] looks like a yt-dlp playlist payload.
  ///
  /// Searching the retained head is enough: `_type` is one of the first
  /// fields yt-dlp emits.
  static bool looksLikePlaylist(String text) =>
      text.contains('"_type": "playlist"') ||
      text.contains('"_type":"playlist"');
}

/// Formats a byte count for an error message.
String formatBytesShort(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// Decoder for process output that never throws on malformed input: one bad
/// byte from a site must not blank out a metadata fetch.
final lenientDecoder = Utf8Decoder(allowMalformed: true);
