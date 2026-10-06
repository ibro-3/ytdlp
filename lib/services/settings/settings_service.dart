import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/models/settings_model.dart';

class SettingsService extends ChangeNotifier {
  SettingsService(this._box);
  final Box<dynamic> _box;

  static const _key = 'app_settings';

  late AppSettings _settings;
  AppSettings get settings => _settings;

  /// Reloads settings from storage and tells listeners.
///
/// Called once at construction, and again after a backup restore — which
/// rewrites the stored map behind this object's back. Nothing reactive watches
/// the notifier itself (a Riverpod provider yielding one always-equal instance
/// never notifies), so this is for `ChangeNotifier` listeners; the reactive
/// path is `SettingsController.reload`.
void init() {
    final raw = _box.get(_key);
    _settings = raw is Map
        ? AppSettings.fromMap(Map<String, dynamic>.from(raw))
        : const AppSettings();
    notifyListeners();
  }

  Future<void> update(AppSettings next) async {
    _settings = next;
    await _box.put(_key, next.toMap());
    notifyListeners();
  }
}
