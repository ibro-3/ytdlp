import 'dart:convert';
import 'dart:collection';

/// Which end of a stream to retain once it exceeds its budget.
enum CaptureKeep { head, tail }

/// Accumulates process output up to a byte budget without letting a runaway
/// process exhaust memory.
///
/// Why the two modes exist:
/// - *head* keeps everything written while under the budget, because that
///   payload is what the caller must parse — truncating it would corrupt a
///   good response. Memory is bounded by [maxBytes] because the caller stops
///   the process (see the `false` return) as soon as the budget is crossed.
/// - *tail* keeps only the last [windowChars] characters, so a chatty stderr
///   stays cheap even while the byte count runs away (the count keeps rising
///   so the caller can still detect a flood).
class BoundedCapture {
  BoundedCapture({
    required this.maxBytes,
    this.keep = CaptureKeep.head,
    this.windowChars = 64 * 1024,
  });

  /// The stream is considered flooded past this many UTF-16 code units.
  ///
  /// Named "bytes" for historical reasons; see [add] for what it actually
  /// measures.
  final int maxBytes;

  /// Which end to retain.
  final CaptureKeep keep;

  /// Maximum characters retained in tail mode.
  final int windowChars;

  int _seen = 0;
  bool _overflowed = false;
  // Retained text as chunks rather than one grown-by-concatenation string.
  // Strings are immutable in Dart, so `_buf += chunk` copies the whole buffer
  // every time; a large metadata payload arriving in thousands of line-sized
  // chunks made head retention quadratic in the payload size — the exact
  // case the flood guard exists to survive. Joining happens once, on read.
  final Queue<String> _parts = Queue<String>();
  int _len = 0;

  /// Units seen on the stream, including those dropped after the budget.
  ///
  /// UTF-16 code units, not bytes — see [add]. Reported to the user through
  /// `formatBytesShort`, so it can overstate a multi-byte payload by up to 3×.
  int get bytes => _seen;

  bool get overflowed => _overflowed;

  /// The retained text: the full payload in head mode (up to [maxBytes]), or
  /// the last [windowChars] characters in tail mode.
  String get text => _parts.join();

  /// Feeds a chunk. Returns false once the budget is exhausted, so a caller
  /// can stop a process that is flooding it.
  ///
  /// The budget is measured in UTF-16 code units, not bytes: [maxBytes] is
  /// compared against `chunk.length`, so a multi-byte payload under-counts by up
  /// to three times per character. Callers decode with `lenientDecoder` before
  /// reaching here, which is what makes that worth stating. For the numbers
  /// actually used (16 MB of stdout) the difference is a ceiling of tens of MB
  /// of heap on a phone rather than an unbounded buffer — the flood *detection*
  /// is what matters, and it still happens.
  bool add(String chunk) {
    if (chunk.isEmpty) return !_overflowed;
    _seen += chunk.length;
    if (_seen > maxBytes) {
      _overflowed = true;
      // Head mode: stop retaining here — the payload past the budget would
      // only be dropped after the caller kills the process anyway.
      if (keep == CaptureKeep.head) return false;
      _slide(chunk);
      return false;
    }
    if (keep == CaptureKeep.head) {
      _parts.addLast(chunk);
      _len += chunk.length;
    } else {
      _slide(chunk);
    }
    return true;
  }

  void _slide(String chunk) {
    _parts.addLast(chunk);
    _len += chunk.length;
    if (_len <= windowChars) return;
    // Drop whole chunks from the front while the window can afford to lose
    // them; when the cutoff lands inside a chunk, that chunk — and only that
    // one — is split. Every retained byte is visited at most once this way,
    // versus the old per-chunk copy of the whole window.
    while (_parts.isNotEmpty && _len - _parts.first.length >= windowChars) {
      _len -= _parts.removeFirst().length;
    }
    if (_len > windowChars) {
      final first = _parts.removeFirst();
      // The cutoff lands inside this chunk: drop everything in front of it so
      // exactly the last [windowChars] characters survive.
      _parts.addFirst(first.substring(_len - windowChars));
      _len = windowChars;
    }
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
