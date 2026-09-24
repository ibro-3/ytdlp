import 'package:flutter/material.dart';

/// Persisted user preferences. Stored as a plain map in the Hive
/// `settings` box so no codegen is needed.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.seedColor = 0xFFD32F2F,
    this.defaultVideoTier = 720,
    this.defaultAudioOnly = false,
    this.notificationsEnabled = true,
    this.androidYtdlpUrl = '',
    this.downloadRoot = '',
  });

  /// Null tier = Best quality.
  static const List<int?> videoTierOptions = [null, 1080, 720, 480, 360];

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
  final bool notificationsEnabled;
  final String androidYtdlpUrl;

  /// Root folder for downloads; empty means the platform default
  /// (`downloadsDir` in providers.dart). Videos and audio go into a
  /// `Video/` / `Audio/` subfolder of this root.
  final String downloadRoot;

  Color get seed => Color(seedColor);

  String get tierLabel =>
      defaultVideoTier == null ? 'Best' : '${defaultVideoTier}p';

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? seedColor,
    int? Function()? defaultVideoTier,
    bool? defaultAudioOnly,
    bool? notificationsEnabled,
    String? androidYtdlpUrl,
    String? downloadRoot,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      seedColor: seedColor ?? this.seedColor,
      defaultVideoTier: defaultVideoTier != null
          ? defaultVideoTier()
          : this.defaultVideoTier,
      defaultAudioOnly: defaultAudioOnly ?? this.defaultAudioOnly,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      androidYtdlpUrl: androidYtdlpUrl ?? this.androidYtdlpUrl,
      downloadRoot: downloadRoot ?? this.downloadRoot,
    );
  }

  Map<String, dynamic> toMap() => {
    'themeMode': themeMode.name,
    'seedColor': seedColor,
    'defaultVideoTier': defaultVideoTier,
    'defaultAudioOnly': defaultAudioOnly,
    'notificationsEnabled': notificationsEnabled,
    'androidYtdlpUrl': androidYtdlpUrl,
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
      notificationsEnabled: (m['notificationsEnabled'] as bool?) ?? true,
      androidYtdlpUrl: (m['androidYtdlpUrl'] as String?) ?? '',
      downloadRoot: (m['downloadRoot'] as String?) ?? '',
    );
  }
}
