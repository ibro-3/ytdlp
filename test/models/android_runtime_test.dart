import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// Validates the bundled Android CPython + yt-dlp runtimes
/// (built by tool/fetch_android_runtime.sh) without a device.
void main() {
  group('android runtime assets', () {
    for (final abi in ['x86_64', 'arm64-v8a']) {
      test('$abi bundle contains a runnable runtime', () {
        final asset = File('assets/bin/android/$abi/python.tar.gz');
        expect(
          asset.existsSync(),
          isTrue,
          reason: 'run tool/fetch_android_runtime.sh $abi',
        );

        final tarBytes = GZipDecoder().decodeBytes(
          asset.readAsBytesSync(),
          verify: true,
        );
        final names = TarDecoder()
            .decodeBytes(tarBytes)
            .files
            .map((f) => f.name)
            .toSet();

        const usr = 'data/data/com.termux/files/usr';
        expect(names.contains('$usr/bin/python3.14'), isTrue);
        expect(names.contains('$usr/bin/yt-dlp'), isTrue);
        expect(
          names.contains(
            '$usr/lib/python3.14/site-packages/yt_dlp/__init__.py',
          ),
          isTrue,
        );
        expect(names.contains('$usr/etc/tls/cert.pem'), isTrue);
        // Native modules must match the ABI (no cross-arch mixups).
        final dynload = names
            .where((n) => n.contains('lib-dynload') && n.endsWith('.so'))
            .toList();
        expect(dynload, isNotEmpty);
        final brotli = names.firstWhere(
          (n) => n.contains('_brotli') && n.endsWith('.so'),
          orElse: () => '',
        );
        expect(brotli, isNotEmpty);
        if (abi == 'x86_64') {
          expect(brotli, contains('x86_64'));
        } else {
          expect(brotli, contains('aarch64'));
        }
      });

      test('$abi bundles a minimal static ffmpeg (DASH merges)', () {
        final bin = File('assets/bin/android/$abi/ffmpeg');
        expect(
          bin.existsSync(),
          isTrue,
          reason: 'run tool/fetch_ffmpeg_android.sh $abi',
        );
        // Must be small — that's the whole point vs. the Termux package.
        expect(bin.lengthSync(), lessThan(5 * 1024 * 1024));
        final head = bin.readAsBytesSync().take(20).toList();
        expect(
          head.sublist(0, 4),
          [0x7f, 0x45, 0x4c, 0x46], // ELF
          reason: 'ffmpeg must be a native executable',
        );
        // e_machine: x86-64 == 62, aarch64 == 183.
        final machine = (head[18] | (head[19] << 8));
        expect(
          machine,
          abi == 'x86_64' ? 62 : 183,
          reason: 'ffmpeg must match the device ABI',
        );
      });

      test('$abi bundles ffprobe (postprocessing)', () {
        // BinaryManager._initAndroidFfmpeg only keeps an already-extracted
        // copy when the version marker matches AND ffprobe sits next to
        // ffmpeg. A missing probe silently downgrades the app to
        // "no embedding" instead of failing loudly, so assert it ships.
        final probe = File('assets/bin/android/$abi/ffprobe');
        expect(
          probe.existsSync(),
          isTrue,
          reason: 'run tool/fetch_ffmpeg_android.sh $abi',
        );
        expect(probe.lengthSync(), lessThan(5 * 1024 * 1024));
        final head = probe.readAsBytesSync().take(20).toList();
        expect(head.sublist(0, 4), [0x7f, 0x45, 0x4c, 0x46]);
        expect(head[18] | (head[19] << 8), abi == 'x86_64' ? 62 : 183);
      });
    }
  });

  group('declared assets exist on disk', () {
    // pubspec.yaml lists these under flutter.assets. A path that is declared
    // but absent fails the build outright, so keep the two in sync.
    const declared = [
      'assets/bin/.gitkeep',
      'assets/bin/android/x86_64/ffmpeg',
      'assets/bin/android/x86_64/ffprobe',
      'assets/bin/android/x86_64/python.tar.gz',
      'assets/bin/android/arm64-v8a/ffmpeg',
      'assets/bin/android/arm64-v8a/ffprobe',
      'assets/bin/android/arm64-v8a/python.tar.gz',
    ];

    test('every asset declared in pubspec.yaml is present', () {
      for (final path in declared) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path is declared in pubspec.yaml but missing on disk',
        );
      }
    });

    test('desktop yt-dlp binaries stay out of flutter.assets', () {
      // flutter.assets has no per-platform scoping, so declaring the desktop
      // builds would ship ~56 MB of them inside every Android APK. Desktop
      // resolves a system install and otherwise auto-downloads, so leaving
      // these undeclared is deliberate — not an oversight to "fix".
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final path in [
        'assets/bin/linux/yt-dlp',
        'assets/bin/macos/yt-dlp',
        'assets/bin/windows/yt-dlp.exe',
      ]) {
        if (!File(path).existsSync()) continue;
        expect(
          pubspec,
          isNot(contains('- $path')),
          reason:
              '$path is bundled. That adds ~56 MB to Android APKs; remove the '
              'asset entry from pubspec.yaml (the README documents the '
              'auto-download fallback instead)',
        );
      }
    });
  });
}
