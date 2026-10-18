import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/binary_manager.dart';

void main() {
  BinaryManager makeManager() => BinaryManager();

  group('safeJoinRuntime', () {
    // The runtime root is where every archive member is written; an archive
    // whose member names carry `..` or absolute paths used to be able to land
    // files in the app support dir or system directories.
    test('lets a plain name through, resolved inside the root', () {
      final root = '/support/pyrt-arm64-v8a';
      expect(
        makeManager().safeJoinRuntime(root, 'data/data/com.termux/usr/bin'),
        startsWith(root),
      );
    });

    test('a nested `..` that still resolves inside is kept', () {
      final resolved = makeManager().safeJoinRuntime(
        '/root',
        'data/../usr/bin/python3.14',
      );
      expect(resolved, '/root/usr/bin/python3.14');
    });

    test('an escape to a parent directory is refused', () {
      final resolved = makeManager().safeJoinRuntime('/root', '../escape');
      expect(resolved, isNull);
    });

    test('backslashes are treated as separators, so `..\\..\\` cannot sneak a relative escape past it', () {
      expect(
        makeManager().safeJoinRuntime('/root', 'a\\..\\..\\escape'),
        isNull,
      );
    });

    test('an absolute path is anchored inside the root, not honoured', () {
      // `/etc/passwd` written as an archive member name must not write to the
      // system path: folding it under the root keeps every member inside the
      // sandbox, whichever shape the name is in.
      expect(
        makeManager().safeJoinRuntime('/root', '/etc/passwd'),
        '/root/etc/passwd',
      );
    });
  });

  group('runtimeLinkPointsOutside', () {
    test('a relative target that stays inside is allowed', () async {
      // Real Termux trees are full of these: usr/bin/python3.14 → python3,
      // resolved from the link's own directory.
      final inside = await makeManager().runtimeLinkPointsOutside(
        '/root',
        '/root/data/termux/bin/python3',
        '../lib/python3.14',
      );
      expect(inside, isFalse);
    });

    test('a relative target that climbs out is refused', () async {
      final outside = await makeManager().runtimeLinkPointsOutside(
        '/root',
        '/root/data/termux/bin/x',
        '../../../../etc',
      );
      expect(outside, isTrue);
    });

    test('an absolute target inside the root is allowed', () async {
      final inside = await makeManager().runtimeLinkPointsOutside(
        '/root',
        '/root/data/termux/bin/x',
        '/root/data/termux/usr/lib',
      );
      expect(inside, isFalse);
    });

    test('an absolute target elsewhere is refused', () async {
      final outside = await makeManager().runtimeLinkPointsOutside(
        '/root',
        '/root/data/termux/bin/x',
        '/etc/ssl/certs',
      );
      expect(outside, isTrue);
    });
  });

  group('hasFfprobe on desktop', () {
    // Non-Android installs delegate to the ffmpeg check: a normal system
    // ffmpeg package always ships ffprobe beside it, so a second probe would
    // only re-ask the same question.
    test('follows whatever hasFfmpeg answers', () async {
      final manager = _FfmpegAnswer(answer: false);
      expect(await manager.hasFfprobe(), isFalse);
      expect(manager.probeCount, 1);
    });
  });

  group('takeDownloadError', () {
    // The contract that makes "not found" distinguishable from "not
    // installed": the message is consumed exactly once by whoever surfaces it.
    test('a fresh manager has no error to report, twice over', () {
      final manager = makeManager();
      expect(manager.takeDownloadError(), isNull);
      expect(manager.takeDownloadError(), isNull);
    });
  });
}

/// A manager whose ffmpeg probe is answered by the test.
class _FfmpegAnswer extends BinaryManager {
  _FfmpegAnswer({required this.answer}) : super();

  final bool answer;
  int probeCount = 0;

  @override
  Future<bool> hasFfmpeg() async {
    probeCount++;
    return answer;
  }
}
