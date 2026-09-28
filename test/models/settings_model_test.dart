import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/output_template.dart';
import 'package:ytdlp/core/models/settings_model.dart';

void main() {
  group('AppSettings', () {
    test('defaults match v1 behavior', () {
      const s = AppSettings();
      expect(s.themeMode, ThemeMode.system);
      expect(s.seedColor, 0xFFD32F2F);
      expect(s.defaultVideoTier, 720);
      expect(s.defaultAudioOnly, isFalse);
      expect(s.defaultAudioTier, isNull, reason: 'Best audio by default');
      expect(s.notificationsEnabled, isTrue);
      expect(s.downloadRoot, isEmpty);
      expect(s.tierLabel, '720p');
    });

    test('round-trips through toMap/fromMap', () {
      const s = AppSettings(
        themeMode: ThemeMode.dark,
        seedColor: 0xFF1565C0,
        defaultVideoTier: null,
        defaultAudioOnly: true,
        defaultAudioTier: 128,
        notificationsEnabled: false,
        downloadRoot: '/data/media/0/ytdlp',
      );
      final back = AppSettings.fromMap(s.toMap());
      expect(back.themeMode, ThemeMode.dark);
      expect(back.seedColor, 0xFF1565C0);
      expect(back.defaultVideoTier, isNull);
      expect(back.tierLabel, 'Best');
      expect(back.defaultAudioOnly, isTrue);
      expect(back.defaultAudioTier, 128);
      expect(back.notificationsEnabled, isFalse);
      expect(back.downloadRoot, '/data/media/0/ytdlp');
    });

    test('extraArgs and outputTemplate default to empty', () {
      const s = AppSettings();
      expect(s.extraArgs, isEmpty);
      expect(s.outputTemplate, isEmpty);
      // An empty template resolves to the built-in default, never a blank one.
      expect(
        s.effectiveOutputTemplate.effective,
        OutputTemplate.defaultTemplate,
      );
    });

    test('the new fields round-trip', () {
      const s = AppSettings(
        extraArgs: '--concurrent-fragments 4',
        outputTemplate: '%(uploader)s/%(title)s.%(ext)s',
      );
      final back = AppSettings.fromMap(s.toMap());
      expect(back.extraArgs, '--concurrent-fragments 4');
      expect(back.outputTemplate, '%(uploader)s/%(title)s.%(ext)s');
      expect(
        back.effectiveOutputTemplate.effective,
        '%(uploader)s/%(title)s.%(ext)s',
      );
    });

    test('copyWith sets and clears the new fields', () {
      const s = AppSettings();
      final set = s.copyWith(
        extraArgs: '--a',
        outputTemplate: '%(title)s.%(ext)s',
      );
      expect(set.extraArgs, '--a');
      expect(set.copyWith(extraArgs: '').extraArgs, isEmpty);
      expect(set.copyWith(outputTemplate: '').outputTemplate, isEmpty);
    });

    test('fromMap defaults the new fields for an older stored map', () {
      // An install upgrading from before these fields existed has neither key.
      final s = AppSettings.fromMap({'themeMode': 'dark'});
      expect(s.extraArgs, isEmpty);
      expect(s.outputTemplate, isEmpty);
    });

    test('copyWith can clear the audio tier to Best via thunk', () {
      const s = AppSettings(defaultAudioTier: 192);
      final cleared = s.copyWith(defaultAudioTier: () => null);
      expect(cleared.defaultAudioTier, isNull);
      final kept = s.copyWith();
      expect(kept.defaultAudioTier, 192);
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

    test('fromMap ignores a stored androidYtdlpUrl from older installs', () {
      // The custom build URL setting was removed; old persisted maps must
      // still load without it.
      final s = AppSettings.fromMap({
        'themeMode': 'dark',
        'androidYtdlpUrl': 'https://example.com/yt-dlp',
      });
      expect(s.themeMode, ThemeMode.dark);
      expect(s.toMap().containsKey('androidYtdlpUrl'), isFalse);
    });
  });
}
