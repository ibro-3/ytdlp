import 'package:flutter/material.dart';

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
    this.defaultEmbedThumb = false,
    this.defaultWriteThumb = false,
    this.cookiesPath = '',
    this.downloadRoot = '',
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

  /// Optional Netscape-format `cookies.txt` handed to yt-dlp via `--cookies`.
  /// Some sites (notably YouTube) refuse anonymous requests; a cookie jar
  /// lets the user authenticate without the app storing any credentials.
  /// Empty = no cookies.
  final String cookiesPath;

  /// Root folder for downloads; empty means the platform default
  /// (`downloadsDir` in providers.dart). Videos and audio go into a
  /// `Video/` / `Audio/` subfolder of this root.
  final String downloadRoot;

  /// Defaults seeded into the download sheet. Embed options are only honored
  /// when ffmpeg is available (bundled on Android, inferred on desktop).
  final bool defaultEmbedSubs;
  final bool defaultWriteSubs;
  final bool defaultIncludeAutoSubs;
  final bool defaultEmbedThumb;
  final bool defaultWriteThumb;

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
    bool? defaultEmbedThumb,
    bool? defaultWriteThumb,
    String? cookiesPath,
    String? downloadRoot,
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
      defaultEmbedThumb: defaultEmbedThumb ?? this.defaultEmbedThumb,
      defaultWriteThumb: defaultWriteThumb ?? this.defaultWriteThumb,
      cookiesPath: cookiesPath ?? this.cookiesPath,
      downloadRoot: downloadRoot ?? this.downloadRoot,
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
    'defaultEmbedThumb': defaultEmbedThumb,
    'defaultWriteThumb': defaultWriteThumb,
    'cookiesPath': cookiesPath,
    'downloadRoot': downloadRoot,
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
      defaultEmbedThumb: (m['defaultEmbedThumb'] as bool?) ?? false,
      defaultWriteThumb: (m['defaultWriteThumb'] as bool?) ?? false,
      cookiesPath: (m['cookiesPath'] as String?) ?? '',
      downloadRoot: (m['downloadRoot'] as String?) ?? '',
    );
  }
}
