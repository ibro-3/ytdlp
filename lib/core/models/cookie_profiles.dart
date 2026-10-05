import 'dart:io';

/// The profile names found under a browser profile root.
///
/// A *name*, never a path, because that is the only thing the app is willing to
/// put on the command line — see the library doc in `cookie_browser.dart`.
///
/// A directory counts as a profile when it actually contains a cookie store,
/// rather than when its name looks like one. Chromium keeps `Cookies` (Linux)
/// or `Network/Cookies` (Windows, macOS); Firefox keeps `cookies.sqlite`.
/// Both rules are checked at depth one only, because a profile root's own parent
/// is full of things that are not profiles and a recursive walk would report the
/// whole browser installation.
///
/// Ordered with the browser's own default first, then alphabetically, so the
/// list matches what the user sees in their browser's profile switcher.
List<String> profileNamesIn(String root) {
  final Directory dir = Directory(root);
  if (!dir.existsSync()) return const [];
  final found = <String>[];
  try {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.isEmpty || name.startsWith('.')) continue;
      if (_looksLikeProfile(entity.path)) found.add(name);
    }
  } on FileSystemException {
    // An unreadable or half-removed folder is a state the picker explains, not
    // a crash, and returning nothing says so honestly.
    return const [];
  }
  found.sort((a, b) {
    // Default first, then alphabetically — the order a browser's own profile
    // switcher lists them in, so the picker is recognisable.
    final aIsDefault = _isDefaultName(a);
    final bIsDefault = _isDefaultName(b);
    if (aIsDefault != bIsDefault) return aIsDefault ? -1 : 1;
    return a.toLowerCase().compareTo(b.toLowerCase());
  });
  return List.unmodifiable(found);
}

bool _looksLikeProfile(String path) {
  // Chromium: a bare `Cookies` file, or the Windows/macOS `Network` subfolder.
  if (File('$path/Cookies').existsSync()) return true;
  if (File('$path/Network/Cookies').existsSync()) return true;
  // Firefox.
  if (File('$path/cookies.sqlite').existsSync()) return true;
  return false;
}

/// Whether a directory name is the browser's default profile.
///
/// Both spellings, because they are the two the browsers actually use:
/// Chromium's `Default`, Firefox's `xxxxxxxx.default-release`.
bool _isDefaultName(String name) {
  final lower = name.toLowerCase();
  return lower == 'default' ||
      lower.endsWith('.default-release') ||
      lower.endsWith('.default');
}
