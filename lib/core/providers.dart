import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../services/downloads/download_manager.dart';
import '../services/downloads/history_service.dart';
import '../services/notifications/notification_service.dart';
import '../services/settings/settings_service.dart';
import '../services/ytdlp/binary_manager.dart';
import '../services/ytdlp/ytdlp_service.dart';
import 'models/settings_model.dart';

final historyBoxProvider = Provider<Box<dynamic>>((ref) {
  throw UnimplementedError('historyBoxProvider must be overridden in main()');
});

final settingsBoxProvider = Provider<Box<dynamic>>((ref) {
  throw UnimplementedError('settingsBoxProvider must be overridden in main()');
});

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
  // Mobile devices have less headroom than desktops. Two never run at once
  // on Android/iOS; desktop allows two parallel downloads by default.
  final maxConcurrency = Platform.isAndroid ? 1 : 2;
  final manager = DownloadManager(
    ytdlp: ref.watch(ytdlpServiceProvider),
    history: ref.watch(historyServiceProvider),
    downloadsDir: ref.watch(downloadsDirProvider),
    settings: ref.watch(settingsServiceProvider),
    notifications: ref.watch(notificationServiceProvider),
    maxConcurrency: maxConcurrency,
  );
  ref.onDispose(manager.dispose);
  return manager;
});
