import 'dart:convert';

import 'package:hive/hive.dart';

import '../../core/models/command_template.dart';
import '../../core/models/settings_model.dart';
import 'template_store.dart';

/// A settings backup: the app's preferences plus any saved argument
/// templates, as a single JSON document.
///
/// Losing the extra-args field or a hand-tuned output template is annoying at
/// best, and there is no other way back once the box is cleared. A file the
/// user can keep solves that without an account or a sync service.
class SettingsBackup {
  const SettingsBackup({
    required this.settings,
    required this.templates,
    required this.version,
  });

  final AppSettings settings;
  final List<CommandTemplate> templates;

  /// Backup format version, so a future change can migrate rather than fail.
  final int version;

  /// The version this build writes.
  static const int currentVersion = 1;

  Map<String, dynamic> toMap() => {
    'version': version,
    'app': settings.toMap(),
    'templates': [for (final t in templates) t.toMap()],
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toMap());

  /// Parses [raw], returning null when it is not a backup this app wrote.
  ///
  /// Returns null rather than throwing: the caller offers a file picker, and a
  /// wrong file chosen there is a user mistake, not a crash.
  static SettingsBackup? decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);

    // Only a *newer* format is refused. An older one is read best-effort,
    // because every field already has a default in AppSettings.fromMap.
    final version = (map['version'] as num?)?.toInt() ?? 0;
    if (version > currentVersion) return null;

    final app = map['app'];
    if (app is! Map) return null;

    return SettingsBackup(
      version: version,
      settings: AppSettings.fromMap(Map<String, dynamic>.from(app)),
      templates: [
        // Pattern-matched rather than cast: a hand-edited or truncated backup
        // whose `templates` is not a list must still load its settings rather
        // than throw, since this is the path where a user picks a file.
        for (final t in switch (map['templates']) {
          final List<dynamic> list => list,
          _ => const <dynamic>[],
        })
          if (t is Map) CommandTemplate.fromMap(Map<String, dynamic>.from(t)),
      ],
    );
  }
}

/// Reads and writes the settings backup.
///
/// Templates go through [TemplateStore] rather than a second copy of its key
/// scheme, so a restore cannot drift from how templates are actually stored.
class BackupService {
  const BackupService({required this.box, required this.templates});

  final Box<dynamic> box;
  final TemplateStore templates;

  static const settingsKey = 'app_settings';

  /// Snapshot of the current settings and templates.
  ///
  /// With nothing stored this returns the constructor defaults rather than
  /// routing through [AppSettings.fromMap], because a missing key there
  /// resolves to "Best quality" instead of the documented 720 default — an
  /// export of an untouched install should look untouched.
  SettingsBackup export() {
    final stored = box.get(settingsKey);
    return SettingsBackup(
      version: SettingsBackup.currentVersion,
      settings: stored is Map
          ? AppSettings.fromMap(Map<String, dynamic>.from(stored))
          : const AppSettings(),
      templates: templates.templates,
    );
  }

  /// Applies [backup], replacing the stored settings and templates.
  ///
  /// Returns false when the document is from a newer build, in which case
  /// nothing is written — a partial restore would be worse than none.
  Future<bool> restore(SettingsBackup backup) async {
    if (backup.version > SettingsBackup.currentVersion) return false;
    await box.put(settingsKey, backup.settings.toMap());
    // A restore is a snapshot, not a merge: a template deleted before the
    // backup stays deleted rather than reappearing.
    await templates.clear();
    for (final t in backup.templates) {
      await templates.save(t);
    }
    return true;
  }

  /// Parses and applies [raw] in one step. False when it is not a backup.
  Future<bool> restoreFrom(String raw) async {
    final backup = SettingsBackup.decode(raw);
    if (backup == null) return false;
    return restore(backup);
  }
}
