import 'package:flutter/material.dart';

import 'output_template.dart';
import 'youtube_prefs.dart';
import 'yt_prefs.dart';

/// Persisted user preferences. Stored as a plain map in the Hive
/// `settings` box so no codegen is needed.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.seedColor = 0xFFD32F2F,
    this.defaultVideoTier = 720,
    this.defaultAudioOnly = false,
    this.defaultAudioTier,
    this.notificationsEnabled = true,
    this.defaultEmbedSubs = false,
    this.defaultWriteSubs = false,
    this.defaultIncludeAutoSubs = false,
    this.wifiOnly = false,
    this.cookiesPath = '',
    this.cookieSourcePath = '',
    this.cookieDisabledDomains = const [],
    this.cookieBrowser = '',
    this.cookieBrowserProfile = '',
    this.cookieBrowserRootPath = '',
    this.downloadRoot = '',
    this.extraArgs = '',
    this.outputTemplate = '',
    this.ytPrefs = const YtPrefs(),
    this.youtube = const YoutubePrefs(),
    // null means "not set", and the platform default is used instead: one
    // parallel download on Android, two on desktop.
    this.maxConcurrency,
    this.maxQueueSize = 50,
  });

  /// Null tier = Best quality.
  static const List<int?> videoTierOptions = [null, 1080, 720, 480, 360];

  /// Audio quality tiers from [VideoInfo.audioTiers]; null = best available.
  static const List<int?> audioTierOptions = [null, 192, 128, 96];

  static const List<(String, int)> seedOptions = [
    ('Red', 0xFFD32F2F),
    ('Blue', 0xFF1565C0),
    ('Green', 0xFF2E7D32),
    ('Purple', 0xFF6A1B9A),
    ('Orange', 0xFFEF6C00),
    ('Teal', 0xFF00838F),
  ];

  final ThemeMode themeMode;
  final int seedColor;
  final int? defaultVideoTier;
  final bool defaultAudioOnly;

  /// Audio tier matching [AppSettings.audioTierOptions]; null = best.
  final int? defaultAudioTier;
  final bool notificationsEnabled;

  /// When true, new downloads only start on an unmetered network (Wi-Fi or
  /// Ethernet). A running download is never killed when the network changes —
  /// the restriction applies to *starting* work, which is the moment the cost
  /// is incurred. Applies on Android; desktop always has a fixed connection.
  final bool wifiOnly;

  /// Optional Netscape-format `cookies.txt` handed to yt-dlp via `--cookies`.
  /// Some sites (notably YouTube) refuse anonymous requests; a cookie jar
  /// lets the user authenticate without the app storing any credentials.
  /// Empty = no cookies.
  ///
  /// This points at the *generated* jar, which is the full import minus the
  /// sites the user switched off in [cookieDisabledDomains]. yt-dlp is only
  /// ever given this path.
  final String cookiesPath;

  /// The jar exactly as imported, kept unmodified so a site can be switched
  /// back on without asking the user to export it from their browser again.
  ///
  /// Empty when [cookiesPath] predates per-site management, in which case the
  /// UI falls back to treating [cookiesPath] itself as the source.
  final String cookieSourcePath;

  /// Hosts whose cookies are withheld from yt-dlp, as keys from
  /// `cookieHostKey` (lower-case, no leading dot).
  ///
  /// Hosts are not names of credentials — they are already in the file, the
  /// download log and the diagnostics report — so storing and reporting these is
  /// safe. What is never stored, logged or reported is a cookie *value*.
  final List<String> cookieDisabledDomains;

  /// yt-dlp's name for a browser to read cookies from, or empty for none.
  ///
  /// Set, this *replaces* [cookiesPath] on the command line rather than adding
  /// to it — yt-dlp would merge the two and a site switched off in
  /// [cookieDisabledDomains] would go out anyway. See `cookie_browser.dart` for
  /// why that guarantee cannot be kept otherwise.
  ///
  /// The value is validated against `CookieBrowser` before use; an unrecognised
  /// one falls back to the file jar rather than being passed through to a
  /// download that would fail on an argument it does not understand.
  final String cookieBrowser;

  /// Which profile of [cookieBrowser] to read, by *name* (`Default`, `Profile
  /// 2`). Empty means the browser's default profile.
  ///
  /// A name and never a path: yt-dlp splits the specification on `:`, so a
  /// Windows path would parse as a different browser entirely.
  final String cookieBrowserProfile;

  /// The folder the user pointed [CookieProfilePicker] at, so the profile names
  /// can be listed without asking again.
  ///
  /// Read by the app only. Never passed to yt-dlp, and never reported in
  /// diagnostics: a path can carry a username, exactly like the jar path.
  /// Surfaced by the cookie settings section's folder picker.
  final String cookieBrowserRootPath;

  /// Root folder for downloads; empty means the platform default
  /// (`downloadsDir` in providers.dart). Videos and audio go into a
  /// `Video/` / `Audio/` subfolder of this root.
  final String downloadRoot;

  /// Extra yt-dlp flags applied to every download, as typed.
  ///
  /// Tokenised on use and appended ahead of the flags the app manages, so a
  /// user-supplied `-o` or `-f` cannot redirect the output or change the stream
  /// out from under the staging/finalize logic. See `validateExtraArgs` for
  /// what gets reported back to the user.
  final String extraArgs;

  /// Output template (`-o`) for downloaded files. Empty means
  /// [OutputTemplate.defaultTemplate].
  ///
  /// Must resolve to a filename with an extension, since the manager decides
  /// which file is the media file by extension.
  final String outputTemplate;

  /// The template actually used, with the blank case resolved.
  OutputTemplate get effectiveOutputTemplate => OutputTemplate(outputTemplate);

  /// First-class yt-dlp capabilities: fragment parallelism, rate limits,
  /// postprocessing choices, proxy. All are also reachable through
  /// [extraArgs]; these exist because each has a value that must be right.
  final YtPrefs ytPrefs;

  /// YouTube player clients and JS-runtime preference.
  final YoutubePrefs youtube;

  /// How many downloads may run at once. `null` defers to the platform default
  /// (1 on Android, 2 on desktop) so the value is right without the user having
  /// to choose it.
  final int? maxConcurrency;

  /// The concurrency actually in force, resolved against [isMobile].
  int resolveConcurrency({required bool isMobile}) =>
      maxConcurrency ?? (isMobile ? 1 : 2);

  /// How many task snapshots to keep for restart recovery.
  ///
  /// 50 is enough for a session; a larger playlist needs a higher value or the
  /// oldest entries are lost on restart. Anything above the cap only affects
  /// what survives a restart — queued work still runs in the current session.
  final int maxQueueSize;

  /// Concurrency bounds. The ceiling is a resource limit, not a preference.
  static const int concurrencyMin = 1;
  static const int concurrencyMax = 8;
  static const int queueSizeMin = 10;
  static const int queueSizeMax = 500;

  /// Defaults seeded into the download sheet. Embed options are only honored
  /// when ffmpeg is available (bundled on Android, inferred on desktop).
  ///
  /// There is no thumbnail default here: cover art is derived from the download
  /// kind by `DownloadOptions.coverArtDefault` rather than offered as a toggle,
  /// so a stored `defaultEmbedThumb` from an older build is simply ignored.
  final bool defaultEmbedSubs;
  final bool defaultWriteSubs;
  final bool defaultIncludeAutoSubs;

  Color get seed => Color(seedColor);

  String get tierLabel =>
      defaultVideoTier == null ? 'Best' : '${defaultVideoTier}p';

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? seedColor,
    int? Function()? defaultVideoTier,
    bool? defaultAudioOnly,
    int? Function()? defaultAudioTier,
    bool? notificationsEnabled,
    bool? defaultEmbedSubs,
    bool? defaultWriteSubs,
    bool? defaultIncludeAutoSubs,
    bool? wifiOnly,
    String? cookiesPath,
    String? cookieSourcePath,
    List<String>? cookieDisabledDomains,
    String? cookieBrowser,
    String? cookieBrowserProfile,
    String? cookieBrowserRootPath,
    String? downloadRoot,
    String? extraArgs,
    String? outputTemplate,
    YtPrefs? ytPrefs,
    YoutubePrefs? youtube,
    int? Function()? maxConcurrencySetter,
    int? maxQueueSize,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      seedColor: seedColor ?? this.seedColor,
      defaultVideoTier: defaultVideoTier != null
          ? defaultVideoTier()
          : this.defaultVideoTier,
      defaultAudioOnly: defaultAudioOnly ?? this.defaultAudioOnly,
      defaultAudioTier: defaultAudioTier != null
          ? defaultAudioTier()
          : this.defaultAudioTier,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      defaultEmbedSubs: defaultEmbedSubs ?? this.defaultEmbedSubs,
      defaultWriteSubs: defaultWriteSubs ?? this.defaultWriteSubs,
      defaultIncludeAutoSubs:
          defaultIncludeAutoSubs ?? this.defaultIncludeAutoSubs,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      cookiesPath: cookiesPath ?? this.cookiesPath,
      cookieSourcePath: cookieSourcePath ?? this.cookieSourcePath,
      cookieDisabledDomains:
          cookieDisabledDomains ?? this.cookieDisabledDomains,
      cookieBrowser: cookieBrowser ?? this.cookieBrowser,
      cookieBrowserProfile: cookieBrowserProfile ?? this.cookieBrowserProfile,
      cookieBrowserRootPath:
          cookieBrowserRootPath ?? this.cookieBrowserRootPath,
      downloadRoot: downloadRoot ?? this.downloadRoot,
      extraArgs: extraArgs ?? this.extraArgs,
      outputTemplate: outputTemplate ?? this.outputTemplate,
      ytPrefs: ytPrefs ?? this.ytPrefs,
      youtube: youtube ?? this.youtube,
      // The setter thunk distinguishes three cases: omitted keeps the current
      // value, `() => null` clears the override back to the platform default,
      // and `() => n` sets one.
      maxConcurrency: switch (maxConcurrencySetter?.call()) {
        final int value => value.clamp(concurrencyMin, concurrencyMax),
        null when maxConcurrencySetter != null => null,
        _ => maxConcurrency,
      },
      maxQueueSize: (maxQueueSize ?? this.maxQueueSize).clamp(
        queueSizeMin,
        queueSizeMax,
      ),
    );
  }

  Map<String, dynamic> toMap() => {
    'themeMode': themeMode.name,
    'seedColor': seedColor,
    'defaultVideoTier': defaultVideoTier,
    'defaultAudioOnly': defaultAudioOnly,
    'defaultAudioTier': defaultAudioTier,
    'notificationsEnabled': notificationsEnabled,
    'defaultEmbedSubs': defaultEmbedSubs,
    'defaultWriteSubs': defaultWriteSubs,
    'defaultIncludeAutoSubs': defaultIncludeAutoSubs,
    'wifiOnly': wifiOnly,
    'cookiesPath': cookiesPath,
    'cookieSourcePath': cookieSourcePath,
    'cookieDisabledDomains': cookieDisabledDomains,
    'cookieBrowser': cookieBrowser,
    'cookieBrowserProfile': cookieBrowserProfile,
    'cookieBrowserRootPath': cookieBrowserRootPath,
    'downloadRoot': downloadRoot,
    'extraArgs': extraArgs,
    'outputTemplate': outputTemplate,
    'ytPrefs': ytPrefs.toMap(),
    'youtube': youtube.toMap(),
    'maxConcurrency': maxConcurrency,
    'maxQueueSize': maxQueueSize,
  };

  factory AppSettings.fromMap(Map<String, dynamic> m) {
    ThemeMode mode = ThemeMode.system;
    try {
      mode = ThemeMode.values.byName(m['themeMode'] as String? ?? 'system');
    } catch (_) {}
    return AppSettings(
      themeMode: mode,
      seedColor: (m['seedColor'] as num?)?.toInt() ?? 0xFFD32F2F,
      defaultVideoTier: (m['defaultVideoTier'] as num?)?.toInt(),
      defaultAudioOnly: (m['defaultAudioOnly'] as bool?) ?? false,
      defaultAudioTier: (m['defaultAudioTier'] as num?)?.toInt(),
      notificationsEnabled: (m['notificationsEnabled'] as bool?) ?? true,
      defaultEmbedSubs: (m['defaultEmbedSubs'] as bool?) ?? false,
      defaultWriteSubs: (m['defaultWriteSubs'] as bool?) ?? false,
      defaultIncludeAutoSubs: (m['defaultIncludeAutoSubs'] as bool?) ?? false,
      wifiOnly: (m['wifiOnly'] as bool?) ?? false,
      cookiesPath: (m['cookiesPath'] as String?) ?? '',
      cookieSourcePath: (m['cookieSourcePath'] as String?) ?? '',
      // Read defensively: a hand-edited or downgraded box must not be able to
      // store a non-string, and the sort makes the stored form deterministic so
      // an unchanged jar does not rewrite the key on every save.
      cookieDisabledDomains: [
        for (final d in (m['cookieDisabledDomains'] as List?) ?? const [])
          if (d is String && d.isNotEmpty) d,
      ]..sort(),
      cookieBrowser: (m['cookieBrowser'] as String?) ?? '',
      cookieBrowserProfile: (m['cookieBrowserProfile'] as String?) ?? '',
      cookieBrowserRootPath: (m['cookieBrowserRootPath'] as String?) ?? '',
      downloadRoot: (m['downloadRoot'] as String?) ?? '',
      extraArgs: (m['extraArgs'] as String?) ?? '',
      outputTemplate: (m['outputTemplate'] as String?) ?? '',
      ytPrefs: YtPrefs.fromMap((m['ytPrefs'] as Map?)?.cast<String, dynamic>()),
      youtube: YoutubePrefs.fromMap(
        (m['youtube'] as Map?)?.cast<String, dynamic>(),
      ),
      // Clamped on read as well as on write, so a hand-edited or downgraded box
      // cannot set a concurrency that starves or overloads the device. A stored
      // 1 from an older build is indistinguishable from a deliberate choice, so
      // it is honoured rather than treated as "unset".
      maxConcurrency: switch (m['maxConcurrency']) {
        final num n => _clamp(n.toInt(), concurrencyMin, concurrencyMax),
        _ => null,
      },
      maxQueueSize: _clamp(
        (m['maxQueueSize'] as num?)?.toInt() ?? 50,
        queueSizeMin,
        queueSizeMax,
      ),
    );
  }

  static int _clamp(int value, int min, int max) => value.clamp(min, max);
}
