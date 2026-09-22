import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/settings_model.dart';

void main() {
  group('AppSettings', () {
    test('defaults match v1 behavior', () {
      const s = AppSettings();
      expect(s.themeMode, ThemeMode.system);
      expect(s.seedColor, 0xFFD32F2F);
      expect(s.defaultVideoTier, 720);
      expect(s.defaultAudioOnly, isFalse);
      expect(s.askQualityEachTime, isTrue);
      expect(s.notificationsEnabled, isTrue);
      expect(s.androidYtdlpUrl, isEmpty);
      expect(s.downloadRoot, isEmpty);
      expect(s.tierLabel, '720p');
    });

    test('round-trips through toMap/fromMap', () {
      const s = AppSettings(
        themeMode: ThemeMode.dark,
        seedColor: 0xFF1565C0,
        defaultVideoTier: null,
        defaultAudioOnly: true,
        askQualityEachTime: false,
        notificationsEnabled: false,
        androidYtdlpUrl: 'https://example.com/yt-dlp',
        downloadRoot: '/data/media/0/ytdlp',
      );
      final back = AppSettings.fromMap(s.toMap());
      expect(back.themeMode, ThemeMode.dark);
      expect(back.seedColor, 0xFF1565C0);
      expect(back.defaultVideoTier, isNull);
      expect(back.tierLabel, 'Best');
      expect(back.defaultAudioOnly, isTrue);
      expect(back.askQualityEachTime, isFalse);
      expect(back.notificationsEnabled, isFalse);
      expect(back.androidYtdlpUrl, 'https://example.com/yt-dlp');
      expect(back.downloadRoot, '/data/media/0/ytdlp');
    });

    test('copyWith sets and clears downloadRoot', () {
      const s = AppSettings();
      final set = s.copyWith(downloadRoot: '/tmp/dl');
      expect(set.downloadRoot, '/tmp/dl');
      expect(set.copyWith(downloadRoot: '').downloadRoot, isEmpty);
    });

    test('copyWith can clear the tier to Best via thunk', () {
      const s = AppSettings(defaultVideoTier: 720);
      final cleared = s.copyWith(defaultVideoTier: () => null);
      expect(cleared.defaultVideoTier, isNull);
      final kept = s.copyWith();
      expect(kept.defaultVideoTier, 720);
    });

    test('fromMap tolerates missing/unknown values', () {
      final s = AppSettings.fromMap({'themeMode': 'nope'});
      expect(s.themeMode, ThemeMode.system);
      expect(s.defaultVideoTier, isNull);
    });
  });
}
