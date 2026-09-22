import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/models/settings_model.dart';

class SettingsService extends ChangeNotifier {
  SettingsService(this._box);
  final Box<dynamic> _box;

  static const _key = 'app_settings';

  late AppSettings _settings;
  AppSettings get settings => _settings;

  void init() {
    final raw = _box.get(_key);
    _settings = raw is Map
        ? AppSettings.fromMap(Map<String, dynamic>.from(raw))
        : const AppSettings();
  }

  Future<void> update(AppSettings next) async {
    _settings = next;
    await _box.put(_key, next.toMap());
    notifyListeners();
  }
}
