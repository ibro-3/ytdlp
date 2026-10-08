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

  // Everything below happens before `runApp`, so a throw here — a box that
  // cannot be opened, a notification plugin that will not initialise — used to
  // kill the process with a blank screen and nothing to report. Startup is
  // therefore best-effort per step: each is attempted on its own, and a failure
  // is passed to the app to show rather than thrown.
  final problems = <String>[];
  Box<dynamic>? historyBox;
  Box<dynamic>? settingsBox;
  Box<dynamic>? queueBox;
  NotificationService? notifications;

  try {
    await Hive.initFlutter();
  } catch (e) {
    // Nothing else can work without this, but reporting it beats a blank
    // screen: the message says what happened and the app still runs.
    problems.add('Local storage could not be prepared.\n\n$e');
  }
  // Attempted outside that try, and each on its own: one store failing must not
  // stop the others being opened.
  historyBox = await _openBox('history', problems);
  settingsBox = await _openBox('settings', problems);
  queueBox = await _openBox('queue', problems);

  try {
    notifications = NotificationService();
    await notifications.init();
  } catch (e) {
    // Optional: downloads still run without them, they just do not announce
    // themselves or appear in the shade.
    notifications = null;
    problems.add('Notifications could not be set up.\n\n$e');
  }

  // Separately from the share intake, which must survive a foreground-service
  // failure: losing the service costs background downloads, losing the intake
  // costs the share sheet, and one must not take the other down.
  try {
    ForegroundService.instance.init();
  } catch (e) {
    problems.add('Background downloads could not be enabled.\n\n$e');
  }
  try {
    ShareIntentService.instance.init();
  } catch (e) {
    problems.add('Share-sheet links could not be received.\n\n$e');
  }

  runApp(
    ProviderScope(
      overrides: [
        if (historyBox != null)
          historyBoxProvider.overrideWithValue(historyBox),
        if (settingsBox != null)
          settingsBoxProvider.overrideWithValue(settingsBox),
        if (queueBox != null) queueBoxProvider.overrideWithValue(queueBox),
        if (notifications != null)
          notificationServiceProvider.overrideWithValue(notifications),
      ],
      child: App(startupProblems: problems),
    ),
  );
}

/// Opens [name], recording — rather than throwing — any failure.
///
/// A store that will not open is left unoverridden, so its provider reports the
/// problem when read instead of the app dying here with no explanation.
Future<Box<dynamic>?> _openBox(String name, List<String> problems) async {
  try {
    return await Hive.openBox<dynamic>(name);
  } catch (e) {
    problems.add('The "$name" store could not be opened.\n\n$e');
    return null;
  }
}
