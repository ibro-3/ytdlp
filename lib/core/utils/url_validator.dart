final _urlRe = RegExp(r'^https?://\S+$', caseSensitive: false);

bool isValidUrl(String input) {
  final s = input.trim();
  if (s.isEmpty) return false;
  return _urlRe.hasMatch(s);
}
