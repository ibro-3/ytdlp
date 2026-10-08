import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/models/settings_model.dart';

class SettingsService extends ChangeNotifier {
  SettingsService(this._box);
  final Box<dynamic> _box;

  static const _key = 'app_settings';

  /// The write most recently issued by [update], if any.
  ///
  /// Callers that own the box's lifetime need to know whether a save has
  /// landed before they close it: `Box.close` waits for writes in flight, so a
  /// pending one holds the close open. `update` itself is awaited by its own
  /// callers, but the settings screen fires saves with `unawaited`, so this is
  /// the only handle on one that is still in flight.
  Future<void> get pendingWrite => _pendingWrite;
  Future<void> _pendingWrite = Future<void>.value();

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
    // Tracked rather than only awaited: see [pendingWrite].
    final write = _box.put(_key, next.toMap());
    _pendingWrite = write;
    await write;
    notifyListeners();
  }
}
