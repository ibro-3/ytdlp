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
}
