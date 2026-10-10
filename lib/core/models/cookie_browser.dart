/// Where yt-dlp should get cookies from, when the answer is not a file.
///
/// The usual answer is the imported `cookies.txt` (`AppSettings.cookiesPath`),
/// which the app can filter site by site. A browser store cannot be: yt-dlp
/// reads it directly, so anything the user switched off there would be sent
/// anyway. That is why this is a *separate source* rather than another setting
/// on the jar — the two are never combined, and [cookieArgs] is the single place
/// that decides.
///
/// ## Why a profile *name* rather than a path
///
/// yt-dlp splits `BROWSER[+KEYRING][:PROFILE][::CONTAINER]` on the first `:` of
/// each field, resolves a profile name against the browser root it computes
/// itself, and treats a profile starting with a path separator as an *absolute
/// path*. It also accepts `:` and `+` inside a profile name without complaint.
///
/// The app passes a name because yt-dlp recomputes the browser root on every
/// run, and a root stored in a settings box goes stale the moment the browser
/// is reinstalled, moved to a new machine or relocated. A name is resolved
/// fresh each time, so it keeps working where a remembered path would not.
///
/// That name is validated by [checkProfileName] at the point the argument is
/// built ([cookieBrowserSpec]), not only in the picker UI: the value reaches
/// yt-dlp by more routes than the picker — a restored backup writes it straight
/// into the settings box, and `AppSettings.fromMap` reads it back as a bare
/// string. A check the picker performs on its own therefore guards nothing, and
/// the picker's own message ("yt-dlp was not pointed at it") would be a lie.
/// Only path syntax is refused, and only because a path is read as one.
///
/// The picker exists to answer "which profile?" with a list of names that
/// exist rather than a guess: a wrong name is a hard error at download time,
/// not a warning.
library;

/// The browsers yt-dlp can read cookies from.
///
/// [argument] is yt-dlp's own spelling because that is what goes on the command
/// line; [label] is for the UI and never for the argument.
enum CookieBrowser {
  brave('brave', 'Brave'),
  chrome('chrome', 'Google Chrome'),
  chromium('chromium', 'Chromium'),
  edge('edge', 'Microsoft Edge'),
  firefox('firefox', 'Firefox'),
  opera('opera', 'Opera'),
  safari('safari', 'Safari'),
  vivaldi('vivaldi', 'Vivaldi'),
  whale('whale', 'Whale');

  const CookieBrowser(this.argument, this.label);

  /// yt-dlp's name for it, which is what `--cookies-from-browser` takes.
  final String argument;

  /// What the picker shows.
  final String label;

  /// Safari's cookies live in a system keychain file and its layout is nothing
  /// like the others, so the desktop-only gate is not the whole story: on Linux
  /// and Windows yt-dlp has no way to read them either.
  bool get isMacOnly => this == CookieBrowser.safari;

  /// The entry for [value], or null if yt-dlp would not recognise it.
  ///
  /// Matching is case- and whitespace-insensitive because the value may have
  /// come from a hand-edited settings box, but anything unrecognised is dropped
  /// rather than passed through — a typo here would otherwise fail every
  /// download on an argument yt-dlp rejects.
  static CookieBrowser? byArgument(String value) {
    final wanted = value.trim().toLowerCase();
    for (final b in values) {
      if (b.argument == wanted) return b;
    }
    return null;
  }
}

/// Why a profile cannot be used.
enum ProfileProblem {
  /// A folder with no browser profiles in it.
  notAProfileRoot,

  /// A path where a profile name belongs.
  notAProfileName,
}

extension ProfileProblemMessage on ProfileProblem {
  /// What to show the user.
  String? get message => switch (this) {
    ProfileProblem.notAProfileRoot =>
      'That folder has no browser profiles in it. Pick the folder that '
          'contains them, not a profile itself.',
    ProfileProblem.notAProfileName =>
      'That is a path, not a profile name. Give just the profile folder name, '
          'such as "Default" or "Profile 2" — the browser directory itself is '
          'chosen above.',
  };
}

