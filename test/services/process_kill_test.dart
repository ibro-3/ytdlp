@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/ytdlp/process_kill.dart';

/// These tests spawn real children, which is the only way to observe a signal.
/// They are skipped where the shell and `sleep` are unavailable rather than
/// guessed at: a fake [Process] would only prove that `kill` was called, not
/// that anything died.
void main() {
  final onPosix = !Platform.isWindows;

  test('a cooperative child stops from SIGTERM alone', () async {
    if (!onPosix) return;
    final child = await Process.start('sleep', ['30']);
    killProcess(child);
    final code = await child.exitCode.timeout(const Duration(seconds: 10));
    // Killed by a signal, not a self-chosen exit status.
    expect(code, isNot(0));
  });

  test('a child that ignores SIGTERM is killed outright after the grace', () async {
    if (!onPosix) return;
    // `trap "" TERM` makes the shell deaf to the polite request; the short
    // sleep lets the orphaned grandson exit on its own soon after.
    final child = await Process.start('sh', ['-c', 'trap "" TERM; sleep 3']);
    killProcess(child, grace: const Duration(milliseconds: 100));
    final code = await child.exitCode.timeout(const Duration(seconds: 10));
    // Escalation is the whole point: without it this future never completes and
    // the timeout above fails the test.
    expect(code, lessThan(0), reason: 'expected death by signal');
  });

  test('killing an already-reaped child is a no-op', () async {
    if (!onPosix) return;
    final child = await Process.start('true', const []);
    await child.exitCode;
    // Must not throw: the process is gone, and every caller kills
    // defensively.
    expect(() => killProcess(child), returnsNormally);
  });
}
