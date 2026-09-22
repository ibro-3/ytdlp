import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'core/providers.dart';
import 'services/notifications/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  final historyBox = await Hive.openBox<dynamic>('history');
  final settingsBox = await Hive.openBox<dynamic>('settings');
  final notifications = NotificationService();
  await notifications.init();
  runApp(
    ProviderScope(
      overrides: [
        historyBoxProvider.overrideWithValue(historyBox),
        settingsBoxProvider.overrideWithValue(settingsBox),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
      child: const App(),
    ),
  );
}
