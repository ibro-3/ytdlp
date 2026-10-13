import 'dart:async';
import 'dart:io';

/// How long a child is given to honour SIGTERM before it is killed outright.
const Duration processKillGrace = Duration(seconds: 5);

/// Signals [process] to terminate, escalating to SIGKILL after [grace] when it
/// is still alive.
///
/// Both places the app stops a child need this, and both need the escalation:
/// `YtdlpProcess.cancel` (the user pressed cancel or pause) and
/// `YtdlpService`'s own timeout and flood kills (the app gave up on a
/// metadata fetch). A single SIGTERM is not enough in either case. yt-dlp
/// installs a SIGTERM handler and finishes the fragment it is on, and on
/// Android the runner is a Python parent whose ffmpeg children never see the
/// signal at all — so a child that declines to go politely would otherwise
/// outlive the caller's wait for its exit status indefinitely, and a paused
/// download would hold its queue slot forever.
///
/// Returns as soon as the signal has been sent. The escalation timer cancels
/// itself once the child is reaped, so a cooperative process leaves nothing
/// behind.
void killProcess(Process process, {Duration grace = processKillGrace}) {
  var escalated = false;
  final escalate = Timer(grace, () {
    escalated = true;
    _signal(process, ProcessSignal.sigkill);
  });
  unawaited(
    process.exitCode.whenComplete(() {
      if (!escalated) escalate.cancel();
    }),
  );
  _signal(process, ProcessSignal.sigterm);
}

/// Sends [signal], falling back to the platform default signal.
///
/// [ProcessSignal.sigterm] is not available on every platform, and the error
/// that comes back from an unsupported signal is indistinguishable from one
/// thrown for a child that has already been reaped — so either way the default
/// signal is tried next. Both throws are swallowed: the caller has no better
/// option than to have asked, and a kill is best effort by nature.
void _signal(Process process, ProcessSignal signal) {
  try {
    process.kill(signal);
  } catch (_) {
    try {
      process.kill();
    } catch (_) {}
  }
}
