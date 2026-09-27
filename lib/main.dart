import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'core/providers.dart';
import 'services/foreground/foreground_service.dart';
import 'services/notifications/notification_service.dart';
import 'services/sharing/share_intent_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  final historyBox = await Hive.openBox<dynamic>('history');
  final settingsBox = await Hive.openBox<dynamic>('settings');
  final queueBox = await Hive.openBox<dynamic>('queue');
  final notifications = NotificationService();
  await notifications.init();
  ForegroundService.instance.init();
  ShareIntentService.instance.init();
  runApp(
    ProviderScope(
      overrides: [
        historyBoxProvider.overrideWithValue(historyBox),
        settingsBoxProvider.overrideWithValue(settingsBox),
        queueBoxProvider.overrideWithValue(queueBox),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
      child: const App(),
    ),
  );
}
