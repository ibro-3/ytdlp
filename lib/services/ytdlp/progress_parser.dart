class YtdlpProgressData {
  const YtdlpProgressData({this.progress, this.speed, this.eta});
  final double? progress;
  final String? speed;
  final String? eta;
}

class YtdlpProgressParser {
  static final RegExp _progressRe = RegExp(
    r'^\[download\]\s+([\d.]+)%'
    r'(?: of ~?([\d.]+)([KMGT]?i?B))?'
    r'(?: at\s+([\d.]+(?:\.\d+)?)([KMGT]?i?B/s))?'
    r'(?: ETA ([\d:]+|Unknown))?',
  );

  static final RegExp _destinationRe = RegExp(
    r'^\[download\] Destination: (.+)$',
  );
  static final RegExp _mergerRe = RegExp(
    r'^\[Merger\] Merging formats into "(.+)"$',
  );
  static final RegExp _errorRe = RegExp(r'^ERROR:\s*(.+)$');
  static final RegExp _warningRe = RegExp(r'^WARNING:\s*(.+)$');

  static YtdlpProgressData? parseProgress(String line) {
    final m = _progressRe.firstMatch(line);
    if (m == null || m.group(1) == null) return null;
    final percent = double.tryParse(m.group(1)!);
    String? speed;
    if (m.group(4) != null && m.group(5) != null) {
      speed = '${m.group(4)} ${m.group(5)}';
    }
    return YtdlpProgressData(
      progress: percent == null ? null : (percent / 100).clamp(0, 1).toDouble(),
      speed: speed,
      eta: m.group(6),
    );
  }

  static String? parseDestination(String line) {
    final m = _destinationRe.firstMatch(line);
    return m?.group(1)?.trim();
  }

  static String? parseMergedFile(String line) {
    final m = _mergerRe.firstMatch(line);
    return m?.group(1)?.trim();
  }

  static String? parseError(String line) {
    final m = _errorRe.firstMatch(line);
    return m?.group(1)?.trim();
  }

  /// Warnings that are pure noise on a queue card.
  ///
  /// All of them say the same thing — this machine has no JavaScript runtime, so
  /// YouTube's signature challenge could not be solved and some formats were
  /// skipped. yt-dlp splits that across several lines, and the app was showing
  /// the first one verbatim on a completed card, which reads as a problem with
  /// the download the user just made rather than with the machine's setup.
  ///
  /// Silently dropping them is the right call: the app owns a JS runtime
  /// installer in Settings, so the fix has somewhere to live, and the download
  /// itself succeeded with whatever formats were available.
  static final List<RegExp> _ignoredWarningRes = [
    RegExp(r'No supported JavaScript runtime', caseSensitive: false),
    // "nsig extraction failed", "Signature solving failed", "n challenge
    // solving failed" — the same root cause in yt-dlp's older and newer
    // wordings.
    RegExp(
      r'(nsig|Signature|signature|n challenge) (extraction|solving) failed',
    ),
    RegExp(
      r'Ensure you have a supported JavaScript runtime',
      caseSensitive: false,
    ),
  ];

  static String? parseWarning(String line) {
    final m = _warningRe.firstMatch(line);
    final text = m?.group(1)?.trim();
    if (text == null) return null;
    for (final re in _ignoredWarningRes) {
      if (re.hasMatch(text)) return null;
    }
    return text;
  }
}