/// Returns the problem with [profile], or `null` when it is fine to pass to
/// yt-dlp.
///
/// yt-dlp treats a profile argument beginning with a path separator as an
/// *absolute path* rather than a name, so without this check a hand-edited
/// settings box could aim the cookie read at any directory on the device. An
/// empty name is fine: it means the browser's own default profile.
///
/// `:` and `+` are legal in profile names (Firefox and Chromium use them), so
/// only genuine path syntax is rejected.
ProfileProblem? checkProfileName(String profile) {
  final name = profile.trim();
  if (name.isEmpty) return null;
  if (name.startsWith('/') || name.startsWith(r'\')) {
    return ProfileProblem.notAProfileName;
  }
  return null;
}

/// The yt-dlp specification for a browser and profile, or null when there is no
/// browser or the profile cannot be spelled.
///
/// Null rather than the bare browser name for an unusable profile, so the caller
/// has to make a decision about a configuration it does not understand instead
/// of silently asking for a different one.
///
/// The profile is validated by [checkProfileName] *here*, at the one place that
/// builds the argument, rather than only in the picker UI. The value can arrive
/// without ever passing through that UI — a restored backup writes it straight
/// into the settings box, and `AppSettings.fromMap` reads it as a bare string —
/// so a check the UI performs on its own guards nothing. An invalid profile
/// falls back to the browser's own default, which is what an empty name means
/// anyway.
String? cookieBrowserSpec({
  required CookieBrowser? browser,
  String profile = '',
}) {
  if (browser == null) return null;
  final name = profile.trim();
  if (name.isEmpty) return browser.argument;
  // A path is a path: yt-dlp would read it as one, so the profile is dropped
  // rather than the user's browser root abandoned. See [checkProfileName].
  if (checkProfileName(name) != null) return null;
  return '${browser.argument}:$name';
}

/// The single cookie source in effect.
enum CookieSource {
  /// Nothing configured.
  none,

  /// The imported jar, which the app filters per site.
  file,

  /// The browser's own store, which it cannot.
  browser,
}

/// Why `--cookies-from-browser` cannot be used here, or null when it can.
///
/// Takes the platform as plain booleans rather than reading `Platform` or
/// `kIsWeb` itself, because "does this platform get an explanation or a
/// silent absence" is the part worth testing and neither is reachable from a
/// test otherwise. The caller passes the real values.
String? cookieBrowserBlock({
  required bool isWeb,
  required bool isMobile,
  required bool isMacOS,
}) {
  if (isWeb) {
    return "A browser build can't read this computer's browsers.";
  }
  if (isMobile) {
    // Not "unavailable": the platform has no facility for it at all. Android
    // sandboxes app storage per-app and per-profile, so there is no cookie
    // store an app could be given, and the Android browser keeps its own.
    return "This platform gives apps no access to a browser's cookies, so "
        'there is nothing to read. Import a cookies.txt instead.';
  }
  return null;
}

/// Which source a configuration resolves to.
///
/// A browser source wins when set, because it is the newer intent: the user
/// asked for their login to come from where they are already logged in. The
/// file's presence is reported alongside by [cookieArgs]' caller so the UI can
/// say it is being set aside rather than dropping it unnoticed.
CookieSource resolveCookieSource({
  required String cookiesPath,
  required String cookieBrowser,
}) {
  if (CookieBrowser.byArgument(cookieBrowser) != null) {
    return CookieSource.browser;
  }
  if (cookiesPath.trim().isNotEmpty) return CookieSource.file;
  return CookieSource.none;
}

/// The cookie flags for a download, as yt-dlp arguments.
///
/// Empty when nothing is configured. At most one flag pair, ever — see
/// [CookieSource].
///
/// An unrecognised [cookieBrowser] falls back to the file jar rather than being
/// passed on, so a typo cannot break every download; [CookieBrowser.byArgument]
/// is what decides, and the UI reports the fallback when it happens.
List<String> cookieArgs({
  String? cookiesPath,
  String? cookieBrowser,
  String cookieBrowserProfile = '',
}) {
  final browser = CookieBrowser.byArgument(cookieBrowser ?? '');
  if (browser != null) {
    return [
      '--cookies-from-browser',
      cookieBrowserSpec(browser: browser, profile: cookieBrowserProfile) ??
          browser.argument,
    ];
  }
  final file = cookiesPath?.trim() ?? '';
  return file.isEmpty ? const [] : ['--cookies', file];
}
