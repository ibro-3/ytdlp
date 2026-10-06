import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// The foreground-service operations [ForegroundService] drives.
///
/// Split out so the lifecycle rules are testable off-device; production uses
/// [PluginForegroundTaskDriver], which is the real plugin.
abstract interface class ForegroundTaskDriver {
  /// Whether this host can run a foreground service at all (Android only).
  bool get isSupportedHost;

  Future<bool> isRunning();

  Future<void> start({required String title, required String headline});

  Future<void> update({required String title, required String headline});

  Future<void> stop();
}

/// Talks to `flutter_foreground_task` directly.
class PluginForegroundTaskDriver implements ForegroundTaskDriver {
  const PluginForegroundTaskDriver();

  @override
  bool get isSupportedHost => Platform.isAndroid;

  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  @override
  Future<void> start({required String title, required String headline}) =>
      FlutterForegroundTask.startService(
        notificationTitle: headline,
        notificationText: title,
        notificationIcon: null,
        callback: _foregroundTaskCallback,
      );

  @override
  Future<void> update({required String title, required String headline}) =>
      FlutterForegroundTask.updateService(
        notificationTitle: headline,
        notificationText: title,
      );

  @override
  Future<void> stop() => FlutterForegroundTask.stopService();
}

/// Manages the Android foreground service that keeps downloads alive when
/// the app is backgrounded.
///
/// On Android, background apps have ~60 seconds before the OS may kill them.
/// A foreground service with a persistent notification tells the OS the app is
/// doing user-initiated work and should not be killed.
///
/// The service is started when the first download begins and stopped when the
/// queue drains. It shows a notification with the current download's title
/// and progress.
class ForegroundService {
  ForegroundService._({ForegroundTaskDriver? driver})
    : _driver = driver ?? const PluginForegroundTaskDriver();

  /// Builds a service driven by [driver] rather than the platform plugin, so
  /// the start/update/stop lifecycle can be tested without an emulator.
  @visibleForTesting
  factory ForegroundService.forTesting(ForegroundTaskDriver driver) =>
      ForegroundService._(driver: driver);

  static final ForegroundService instance = ForegroundService._();

  /// The platform operations this service drives.
  ///
  /// Extracted behind an interface so the lifecycle rules — do not re-issue a
  /// start contract while running, do not call the plugin at all off Android —
  /// are testable without an emulator. The plugin talks to a real service, and
  /// the redundant-start behaviour it warns about is exactly what needs
  /// asserting.
  final ForegroundTaskDriver _driver;

  bool _initialized = false;

  @visibleForTesting
  bool isSupportedHost() => _driver.isSupportedHost;

  /// Initialize the foreground task. Must be called before [startService].
  void init() {
    if (_initialized) return;
    _initialized = true;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'downloads_foreground',
        channelName: 'Download Service',
        channelDescription:
            'Keeps downloads running when the app is in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Start the foreground service if it is not already running.
  ///
  /// Safe to call repeatedly: when the service is already up this only
  /// refreshes the notification rather than re-issuing a start contract, which
  /// the plugin treats as redundant and answers with
  /// `ForegroundServiceDidNotStartInTime`.
  ///
  /// The check and the start are serialised through [_starting]. `DownloadManager`
  /// starts one per task without awaiting, so with a concurrency above one two
  /// callers both observe "not running" and both issue a start — which is exactly
  /// the failure this method exists to avoid.
  Future<void> startService({
    required String title,
    required double progress,
  }) {
    if (!_driver.isSupportedHost) return Future<void>.value();
    final pending = _starting;
    if (pending != null) {
      // A start is already in flight; let it finish, then only refresh. The
      // refresh happens either way — a failed start does not make the
      // notification any less stale.
      return pending.then((_) {
        _starting = null;
        return updateService(title: title, progress: progress);
      });
    }

    // Held so the next caller can tell a start is in progress. Cleared by the
    // caller above and, for the last caller, in the `whenComplete` below.
    final guard = Completer<void>();
    _starting = guard.future;
    return _start(title: title, progress: progress).whenComplete(() {
      if (identical(_starting, guard.future)) _starting = null;
      if (!guard.isCompleted) guard.complete();
    });
  }

  Future<void>? _starting;

  Future<void> _start({
    required String title,
    required double progress,
  }) async {
    final isRunning = await _driver.isRunning();
    if (isRunning) {
      await updateService(title: title, progress: progress);
      return;
    }
    await _driver.start(title: title, headline: _headline(progress));
  }

  /// Refresh the notification of an already-running service.
  ///
  /// Callers must throttle this — every call is a platform round trip, and a
  /// percentage that changes many times a second is unreadable anyway.
  Future<void> updateService({
    required String title,
    required double progress,
  }) async {
    if (!_driver.isSupportedHost) return;
    await _driver.update(title: title, headline: _headline(progress));
  }

  static String _headline(double progress) {
    final pct = (progress * 100).round().clamp(0, 100);
    return 'Downloading… $pct%';
  }

  /// Stop the foreground service. Called when all downloads complete.
  Future<void> stopService() async {
    if (!_driver.isSupportedHost) return;
    final isRunning = await _driver.isRunning();
    if (isRunning) {
      await _driver.stop();
    }
  }

  /// Whether the foreground service is currently running.
  Future<bool> get isRunning async {
    if (!_driver.isSupportedHost) return false;
    return _driver.isRunning();
  }
}

/// The entry point for the foreground task. This runs in a separate isolate
/// and is required by the flutter_foreground_task package, but our actual
/// download logic lives in the main isolate (DownloadManager). The service
/// is just a "keep alive" notification — the download itself runs in the
/// main process.
void _foregroundTaskCallback() {
  // The foreground task callback runs in a background isolate.
  // We don't need to do anything here — the download runs in the main
  // isolate and we just need the service to stay alive.
  FlutterForegroundTask.setTaskHandler(_NoOpTaskHandler());
}

class _NoOpTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
