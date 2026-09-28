import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/core/models/output_template.dart';
import 'package:ytdlp/core/models/settings_model.dart';
import 'package:ytdlp/core/models/yt_prefs.dart';

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

    test('ytPrefs default to the neutral configuration', () {
      expect(const AppSettings().ytPrefs, const YtPrefs());
      expect(const AppSettings().ytPrefs.concurrentFragments, 1);
    });

    test('ytPrefs round-trip through toMap/fromMap', () {
      const prefs = YtPrefs(
        concurrentFragments: 3,
        limitRate: '2M',
        extractAudio: true,
        audioFormat: 'opus',
      );
      final back = AppSettings.fromMap(
        const AppSettings(ytPrefs: prefs).toMap(),
      );
      expect(back.ytPrefs, prefs);
    });

    test('fromMap defaults ytPrefs for an older stored map', () {
      // An install upgrading from before these controls has no ytPrefs key.
      final s = AppSettings.fromMap({'themeMode': 'dark'});
      expect(s.ytPrefs, const YtPrefs());
    });

    test('copyWith sets ytPrefs without disturbing other fields', () {
      const s = AppSettings(downloadRoot: '/media/x', extraArgs: '--a');
      final next = s.copyWith(ytPrefs: const YtPrefs(limitRate: '5M'));
      expect(next.ytPrefs.limitRate, '5M');
      expect(next.downloadRoot, '/media/x', reason: 'must not clobber');
      expect(next.extraArgs, '--a');
    });

    test('copyWith keeps ytPrefs when not mentioned', () {
      const s = AppSettings(ytPrefs: YtPrefs(limitRate: '2M'));
      expect(s.copyWith().ytPrefs, s.ytPrefs);
      expect(s.copyWith(themeMode: ThemeMode.dark).ytPrefs, s.ytPrefs);
    });

    test('maxConcurrency is unset by default and resolves per platform', () {
      const s = AppSettings();
      expect(s.maxConcurrency, isNull);
      expect(s.resolveConcurrency(isMobile: true), 1);
      expect(s.resolveConcurrency(isMobile: false), 2);
    });

    test('an explicit concurrency overrides the platform default', () {
      const s = AppSettings(maxConcurrency: 4);
      expect(s.resolveConcurrency(isMobile: true), 4);
      expect(s.resolveConcurrency(isMobile: false), 4);
    });

    test('copyWith can clear concurrency back to the platform default', () {
      const s = AppSettings(maxConcurrency: 4);
      expect(
        s.copyWith(maxConcurrencySetter: () => null).maxConcurrency,
        isNull,
      );
      expect(
        s
            .copyWith(maxConcurrencySetter: () => null)
            .resolveConcurrency(isMobile: true),
        1,
      );
      // A plain int still sets it, and omitting it keeps the current value.
      expect(s.copyWith(maxConcurrencySetter: () => 3).maxConcurrency, 3);
      expect(s.copyWith().maxConcurrency, 4);
    });

    test('copyWith clamps concurrency into range', () {
      const s = AppSettings();
      expect(
        s.copyWith(maxConcurrencySetter: () => 99).maxConcurrency,
        AppSettings.concurrencyMax,
      );
      expect(
        s.copyWith(maxConcurrencySetter: () => 0).maxConcurrency,
        AppSettings.concurrencyMin,
      );
    });

    test('fromMap clamps a stored concurrency', () {
      expect(
        AppSettings.fromMap({'maxConcurrency': 999}).maxConcurrency,
        AppSettings.concurrencyMax,
      );
      expect(
        AppSettings.fromMap({'maxConcurrency': -3}).maxConcurrency,
        AppSettings.concurrencyMin,
      );
      // A stored value is a deliberate choice, so 1 is honoured.
      expect(AppSettings.fromMap({'maxConcurrency': 1}).maxConcurrency, 1);
    });

    test('fromMap treats a non-numeric concurrency as unset', () {
      expect(
        AppSettings.fromMap({'maxConcurrency': 'many'}).maxConcurrency,
        isNull,
      );
    });

    test('maxQueueSize defaults to 50 and clamps', () {
      expect(const AppSettings().maxQueueSize, 50);
      expect(
        const AppSettings().copyWith(maxQueueSize: 1).maxQueueSize,
        AppSettings.queueSizeMin,
      );
      expect(
        AppSettings.fromMap({'maxQueueSize': 0}).maxQueueSize,
        AppSettings.queueSizeMin,
      );
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
