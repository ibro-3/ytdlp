import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../services/downloads/download_manager.dart';
import '../services/downloads/history_service.dart';
import '../services/downloads/queue_store.dart';
import '../services/foreground/foreground_service.dart';
import '../services/notifications/notification_service.dart';
import '../services/diagnostics/diagnostics_service.dart';
import '../services/settings/backup_service.dart';
import '../services/settings/settings_service.dart';
import '../services/settings/template_store.dart';
import '../services/ytdlp/binary_manager.dart';
import '../services/ytdlp/ejs_installer.dart';
import '../services/ytdlp/ytdlp_service.dart';
import 'models/settings_model.dart';

final historyBoxProvider = Provider<Box<dynamic>>((ref) {
  throw UnimplementedError('historyBoxProvider must be overridden in main()');
});

final settingsBoxProvider = Provider<Box<dynamic>>((ref) {
  throw UnimplementedError('settingsBoxProvider must be overridden in main()');
});

/// Saved argument templates. Shares the settings box but uses its own key
/// prefix, so a template never has to round-trip through [AppSettings].
final templateStoreProvider = Provider<TemplateStore>(
  (ref) => TemplateStore(ref.watch(settingsBoxProvider)),
);

/// Export and restore of settings plus templates as one JSON document.
final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    box: ref.watch(settingsBoxProvider),
    templates: ref.watch(templateStoreProvider),
  ),
);

/// Installs and verifies the JavaScript runtime YouTube formats need.
final ejsInstallerProvider = Provider<EjsInstaller>(
  (ref) => EjsInstaller(ref.watch(binaryManagerProvider)),
);

/// Builds a support report: versions, paths and settings, with credentials
/// excluded.
final diagnosticsServiceProvider = Provider<DiagnosticsService>(
  (ref) => DiagnosticsService(
    binary: ref.watch(binaryManagerProvider),
    settings: ref.watch(settingsServiceProvider),
  ),
);

/// Queue snapshots, so a killed app doesn't lose in-flight downloads.
final queueBoxProvider = Provider<Box<dynamic>>((ref) {
  throw UnimplementedError('queueBoxProvider must be overridden in main()');
});

final queueStoreProvider = Provider<QueueStore>(
  (ref) => QueueStore(ref.watch(queueBoxProvider)),
);

final historyServiceProvider = Provider<HistoryService>((ref) {
  final box = ref.watch(historyBoxProvider);
  final service = HistoryService(box);
  service.init();
  return service;
});

final binaryManagerProvider = Provider<BinaryManager>((ref) => BinaryManager());

final ytdlpServiceProvider = Provider<YtdlpService>(
  (ref) => YtdlpService(ref.watch(binaryManagerProvider)),
);

Future<Directory> defaultDownloadsDir() async {
  final downloads = await getDownloadsDirectory();
  if (downloads != null) return downloads;
  final external = await getExternalStorageDirectory();
  if (external != null) return Directory('${external.path}/Download');
  return getApplicationDocumentsDirectory();
}

final downloadsDirProvider = Provider<Future<Directory> Function()>(
  (ref) => defaultDownloadsDir,
);

final settingsServiceProvider = Provider<SettingsService>((ref) {
  final box = ref.watch(settingsBoxProvider);
  final service = SettingsService(box);
  service.init();
  return service;
});

/// Reactive settings state for theming and download defaults.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsServiceProvider).settings;

  Future<void> patch(AppSettings next) async {
    await ref.read(settingsServiceProvider).update(next);
    state = next;
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  // Mobile devices have less headroom, so the default is one parallel download
  // there and two on desktop. The user can override in Settings, and the limit
  // is applied live so a change does not have to rebuild this provider and
  // throw away the live queue.
  final manager = DownloadManager(
    ytdlp: ref.watch(ytdlpServiceProvider),
    history: ref.watch(historyServiceProvider),
    downloadsDir: ref.watch(downloadsDirProvider),
    settings: settings,
    notifications: ref.watch(notificationServiceProvider),
    queueStore: ref.watch(queueStoreProvider),
    foregroundService: ForegroundService.instance,
    maxConcurrency: settings.settings.resolveConcurrency(
      isMobile: Platform.isAndroid || Platform.isIOS,
    ),
  );
  // A later settings change moves the live limit rather than replacing the
  // manager, so queued work survives it.
  ref.listen(settingsServiceProvider, (prev, next) {
    manager.maxConcurrency = next.settings.resolveConcurrency(
      isMobile: Platform.isAndroid || Platform.isIOS,
    );
  });
  ref.onDispose(manager.dispose);
  return manager;
});
