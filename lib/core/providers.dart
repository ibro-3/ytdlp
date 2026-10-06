import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../services/downloads/download_manager.dart';
import '../services/downloads/history_service.dart';
import '../services/downloads/queue_store.dart';
import '../services/foreground/foreground_service.dart';
import '../services/notifications/notification_service.dart';
import '../services/diagnostics/diagnostics_service.dart';
import '../services/cookies/cookie_jar_service.dart';
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

/// Whether post-processing can run on this device.
///
/// A provider rather than a future created in a builder, because the answer is
/// the result of spawning a process: as a `FutureBuilder` argument it was rebuilt
/// on every keystroke anywhere in Settings, restarting the probe each time and
/// dropping the in-flight answer back to "unavailable" — so the post-processing
/// switches visibly flickered greyed out while the user was typing in an
/// unrelated field. Cached, the probe runs once per app session.
final ffprobeAvailableProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.watch(binaryManagerProvider).hasFfprobe();
  } catch (_) {
    // A probe that cannot run is indistinguishable from one that found nothing.
    return false;
  }
});



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
///
/// The reactive source of truth for anything that has to follow a settings
/// change. Note that listening to [settingsServiceProvider] directly does *not*
/// work: it always yields the same `SettingsService` instance, and Riverpod 3
/// filters provider updates with `==`, so the listener never fires. This
/// controller emits a fresh [AppSettings] per change, which does.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsServiceProvider).settings;

  Future<void> patch(AppSettings next) async {
    await ref.read(settingsServiceProvider).update(next);
    // The write is asynchronous, so this controller can be disposed while it
    // is in flight — navigating away from Settings mid-save is enough. Setting
    // state after that throws, turning an ordinary save into a crash.
    if (!ref.mounted) return;
    state = next;
  }

  /// Re-reads the settings box and publishes whatever it now holds.
  ///
  /// Needed after a backup restore, which rewrites the stored settings behind
  /// the service's back. Without this the app keeps the pre-restore theme and
  /// download defaults — the UI says "Settings restored" while still showing the
  /// old values, until it is restarted.
  void reload() {
    final service = ref.read(settingsServiceProvider)..init();
    if (!ref.mounted) return;
    state = service.settings;
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// Where the two cookie-jar files live.
///
/// Resolved through an injected function rather than `path_provider` directly so
/// tests can point it at a temp directory instead of the real one.
final cookieSupportDirProvider = Provider<Future<String> Function()>((ref) {
  return () => getApplicationSupportDirectory().then((d) => d.path);
});

/// Asynchronous because the support directory needs `path_provider`, which
/// cannot answer synchronously — a provider that returned a placeholder path
/// would silently write the jar to the wrong place.
final cookieJarServiceProvider = FutureProvider<CookieJarService>((ref) async {
  final resolve = ref.watch(cookieSupportDirProvider);
  return CookieJarService(supportDir: await resolve());
});

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  // Read, not watched: the manager is long-lived and must survive a settings
  // change, and watching would rebuild it and throw away the live queue. The
  // live concurrency limit is moved by the listener below instead.
  final settings = ref.read(settingsServiceProvider);
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
  //
  // Watches the *controller*, not the service: the service provider always
  // yields the same `SettingsService` instance and Riverpod filters updates
  // with `==`, so listening to it never fired at all — a changed concurrency
  // limit silently only took effect on the next launch.
  ref.listen(settingsControllerProvider, (_, next) {
    manager.maxConcurrency = next.resolveConcurrency(
      isMobile: Platform.isAndroid || Platform.isIOS,
    );
  });
  // A network change re-examines the queue: a queue held back by the
  // "unmetered only" rule must start as soon as the connection allows,
  // without waiting for the user to enqueue or resume something.
  final connectivity = Connectivity();
  final sub = connectivity.onConnectivityChanged.listen((_) {
    manager.onConnectivityChanged();
  });
  // Prime the connectivity cache now, so the gate answers on the very
  // first pump instead of holding everything as "unknown".
  manager.onConnectivityChanged();
  ref.onDispose(() {
    sub.cancel();
    manager.dispose();
  });
  return manager;
});
