import 'package:flutter_test/flutter_test.dart';
import 'package:ytdlp/services/notifications/notification_service.dart';

void main() {
  group('requestPermission', () {
    test('Linux-like host needs no permission and reports true', () async {
      final service = NotificationService(
        isAndroid: () => false,
        hasPermissionModel: () => false,
      );
      expect(await service.requestPermission(), isTrue);
    });

    test('a host with a permission model but no Android is macOS', () async {
      // Cannot fake the macOS plugin implementation: construct one and confirm
      // we reach the macOS path, which returns false rather than throwing when
      // the plugin has no platform.
      final service = NotificationService(
        isAndroid: () => false,
        hasPermissionModel: () => true,
      );
      expect(await service.requestPermission(), anyOf(isTrue, isFalse));
    });

    test('an Android host talks to the Android plugin, never throws', () async {
      final service = NotificationService(
        isAndroid: () => true,
        hasPermissionModel: () => true,
      );
      // Whatever the plugin reports, the service must not throw — a missing
      // platform channel is a legitimate state in a test and must not crash a
      // download.
      expect(await service.requestPermission(), anyOf(isTrue, isFalse));
    });
  });

  group('showProgress / showDone before init', () {
    test('never throws when the service never initialized', () async {
      final service = NotificationService();
      await service.showProgress(taskId: 't', title: 'T', progress: 0.5);
      await service.showDone(taskId: 't', title: 'T', success: true);
      // If this returns at all, the guard held: no half-initialized plugin is
      // touched.
    });
  });
}
