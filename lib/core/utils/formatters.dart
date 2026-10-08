String formatBytes(num bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

String formatDuration(int totalSeconds) {
  final d = Duration(seconds: totalSeconds);
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '$m:${two(s)}';
}

String formatDate(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Reads the `YYYYMMDD` upload date yt-dlp reports.
///
/// Returns null for anything that is not exactly that shape. `DateTime.parse`
/// is not strict enough on its own: it accepts an out-of-range month or day and
/// silently rolls them over, so `'99999999'` would become the year 10007 rather
/// than being rejected. Since this feeds a filename, a plausible-looking wrong
/// date is worse than none, so the fields are checked before parsing.
DateTime? parseUploadDate(String? s) {
  if (s == null || s.length != 8) return null;
  for (var i = 0; i < 8; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return null; // not an ASCII digit
  }
  final year = int.parse(s.substring(0, 4));
  final month = int.parse(s.substring(4, 6));
  final day = int.parse(s.substring(6, 8));
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  // Catches the impossible combinations the range checks above allow through,
  // such as the 31st of February, which would otherwise roll into March.
  final parsed = DateTime(year, month, day);
  if (parsed.month != month || parsed.day != day) return null;
  return parsed;
}
