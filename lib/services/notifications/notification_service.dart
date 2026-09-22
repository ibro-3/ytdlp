import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Android-first download notifications on the `downloads` channel.
/// Foreground-only in v1 (no Foreground Service); safe no-ops when the
/// plugin isn't ready.
class NotificationService {
  NotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;

  static const _channelId = 'downloads';
  static const _channelName = 'Downloads';
  static const _channelDesc = 'Video download progress and completion';

  Future<void> init() async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
    );
    await _plugin.initialize(settings: settings);
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDesc,
              importance: Importance.low,
            ),
          );
    }
    _ready = true;
  }

  /// Android 13+ requires an explicit runtime grant.
  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    final granted = await android.requestNotificationsPermission();
    return granted ?? false;
  }

  Future<void> showProgress({
    required String taskId,
    required String title,
    required double progress,
    String? speed,
    String? eta,
  }) async {
    if (!_ready) return;
    final pct = (progress * 100).round().clamp(0, 100);
    final sub = [?speed, if (eta != null) 'ETA $eta'].join(' · ');
    await _plugin.show(
      id: taskId.hashCode,
      title: 'Downloading… $pct%',
      body: sub.isEmpty ? title : '$title\n$sub',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: 100,
          progress: pct,
          onlyAlertOnce: true,
          ongoing: true,
        ),
        linux: const LinuxNotificationDetails(),
      ),
    );
  }

  Future<void> showDone({
    required String taskId,
    required String title,
    required bool success,
    String? detail,
  }) async {
    if (!_ready) return;
    await _plugin.show(
      id: taskId.hashCode,
      title: success ? 'Download complete' : 'Download failed',
      body: detail == null || detail.isEmpty ? title : '$title\n$detail',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          ongoing: false,
          autoCancel: true,
        ),
        linux: LinuxNotificationDetails(),
      ),
    );
  }

  Future<void> cancel(String taskId) async {
    if (!_ready) return;
    await _plugin.cancel(id: taskId.hashCode);
  }
}
