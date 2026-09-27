import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

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
  ForegroundService._();

  static final ForegroundService instance = ForegroundService._();

  bool _initialized = false;

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
  Future<void> startService({
    required String title,
    required double progress,
  }) async {
    if (!Platform.isAndroid) return;

    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      await updateService(title: title, progress: progress);
      return;
    }

    await FlutterForegroundTask.startService(
      notificationTitle: _headline(progress),
      notificationText: title,
      notificationIcon: null,
      callback: _foregroundTaskCallback,
    );
  }

  /// Refresh the notification of an already-running service.
  ///
  /// Callers must throttle this — every call is a platform round trip, and a
  /// percentage that changes many times a second is unreadable anyway.
  Future<void> updateService({
    required String title,
    required double progress,
  }) async {
    if (!Platform.isAndroid) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: _headline(progress),
      notificationText: title,
    );
  }

  static String _headline(double progress) {
    final pct = (progress * 100).round().clamp(0, 100);
    return 'Downloading… $pct%';
  }

  /// Stop the foreground service. Called when all downloads complete.
  Future<void> stopService() async {
    if (!Platform.isAndroid) return;
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      await FlutterForegroundTask.stopService();
    }
  }

  /// Whether the foreground service is currently running.
  Future<bool> get isRunning async {
    if (!Platform.isAndroid) return false;
    return FlutterForegroundTask.isRunningService;
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
