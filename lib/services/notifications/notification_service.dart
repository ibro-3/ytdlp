import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Download notifications on the `downloads` channel.
///
/// Android is the primary target and additionally runs a `dataSync` foreground
/// service while the queue is non-empty (see `ForegroundService`); Linux and
/// macOS get plain system notifications. Every plugin call is wrapped so a
/// missing/unsupported plugin, revoked permission or platform error can never
/// interrupt a download.
bool _hostIsAndroid() => Platform.isAndroid;

bool _hostHasPermissionModel() => Platform.isAndroid || Platform.isMacOS;

class NotificationService {
  NotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    bool Function()? isAndroid,
    bool Function()? hasPermissionModel,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _isAndroid = isAndroid ?? _hostIsAndroid,
       _hasPermissionModel = hasPermissionModel ?? _hostHasPermissionModel;

  final FlutterLocalNotificationsPlugin _plugin;

  /// Platform predicates, injected so the permission flow is testable on any
  /// host. Production leaves them reading the real platform.
  final bool Function() _isAndroid;
  final bool Function() _hasPermissionModel;

  bool _ready = false;
  bool _initializing = false;

  static const _channelId = 'downloads';
  static const _channelName = 'Downloads';
  static const _channelDesc = 'Video download progress and completion';

  /// SharedPreferences key prefix for persisted notification ID mapping.
  static const _prefsPrefix = 'notif_id_';

  /// Golden ratio hash constant for stable ID generation.
  static const _idSalt = 0x9e3779b9;

  Future<void> init() async {
    if (_ready || _initializing) return;
    _initializing = true;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        // Permissions are not requested here: the notification toggle in
        // Settings is what asks, mirroring the Android behaviour, so the
        // app never throws a permission prompt at first launch.
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      );
      await _plugin.initialize(settings: settings);
      if (_isAndroid()) {
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
    } catch (_) {
      _ready = false; // Stay quiet regardless of platform support.
    } finally {
      _initializing = false;
    }
  }

  /// Asks the OS for permission to post notifications.
  ///
  /// Android 13+ needs an explicit runtime grant; macOS needs the app
  /// authorized before any notification is accepted. Linux and Windows have no
  /// permission model here, so they are treated as always allowed.
  Future<bool> requestPermission() async {
    if (!_hasPermissionModel()) return true;
    try {
      if (_isAndroid()) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (android == null) return false;
        final granted = await android.requestNotificationsPermission();
        return granted ?? false;
      }
      final macos = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (macos == null) return false;
      final granted = await macos.requestPermissions(alert: true, sound: true);
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns a stable notification ID for [taskId] that persists across restarts.
  ///
  /// Uses a hash of the taskId combined with a persisted mapping to ensure
  /// the same taskId always gets the same notification ID, preventing ghost
  /// notifications after app restart.
  Future<int> _idFor(String taskId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_prefsPrefix$taskId';
    int? id = prefs.getInt(key);
    if (id == null) {
      // Generate stable hash-based ID as fallback
      id = (taskId.hashCode * _idSalt) & 0x7FFFFFFF;
      await prefs.setInt(key, id);
    }
    return id;
  }

  /// Removes the persisted notification ID mapping for [taskId].
  Future<void> _removeId(String taskId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefsPrefix$taskId');
  }

  Future<void> showProgress({
    required String taskId,
    required String title,
    required double progress,
    String? speed,
    String? eta,
  }) async {
    if (!_ready) return;
    try {
      final pct = (progress * 100).round().clamp(0, 100);
      final sub = [?speed, if (eta != null) 'ETA $eta'].join(' · ');
      await _plugin.show(
        id: await _idFor(taskId),
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
          // macOS has no progress bar. Stay silent so a fast download does
          // not fire a banner per update — the completion notice below is the
          // one the user actually wants to see.
          macOS: const DarwinNotificationDetails(
            presentAlert: false,
            presentSound: false,
            presentBanner: false,
            presentList: true,
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> showDone({
    required String taskId,
    required String title,
    required bool success,
    String? detail,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: await _idFor(taskId),
        title: success ? 'Download complete' : 'Download failed',
        body: detail == null || detail.isEmpty ? title : '$title\n$detail',
        notificationDetails: NotificationDetails(
          android: const AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.high,
            priority: Priority.high,
            ongoing: false,
            autoCancel: true,
          ),
          linux: const LinuxNotificationDetails(),
          macOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> cancel(String taskId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: await _idFor(taskId));
      await _removeId(taskId);
    } catch (_) {}
  }
}
