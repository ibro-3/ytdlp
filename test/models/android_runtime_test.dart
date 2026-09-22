import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// Validates the bundled Android CPython + yt-dlp runtimes
/// (built by tool/fetch_android_runtime.sh) without a device.
void main() {
  group('android runtime assets', () {
    for (final abi in ['x86_64', 'arm64-v8a']) {
      test('$abi bundle contains a runnable runtime', () {
        final asset =
            File('assets/bin/android/$abi/python.tar.gz');
        expect(asset.existsSync(), isTrue,
            reason: 'run tool/fetch_android_runtime.sh $abi');

        final tarBytes = GZipDecoder()
            .decodeBytes(asset.readAsBytesSync(), verify: true);
        final names =
            TarDecoder().decodeBytes(tarBytes).files.map((f) => f.name).toSet();

        const usr = 'data/data/com.termux/files/usr';
        expect(names.contains('$usr/bin/python3.14'), isTrue);
        expect(names.contains('$usr/bin/yt-dlp'), isTrue);
        expect(
            names.contains(
                '$usr/lib/python3.14/site-packages/yt_dlp/__init__.py'),
            isTrue);
        expect(names.contains('$usr/etc/tls/cert.pem'), isTrue);
        // Native modules must match the ABI (no cross-arch mixups).
        final dynload = names
            .where((n) => n.contains('lib-dynload') && n.endsWith('.so'))
            .toList();
        expect(dynload, isNotEmpty);
        final brotli = names.firstWhere(
            (n) => n.contains('_brotli') && n.endsWith('.so'),
            orElse: () => '');
        expect(brotli, isNotEmpty);
        if (abi == 'x86_64') {
          expect(brotli, contains('x86_64'));
        } else {
          expect(brotli, contains('aarch64'));
        }
      });
    }
  });
}
